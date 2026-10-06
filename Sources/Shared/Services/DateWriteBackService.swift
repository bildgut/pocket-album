import Foundation
import SwiftData

/// Ergebnis einer Übernahme oder einer Rücknahme.
struct DateWriteResult: Sendable {
    let batchId: String
    let written: Int
    /// Bilder ohne lesbares Aufnahmedatum. Übersprungen, nicht geraten.
    let skipped: [String]
    /// Bilder, die unverändert blieben, weil der Server sie nicht herausgab oder
    /// den Schreibvorgang ablehnte.
    ///
    /// Beide Fälle gehören hierher, damit die Summe aus `written`, `skipped` und
    /// `failed` die Zahl der angeforderten Bilder ergibt. Ein Bild, das aus dieser
    /// Bilanz fällt, behält lautlos sein falsches Datum: `DateFixModel` schweigt,
    /// wenn `failed` und `skipped` leer sind, und räumt die Vorschlagskarte weg,
    /// sobald irgendetwas geschrieben wurde.
    let failed: [String]
}

/// Schreibt korrigierte Aufnahmezeitpunkte und protokolliert, was vorher dastand.
///
/// Ein `PUT` je Bild. Der Bulk-Endpunkt `PUT /api/assets` scheidet aus: er setzt
/// *einen* Wert für viele Assets, ein Versatz gibt aber jedem Bild einen eigenen
/// Zeitstempel.
@MainActor
final class DateWriteBackService {

    /// Dieselbe Deckelung wie `AlbumMembershipIndexer`: der Server soll nicht
    /// gesättigt und der laufende Abgleich nicht verdrängt werden.
    static let maxConcurrentWrites = 4

    private let apiClient: ImmichAPIClient
    private let container: ModelContainer

    init(apiClient: ImmichAPIClient, container: ModelContainer) {
        self.apiClient = apiClient
        self.container = container
    }

    // MARK: - Reine Planung

    struct Plan: Sendable {
        /// Asset-ID → neuer Zeitstempel.
        let writes: [String: String]
        /// Asset-IDs ohne lesbares Aufnahmedatum, aufsteigend sortiert.
        let skipped: [String]
    }

    /// Rechnet aus, was geschrieben werden müsste.
    ///
    /// `nonisolated`, weil rein: keine Uhr, kein Netz, kein Zustand. Das ist die
    /// Stelle, an der ein Fehler lautlos falsche Aufnahmedaten in die Bibliothek
    /// schreibt — sie gehört ohne Umgebung prüfbar, nicht an den Hauptthread
    /// gebunden.
    ///
    /// - Parameter current: Asset-ID → aktueller `dateTimeOriginal`, `nil` wenn keiner
    ///   vorhanden ist.
    nonisolated static func plan(current: [String: String?], offset: TimeInterval) -> Plan {
        guard offset != 0 else { return Plan(writes: [:], skipped: []) }

        var writes: [String: String] = [:]
        var skipped: [String] = []

        for (id, value) in current {
            guard let value, let shifted = DateFixOffset.shift(value, by: offset) else {
                skipped.append(id)
                continue
            }
            writes[id] = shifted
        }

        return Plan(writes: writes, skipped: skipped.sorted())
    }

    /// Rechnet aus, was geschrieben werden müsste, wenn je Aufnahme ein eigener
    /// Zielzeitpunkt feststeht.
    ///
    /// Gegenstück zur Versatz-Fassung, für die Detektoren A1 und A2: bei einem
    /// Platzhalter-Block gibt es keinen gemeinsamen Versatz, weil die echten Zeiten
    /// verloren sind.
    ///
    /// Ebenfalls `nonisolated` und rein — und ebenso streng: eine Aufnahme ohne
    /// lesbaren Ist-Wert wird übersprungen, nie geraten.
    nonisolated static func plan(current: [String: String?],
                                 instants: [String: DateInstant]) -> Plan {
        var writes: [String: String] = [:]
        var skipped: [String] = []

        for (id, replacement) in instants {
            guard let value = current[id] ?? nil,
                  let written = DateFixOffset.apply(replacement, to: value) else {
                skipped.append(id)
                continue
            }
            writes[id] = written
        }

        return Plan(writes: writes, skipped: skipped.sorted())
    }

    // MARK: - Übernehmen

    /// Der Ausgang eines einzelnen Schreibvorgangs.
    ///
    /// Trägt die Asset-ID auch im Fehlerfall mit: eine Fehlerliste ohne IDs wäre
    /// nicht nachverfolgbar, und genau sie braucht der Nutzer, um zu sehen, welche
    /// Bilder unverändert blieben.
    private struct WriteOutcome: Sendable {
        let id: String
        let old: String
        let new: String
        let succeeded: Bool
    }

    /// Liest den aktuellen Aufnahmezeitpunkt jedes Bildes, verschiebt ihn und
    /// schreibt ihn zurück. Der alte Wert landet vorher im Protokoll.
    ///
    /// Der aktuelle Wert muss vom Server geholt werden: der Grid-Index führt nur
    /// `fileCreatedAt`, nicht `dateTimeOriginal`, und beide sind nicht dasselbe.
    func apply(assetIds: [String],
               offset: TimeInterval,
               groupTitle: String) async -> DateWriteResult {
        let (current, unreadable) = await fetchCurrentTimestamps(assetIds)
        return await perform(plan: Self.plan(current: current, offset: offset),
                             current: current,
                             unreadable: unreadable,
                             groupTitle: groupTitle)
    }

    /// Setzt je Aufnahme einen eigenen Zielzeitpunkt.
    ///
    /// Für die Detektoren A1 und A2. Die `DateInstant`-Werte müssen bereits
    /// aufgelöst sein — insbesondere dürfen Spender-Zeitpunkte nicht mehr aus dem
    /// Grid-Index stammen, siehe `DateInstant.sourceAssetId`.
    func apply(instants: [String: DateInstant],
               groupTitle: String) async -> DateWriteResult {
        let (current, unreadable) = await fetchCurrentTimestamps(Array(instants.keys))
        return await perform(plan: Self.plan(current: current, instants: instants),
                             current: current,
                             unreadable: unreadable,
                             groupTitle: groupTitle)
    }

    /// Liest den echten `dateTimeOriginal` der Spender-Aufnahmen nach.
    ///
    /// Der Grid-Index führt `fileCreatedAt`; geschrieben wird `dateTimeOriginal`.
    /// Ohne diesen Schritt bekäme jede reparierte Aufnahme den systematischen
    /// Unterschied der beiden Felder eingebacken.
    ///
    /// - Returns: dieselbe Zuordnung, bei den Spender-Fällen mit dem Serverwert.
    ///   Ist ein Spender nicht abrufbar, bleibt der Indexwert stehen — er ist
    ///   allemal besser als der Platzhalter, den er ersetzt.
    func resolvingDonors(_ instants: [String: DateInstant]) async -> [String: DateInstant] {
        let donorIds = Set(instants.values.compactMap(\.sourceAssetId))
        guard !donorIds.isEmpty else { return instants }

        let (values, _) = await fetchCurrentTimestamps(Array(donorIds))

        var resolved = instants
        for (id, replacement) in instants {
            guard let donorId = replacement.sourceAssetId,
                  let raw = values[donorId] ?? nil,
                  let parsed = DateFixOffset.parse(raw) else { continue }
            resolved[id] = DateInstant(instant: parsed.instant,
                                       precision: replacement.precision,
                                       anchor: .absolute,
                                       sourceAssetId: donorId)
        }
        return resolved
    }

    private func perform(plan: Plan,
                         current: [String: String?],
                         unreadable: [String],
                         groupTitle: String) async -> DateWriteResult {

        let batchId = UUID().uuidString
        var written: [String: (old: String, new: String)] = [:]
        // Wer sich nicht lesen ließ, wurde auch nicht geschrieben — und muss in der
        // Bilanz stehen, sonst verschwindet er zwischen den Zahlen.
        var failed: [String] = unreadable

        let apiClient = self.apiClient
        await withTaskGroup(of: WriteOutcome.self) { group in
            var iterator = plan.writes.makeIterator()

            func addNext() {
                guard let (id, newValue) = iterator.next() else { return }
                let oldValue = (current[id] ?? nil) ?? ""
                group.addTask { [apiClient] in
                    do {
                        try await apiClient.updateAssetMetadata(assetId: id,
                                                                dateTimeOriginal: newValue)
                        return WriteOutcome(id: id, old: oldValue, new: newValue, succeeded: true)
                    } catch {
                        AppLogger.api.error("Datumskorrektur für \(id) fehlgeschlagen: \(error)")
                        return WriteOutcome(id: id, old: oldValue, new: newValue, succeeded: false)
                    }
                }
            }

            // Vier Aufgaben starten, danach je abgeschlossener eine neue nachlegen —
            // so laufen nie mehr als `maxConcurrentWrites` gleichzeitig.
            for _ in 0..<Self.maxConcurrentWrites { addNext() }

            while let outcome = await group.next() {
                if outcome.succeeded {
                    written[outcome.id] = (outcome.old, outcome.new)
                } else {
                    failed.append(outcome.id)
                }
                addNext()
            }
        }

        recordUndo(written, groupTitle: groupTitle, batchId: batchId)

        AppLogger.sync.info("Datumskorrektur „\(groupTitle)“: \(written.count) geschrieben, \(plan.skipped.count) ohne Aufnahmedatum, \(failed.count) unverändert (davon \(unreadable.count) nicht abrufbar)")
        NotificationCenter.default.post(name: .assetsDidChange, object: nil)

        return DateWriteResult(batchId: batchId,
                               written: written.count,
                               skipped: plan.skipped,
                               failed: failed)
    }

    /// Holt die aktuellen Aufnahmezeitpunkte, höchstens vier gleichzeitig.
    ///
    /// - Returns: die gelesenen Werte und getrennt davon die IDs, deren Abruf
    ///   scheiterte. Die Trennung ist der Punkt: „kein Aufnahmedatum" (Wert `nil`)
    ///   und „nicht abrufbar" sind verschiedene Dinge, und nur das erste ist ein
    ///   Grund zum Überspringen. Fielen sie zusammen, verschwänden die
    ///   unerreichbaren Bilder ganz aus der Bilanz — `plan` läuft über die
    ///   gelesenen Schlüssel, und was nie ankam, hat keinen.
    private func fetchCurrentTimestamps(
        _ ids: [String]
    ) async -> (values: [String: String?], unreadable: [String]) {
        var result: [String: String?] = [:]
        var unreadable: [String] = []

        let apiClient = self.apiClient
        await withTaskGroup(of: (id: String, value: String?, ok: Bool).self) { group in
            var iterator = ids.makeIterator()

            func addNext() {
                guard let id = iterator.next() else { return }
                group.addTask { [apiClient] in
                    do {
                        let asset = try await apiClient.getAssetDetail(id: id)
                        return (id: id, value: asset.exifInfo?.dateTimeOriginal, ok: true)
                    } catch {
                        AppLogger.api.error("Aufnahmedatum von \(id) nicht lesbar: \(error)")
                        return (id: id, value: nil, ok: false)
                    }
                }
            }

            for _ in 0..<Self.maxConcurrentWrites { addNext() }

            while let entry = await group.next() {
                if entry.ok {
                    result[entry.id] = entry.value
                } else {
                    unreadable.append(entry.id)
                }
                addNext()
            }
        }

        return (result, unreadable.sorted())
    }

    // MARK: - Rücknahme

    /// Ein zurücknehmbarer Stapel.
    struct Batch: Sendable, Identifiable, Equatable {
        let id: String
        let groupTitle: String
        let count: Int
        let appliedAt: Date
    }

    /// Die jüngsten Stapel, die sich noch zurücknehmen lassen.
    ///
    /// Aus dem Protokoll abgeleitet statt gesondert gespeichert — es steht schon
    /// alles da. Damit reicht die Rücknahme über den letzten Vorgang hinaus, ohne
    /// eine Schemaänderung.
    func recentBatches(limit: Int = 20) -> [Batch] {
        let context = ModelContext(container)
        let entries = (try? context.fetch(FetchDescriptor<DateFixUndoEntry>())) ?? []

        var grouped: [String: (title: String, count: Int, at: Date)] = [:]
        for entry in entries {
            var current = grouped[entry.batchId]
                ?? (entry.groupTitle, 0, entry.appliedAt)
            current.count += 1
            current.at = min(current.at, entry.appliedAt)
            grouped[entry.batchId] = current
        }

        // Bewusst in Schritten statt als Kette: als ein Ausdruck geschrieben
        // überforderte das den Typprüfer.
        var batches: [Batch] = []
        for (id, value) in grouped {
            batches.append(Batch(id: id,
                                 groupTitle: value.title,
                                 count: value.count,
                                 appliedAt: value.at))
        }
        batches.sort { a, b in
            a.appliedAt == b.appliedAt ? a.id < b.id : a.appliedAt > b.appliedAt
        }
        return Array(batches.prefix(limit))
    }

    /// Schreibt für einen Stapel die zuvor gesicherten Werte zurück.
    func undo(batchId: String) async -> DateWriteResult {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<DateFixUndoEntry>(
            predicate: #Predicate { $0.batchId == batchId }
        )
        let entries = (try? context.fetch(descriptor)) ?? []
        guard !entries.isEmpty else {
            return DateWriteResult(batchId: batchId, written: 0, skipped: [], failed: [])
        }

        let restore = entries.map { ($0.assetId, $0.previousDateTimeOriginal) }
        var restored = 0
        var failed: [String] = []

        for (id, oldValue) in restore {
            do {
                try await apiClient.updateAssetMetadata(assetId: id, dateTimeOriginal: oldValue)
                restored += 1
            } catch {
                AppLogger.api.error("Rücknahme für \(id) fehlgeschlagen: \(error)")
                failed.append(id)
            }
        }

        // Nur die tatsächlich zurückgeschriebenen Einträge verschwinden aus dem
        // Protokoll. Ein abgelehnter bleibt stehen, damit ein zweiter Versuch ihn
        // noch findet.
        for entry in entries where !failed.contains(entry.assetId) {
            context.delete(entry)
        }
        try? context.save()

        AppLogger.sync.info("Datumskorrektur zurückgenommen: \(restored) Bilder, \(failed.count) abgelehnt")
        NotificationCenter.default.post(name: .assetsDidChange, object: nil)

        return DateWriteResult(batchId: batchId, written: restored, skipped: [], failed: failed)
    }

    // MARK: - Protokoll

    private func recordUndo(_ written: [String: (old: String, new: String)],
                            groupTitle: String,
                            batchId: String) {
        guard !written.isEmpty else { return }

        let context = ModelContext(container)
        for (id, values) in written {
            // Ein Bild ohne vorherigen Wert lässt sich nicht zurücksetzen — für den
            // Weg zurück gäbe es nichts zu schreiben. Solche Fälle kommen hier nicht
            // an, weil `plan` sie überspringt; die Prüfung steht trotzdem, damit ein
            // leerer Eintrag nie ins Protokoll gerät.
            guard !values.old.isEmpty else { continue }
            context.insert(DateFixUndoEntry(assetId: id,
                                            previousDateTimeOriginal: values.old,
                                            newDateTimeOriginal: values.new,
                                            groupTitle: groupTitle,
                                            batchId: batchId))
        }
        try? context.save()
    }
}
