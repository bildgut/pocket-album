import Foundation
import SwiftData

/// Eine Zeile der Seite „Offline“: Kennzahlen aus ``PhoneStorageSummary`` plus
/// Art, Wahl und was zum Sortieren und Freigeben nötig ist.
///
/// **Die `id` ist der `pinId`, nicht der Name**: Zwei Alben dürfen gleich heißen,
/// und ein `ForEach` über gleiche IDs zeigt nur eine der Zeilen — beim Freigeben
/// träfe es womöglich das falsche. `Sendable`, weil die Zeilen aus einem
/// `Task.detached` kommen.
struct PhoneOfflineQuelle: Identifiable, Equatable, Sendable {
    /// `OfflinePin.pinId`.
    let id: String
    let kind: OfflinePinKind
    let targetId: String
    let pinnedAt: Date
    let eintrag: PhoneStorageSummary.Eintrag
    let wahl: OfflineWahl?

    /// „Letzte Tage“ heißt nach der aktuellen Stufe, nicht nach dem gemerkten
    /// `displayName` — der stammt vom Anlegen.
    func titel(tage: Int) -> String {
        kind == .zuletzt ? PhoneZuletztStand.titel(tage: tage) : eintrag.name
    }

    /// „Preview · 1,5 KB“. Ohne Wahl (vor der Offline-Qualität angelegt) lud der
    /// Lader Originale.
    var untertitel: String {
        let qualitaet = wahl?.fotos == .vorschau ? String(localized: "Preview") : String(localized: "Original")
        return "\(qualitaet) · \(eintrag.groesse)"
    }

    var zustand: PhoneStorageSummary.Zustand { eintrag.zustand }
}

/// Reine Logik der Seite „Offline“ (Spec `docs/superpowers/specs/2026-10-22-ios-offline-quellen-design.md`).
enum PhoneOfflineQuellen {
    /// In Ladereihenfolge — dieselbe Ordnung, die der Lader benutzt.
    static func geordnet(_ quellen: [PhoneOfflineQuelle], reihenfolge: OfflineReihenfolge = OfflineReihenfolge()) -> [PhoneOfflineQuelle] {
        reihenfolge.sortiert(quellen, pinId: \.id, kind: \.kind, pinnedAt: \.pinnedAt)
    }

    /// Was unter „Hinzufügen“ steht. Personen immer (es gibt beliebig viele), aber
    /// nur mit `person.read`.
    static func hinzufuegbar(vorhanden: Set<OfflinePinKind>, darfPersonen: Bool) -> [OfflinePinKind] {
        var arten: [OfflinePinKind] = []
        if !vorhanden.contains(.favoriten) { arten.append(.favoriten) }
        if !vorhanden.contains(.zuletzt) { arten.append(.zuletzt) }
        if darfPersonen { arten.append(.person) }
        return arten
    }

    /// Die Zeile in den Einstellungen: „2 sources · 4,2 GB“ bzw. „Off“.
    static func zusammenfassung(_ quellen: [PhoneOfflineQuelle]) -> String {
        guard !quellen.isEmpty else { return String(localized: "Off") }
        let bytes = quellen.reduce(Int64(0)) { $0 + $1.eintrag.bytes }
        // Zwei Teile statt eines Schlüssels: nur so greift die Pluralform („1 source“).
        return String(localized: "\(quellen.count) sources") + " · " + PhoneStorageSummary.groesse(bytes)
    }

    /// Nur ein Berechtigungsfehler nimmt „+ Person…“ weg — ein Zeitüberschreiten
    /// oder ein 5xx sagt nichts über `person.read`.
    static func darfPersonen(nach fehler: Error) -> Bool {
        if case APIError.apiKeyLacksPermission = fehler { return false }
        return true
    }
}

extension PhoneOfflineQuellen {
    /// Was zum Rechnen in den Hintergrund muss. `OfflinePin` ist ein `@Model` und
    /// damit nicht `Sendable` — über die Actor-Grenze geht nur dieser Schnappschuss.
    struct Schnappschuss: Sendable {
        let pinId: String
        let kind: OfflinePinKind
        let targetId: String
        let pinnedAt: Date
        let name: String
        let assetIds: [String]
        let fehler: String?
        let wahl: OfflineWahl?

        @MainActor
        init(_ pin: OfflinePin, speicher: OfflineWahlSpeicher) {
            pinId = pin.pinId
            kind = pin.kind
            targetId = pin.targetId
            pinnedAt = pin.pinnedAt
            name = pin.displayName
            assetIds = pin.assetIds
            fehler = pin.lastError
            wahl = speicher.wahl(fuer: pin.pinId)
        }
    }

    /// Kennzahlen je Vermerk. Kostet je Zeile einen Fetch über alle Assets mit
    /// lokaler Datei — deshalb abseits des MainActors.
    static func berechne(_ schnappschuesse: [Schnappschuss], container: ModelContainer) async -> [PhoneOfflineQuelle] {
        await Task.detached(priority: .utility) {
            schnappschuesse.map { s in
                let status = LocalFileCacheManager.statusAufPlatte(forAssetIds: s.assetIds, wahl: s.wahl, container: container)
                return PhoneOfflineQuelle(
                    id: s.pinId, kind: s.kind, targetId: s.targetId, pinnedAt: s.pinnedAt,
                    eintrag: PhoneStorageSummary.Eintrag(name: s.name, vorhanden: status.present, erwartet: status.expected,
                                                         bytes: status.bytes, fehler: s.fehler),
                    wahl: s.wahl)
            }
        }.value
    }
}
