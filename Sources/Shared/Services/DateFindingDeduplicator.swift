import Foundation

/// Sorgt dafür, dass eine Aufnahme in höchstens einem Befund vorkommt.
///
/// Zwei Gründe, und beide sind an der echten Bibliothek gemessen:
///
/// Der **Schaden**: die Vorgängerfassung lieferte dieselbe Aufnahmemenge doppelt,
/// weil sie in zwei Alben lag („Istanbul 2002" und „2002 03-23 Istanbul", 19
/// Aufnahmen, −4,28 d). Wer beide anwendet, verschiebt zweimal.
///
/// Die **Aussagekraft**: überschneiden sich zwei Befunde, ist einer davon der
/// spezifischere. Ein ausgeschriebenes Datum im Dateinamen ist eine Aussage über
/// *diese* Aufnahme; ein Kamerauhr-Versatz nur eine Theorie über einen Zeitraum.
/// Die Aussage gewinnt.
///
/// Rein und abhängigkeitsfrei.
enum DateFindingDeduplicator {

    /// Ordnet die Befunde und schneidet Überschneidungen heraus.
    ///
    /// - Returns: Befunde in Rangfolge, jeder mit einer Aufnahmemenge, die sich mit
    ///   keiner anderen überschneidet. Befunde, die dabei unter ihr Mindestmaß
    ///   fallen, entfallen ganz — ein Rest, der nichts mehr belegt, ist schlimmer
    ///   als kein Befund.
    static func resolve(_ findings: [DateFinding]) -> [DateFinding] {
        // Nach Rang, dann nach Größe, dann nach Schlüssel: das Ergebnis darf nicht
        // von der Reihenfolge abhängen, in der die Detektoren gelaufen sind.
        let ordered = findings.sorted { a, b in
            if a.kind.priority != b.kind.priority { return a.kind.priority < b.kind.priority }
            if a.assetIds.count != b.assetIds.count { return a.assetIds.count > b.assetIds.count }
            return a.id < b.id
        }

        var claimed = Set<String>()
        var result: [DateFinding] = []

        for finding in ordered {
            let remaining = finding.assetIds.filter { !claimed.contains($0) }
            guard remaining.count >= finding.kind.minimumAssetCount else { continue }

            let reduced = finding.retaining(Set(remaining))
            result.append(reduced)
            claimed.formUnion(remaining)
        }

        return result
    }
}

/// Führt die vier Detektoren in der richtigen Reihenfolge aus.
///
/// Die Reihenfolge ist nicht Geschmack: A1 und A2 benennen Aufnahmen, deren
/// Zeitstempel *nachweislich* kein Aufnahmezeitpunkt ist. Solche Aufnahmen dürfen
/// weder einen Kameralauf verankern noch einen Zeitzonen-Abschnitt prägen — sonst
/// stützte sich eine Theorie auf Werte, die als erfunden erkannt wurden.
enum DateFindingScanner {

    /// Was ein vollständiger Durchlauf ergeben hat.
    struct Result: Sendable {
        let findings: [DateFinding]
        /// Wie viele Aufnahmen überhaupt beurteilt wurden.
        let assetsScanned: Int

        static let empty = Result(findings: [], assetsScanned: 0)
    }

    static func scan(rows: [DateScanRow], now: Date) -> Result {
        let scan = DateLibraryScan.build(rows: rows)

        let filename = DateFilenameDetector.findings(in: scan, now: now)
        let placeholder = DatePlaceholderDetector.findings(in: scan, now: now)

        var claimed = Set(filename.flatMap(\.assetIds))
        claimed.formUnion(placeholder.flatMap(\.assetIds))

        let clock = DateCameraOffsetDetector.findings(in: scan, excluding: claimed)
        claimed.formUnion(clock.flatMap(\.assetIds))

        let timezone = DateTimezoneDetector.findings(in: scan, excluding: claimed)

        let all = filename + placeholder + clock + timezone
        return Result(findings: DateFindingDeduplicator.resolve(all),
                      assetsScanned: scan.count)
    }
}
