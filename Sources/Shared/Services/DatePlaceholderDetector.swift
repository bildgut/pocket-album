import Foundation

/// Detektor A2: ein Block von Aufnahmen, die alle denselben Zeitpunkt tragen.
///
/// Solche Blöcke entstehen, wenn nie eine Aufnahmezeit vorlag und ein Rückfallwert
/// eingesetzt wurde — ein zurückgesetztes Kameradatum (`2004-12-31 17:00:00`), das
/// Änderungsdatum der Datei oder der Zeitpunkt des Imports.
///
/// **Der Detektor schlägt nie einen gemeinsamen Versatz vor.** Die echten Zeiten
/// sind verloren; es gibt keinen Betrag, um den man den Block als Ganzes schieben
/// könnte. Er beschafft je Aufnahme einzeln ein belegtes Ersatzdatum — oder er
/// zeigt den Block, ohne etwas zu behaupten. Dass das so bleibt, erzwingt
/// `DateRepair`.
///
/// Rein und abhängigkeitsfrei.
enum DatePlaceholderDetector {

    // MARK: - Schwellen

    /// So viele Aufnahmen auf **derselben Sekunde** lassen einen Block beginnen.
    ///
    /// Bewusst eng. Eine breitere Definition („viele Aufnahmen in kurzer Zeit")
    /// wurde an der echten Bibliothek gemessen und **verworfen**: sie markierte 618
    /// Aufnahmen vom 2019-05-20 — einem echten, dicht fotografierten Tag in Nara.
    /// Über einen ganzen Tag verteilt landen nie acht Aufnahmen auf derselben
    /// Sekunde; die dichteste Sekunde dort trug drei.
    static let seedSize = 8

    /// So nah dürfen zwei Startsekunden liegen, um zu einem Block zu verschmelzen.
    ///
    /// Ein Importlauf schreibt nicht exakt eine Sekunde, sondern einen kurzen
    /// Abschnitt. Die Verschmelzung fasst ihn zusammen — sie **erweitert** aber nur
    /// Blöcke, die sich schon über die enge Startbedingung als unecht erwiesen haben.
    static let mergeWindow: TimeInterval = 180

    /// Ein Spender-Datum darf höchstens so weit von den übrigen Spendern abweichen.
    static let donorTolerance: TimeInterval = 2

    /// Kürzere Dateinamen taugen nicht als Zwillingsschlüssel.
    ///
    /// `bild1` kollidiert quer durch die Bibliothek; `DCP_0031` nicht.
    static let minimumStemLength = 5

    /// Vor diesem Zeitpunkt gilt ein Spender-Datum als unglaubwürdig.
    static let earliestDonor = Date(timeIntervalSince1970: 631_152_000)  // 1990-01-01

    // MARK: - Block

    /// Ein Zusammenhang von Aufnahmen, die denselben Rückfallwert tragen.
    struct Block: Sendable, Equatable {
        let rows: [DateScanRow]
        let seedSeconds: [Int]
        let corroborators: [PlaceholderEvidence.Corroborator]
        let largestSecondCount: Int

        var instant: Date { rows.first?.timestamp ?? .distantPast }
        /// Ob überhaupt ein Beleg vorliegt, dass der Zeitpunkt unecht ist.
        var qualifies: Bool { !corroborators.isEmpty }
    }

    // MARK: - Durchgang 1

    /// Findet Blöcke gleicher Zeitstempel und prüft, ob sie belegt unecht sind.
    ///
    /// - Returns: nur die belegten Blöcke. Ein Block ohne Zusatzbeleg wird
    ///   verworfen, nicht gezeigt — eine Kamera kann durchaus acht Bilder in einer
    ///   Sekunde schreiben, und an der echten Bibliothek haben 3 459 der 5 201
    ///   Block-Aufnahmen eine Kamera.
    static func blocks(in scan: DateLibraryScan) -> [Block] {
        let seeds = scan.countsBySecond
            .filter { $0.value >= seedSize }
            .keys
            .sorted()
        guard !seeds.isEmpty else { return [] }

        var result: [Block] = []
        var group: [Int] = [seeds[0]]

        func close(_ seedGroup: [Int]) {
            guard let block = build(seedGroup, in: scan) else { return }
            if block.qualifies { result.append(block) }
        }

        for second in seeds.dropFirst() {
            if let last = group.last, TimeInterval(second - last) <= mergeWindow {
                group.append(second)
            } else {
                close(group)
                group = [second]
            }
        }
        close(group)

        return result
    }

    private static func build(_ seedSeconds: [Int], in scan: DateLibraryScan) -> Block? {
        guard let first = seedSeconds.first, let last = seedSeconds.last else { return nil }

        // Der Block nimmt *alle* Zeilen des verschmolzenen Abschnitts auf, nicht nur
        // die der Startsekunden — ein Importlauf trifft nicht jede Sekunde gleich oft.
        var rows: [DateScanRow] = []
        for second in first...last {
            if let inSecond = scan.rowsBySecond[second] { rows.append(contentsOf: inSecond) }
        }
        rows.sort(by: DateLibraryScan.chronological)
        guard !rows.isEmpty else { return nil }

        var corroborators: [PlaceholderEvidence.Corroborator] = []

        // (1) Keine Aufnahme nennt eine Kamera. Eingescannt oder heruntergeladen —
        // dann ist der Zeitstempel per Definition kein Aufnahmezeitpunkt, sondern
        // das, was das Dateisystem hergab.
        if rows.allSatisfy({ !$0.hasCamera }) {
            corroborators.append(.noCamera)
        }

        // (2) Mehrere Kameramodelle auf derselben Sekunde. Physisch unmöglich: zwei
        // Geräte lösen nicht in derselben Sekunde aus und schreiben denselben Wert.
        var maxDistinctCameras = 0
        for second in seedSeconds {
            let cameras = Set((scan.rowsBySecond[second] ?? [])
                .filter(\.hasCamera)
                .map(\.cameraKey))
            maxDistinctCameras = max(maxDistinctCameras, cameras.count)
        }
        if maxDistinctCameras >= 2 {
            corroborators.append(.multipleCameras(count: maxDistinctCameras))
        }

        // (3) Alle Startsekunden liegen auf einer vollen Stunde. Kamerarücksetzungen
        // landen auf runden Zeiten — `17:00:00`, `06:00:00`, `23:00:00`.
        if seedSeconds.allSatisfy({ $0 % 3600 == 0 }) {
            corroborators.append(.roundResetTime)
        }

        let largest = seedSeconds.map { scan.countsBySecond[$0] ?? 0 }.max() ?? 0

        return Block(rows: rows,
                     seedSeconds: seedSeconds,
                     corroborators: corroborators,
                     largestSecondCount: largest)
    }

    // MARK: - Durchgang 2

    /// Baut aus den belegten Blöcken Befunde und beschafft, wo möglich, ein
    /// Ersatzdatum.
    ///
    /// - Parameter now: Obergrenze für plausible Daten, ausdrücklich übergeben.
    static func findings(in scan: DateLibraryScan, now: Date) -> [DateFinding] {
        let blocks = blocks(in: scan)
        guard !blocks.isEmpty else { return [] }

        // Erst alle Blöcke kennen, dann Spender prüfen: ein Spender, der selbst in
        // einem Block liegt, taugt nicht. Genau daran scheiterte die naive Zählung —
        // sie fand 2 600 Zwillinge, darunter Spender auf `1997-01-01 00:00`.
        var poisoned = Set<Int>()
        for block in blocks {
            for row in block.rows { poisoned.insert(row.epochSecond) }
        }

        return blocks.compactMap { finding(for: $0, in: scan, poisoned: poisoned, now: now) }
            .sorted { a, b in
                a.assetIds.count == b.assetIds.count
                    ? a.id < b.id
                    : a.assetIds.count > b.assetIds.count
            }
    }

    private static func finding(for block: Block,
                                in scan: DateLibraryScan,
                                poisoned: Set<Int>,
                                now: Date) -> DateFinding? {
        var instants: [String: DateInstant] = [:]
        var donorIds: [String] = []
        var donorTimes: [Date] = []

        for row in block.rows {
            // Der Dateiname zuerst: er nennt ein Datum ausdrücklich, ein Zwilling
            // lässt es nur erschließen.
            if let named = DateFilenameDetector.parse(fileName: row.originalFileName, now: now) {
                instants[row.id] = DateInstant(instant: named.wallClock,
                                               precision: named.hasTime ? .exact : .dayOnly,
                                               anchor: .wallClock)
                continue
            }

            if let donor = donatedInstant(for: row, in: scan, poisoned: poisoned, now: now) {
                instants[row.id] = DateInstant(instant: donor.instant,
                                               precision: .exact,
                                               anchor: .absolute,
                                               sourceAssetId: donor.ids.first)
                donorIds.append(contentsOf: donor.ids)
                donorTimes.append(donor.instant)
            }
        }

        let evidence = PlaceholderEvidence(
            blockInstant: block.instant,
            blockSize: block.rows.count,
            largestSecondCount: block.largestSecondCount,
            corroborators: block.corroborators,
            repairableCount: instants.count
        )

        return DateFinding(
            id: "block:\(block.seedSeconds.first ?? 0)",
            kind: .placeholderBlock(evidence),
            assetIds: block.rows.map(\.id),
            timestamps: block.rows.map(\.timestamp),
            repair: instants.isEmpty ? .listingOnly : .perAssetInstants(instants),
            referenceIds: donorIds,
            referenceTimestamps: donorTimes,
            title: title(for: block)
        )
    }

    /// Ohne Zählung im Text — siehe `DateFilenameDetector.title`.
    private static func title(for block: Block) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateFormat = "d. MMMM yyyy, HH:mm"
        return "Blockzeitpunkt \(formatter.string(from: block.instant))"
    }

    // MARK: - Spender

    private struct Donation {
        let instant: Date
        let ids: [String]
    }

    /// Sucht ein belegtes Ersatzdatum bei gleichnamigen Aufnahmen derselben Kamera.
    ///
    /// Der beobachtete Normalfall ist eine zweite Kopie derselben Datei — `DCP_0031.jpg`
    /// neben `DCP_0031.JPG` —, bei der das Datum erhalten geblieben ist.
    private static func donatedInstant(for row: DateScanRow,
                                       in scan: DateLibraryScan,
                                       poisoned: Set<Int>,
                                       now: Date) -> Donation? {
        let stem = row.filenameStem
        guard stem.count >= minimumStemLength else { return nil }
        guard let candidates = scan.byFilenameStem[stem] else { return nil }

        let donors = candidates.filter {
            isUsableDonor($0, for: row, poisoned: poisoned, now: now)
        }
        guard !donors.isEmpty else { return nil }

        // Zwei übereinstimmende Spender genügen als Beleg.
        if donors.count >= 2 {
            let times = donors.map(\.timestamp).sorted()
            guard let spread = times.last?.timeIntervalSince(times[0]),
                  spread <= donorTolerance else { return nil }
            return Donation(instant: times[times.count / 2], ids: donors.map(\.id))
        }

        // Ein einzelner Spender nur, wenn die Nummernfolge derselben Kamera ihn
        // einklammert. Das ist die einzige Stelle, an der die Reihenfolge der
        // Dateinamen mitreden darf — und sie redet nur als Schranke mit, nie als
        // eigener Befund.
        guard let only = donors.first,
              isBracketedBySequence(only, in: scan, poisoned: poisoned) else { return nil }
        return Donation(instant: only.timestamp, ids: [only.id])
    }

    private static func isUsableDonor(_ donor: DateScanRow,
                                      for row: DateScanRow,
                                      poisoned: Set<Int>,
                                      now: Date) -> Bool {
        guard donor.id != row.id else { return false }
        guard donor.cameraKey == row.cameraKey else { return false }
        // Selbst in einem belegten Block — der Spender ist dann genauso kaputt.
        guard !poisoned.contains(donor.epochSecond) else { return false }
        // Runde Rücksetzzeiten sind kein Aufnahmezeitpunkt, auch außerhalb eines Blocks.
        guard donor.epochSecond % 3600 != 0 else { return false }
        guard donor.timestamp >= earliestDonor, donor.timestamp <= now else { return false }
        return true
    }

    /// Ob die in der Nummernfolge benachbarten Aufnahmen derselben Kamera den
    /// Spender zeitlich einklammern.
    static func isBracketedBySequence(_ donor: DateScanRow,
                                      in scan: DateLibraryScan,
                                      poisoned: Set<Int>) -> Bool {
        guard let (prefix, number) = sequence(of: donor.filenameStem) else { return false }
        guard let family = scan.byCamera[donor.cameraKey] else { return false }

        var before: DateScanRow?
        var after: DateScanRow?
        var beforeNumber = Int.min
        var afterNumber = Int.max

        for candidate in family where candidate.id != donor.id {
            guard let (candidatePrefix, candidateNumber) = sequence(of: candidate.filenameStem),
                  candidatePrefix == prefix,
                  !poisoned.contains(candidate.epochSecond) else { continue }

            if candidateNumber < number, candidateNumber > beforeNumber {
                beforeNumber = candidateNumber
                before = candidate
            }
            if candidateNumber > number, candidateNumber < afterNumber {
                afterNumber = candidateNumber
                after = candidate
            }
        }

        guard let low = before, let high = after else { return false }
        return low.timestamp <= donor.timestamp && donor.timestamp <= high.timestamp
    }

    /// Zerlegt einen Dateinamen in Namensteil und laufende Nummer.
    static func sequence(of stem: String) -> (prefix: String, number: Int)? {
        let digits = stem.reversed().prefix { $0.isNumber }
        guard !digits.isEmpty, let number = Int(String(digits.reversed())) else { return nil }
        let prefix = String(stem.dropLast(digits.count))
        return (prefix, number)
    }
}
