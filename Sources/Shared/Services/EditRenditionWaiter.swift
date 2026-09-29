import Foundation

/// Wartet, bis der Server die bearbeitete Fassung eines Assets wirklich ausliefert.
///
/// `PUT /api/assets/{id}/edits` antwortet mit HTTP 200, **bevor** die neuen Bilddateien
/// gerendert sind. Zwei Messungen vom 06.09.2026 (Immich v3.1.0):
///
/// ```
/// Erste Bearbeitung (300-ms-Takt):
///   t=0,0 s  thumb=9398  original=2.783.000   ← PUT ist gerade zurückgekommen
///   t=0,7 s  thumb=9206  original=  728.270   ← beide zugleich fertig
///
/// Änderung einer bestehenden Bearbeitung, 180° → 270° (2-s-Takt):
///   t=0,0 s  original=577.642                 ← Thumbnail war da, Original noch alt
///   t=2,2 s  original=578.996                 ← erst jetzt auch das Original
/// ```
///
/// Die zweite Messung ist der Grund, warum hier ein **gemeinsamer** Fingerabdruck über
/// beide Fassungen läuft: Wer nur auf das Thumbnail wartet, lädt in genau diesem
/// Zwei-Sekunden-Fenster das alte Original nach und legt es erneut in den Cache — und
/// danach fordert nichts mehr an. Genau das ließ jede zweite Drehung wirkungslos
/// aussehen, während das Raster längst richtig stand.
enum EditRenditionWaiter {

    /// - Parameters:
    ///   - before: Fingerabdrücke **vor** der Änderung, einer je Fassung. Ein `nil`
    ///     bedeutet: für diese Fassung gibt es keinen Vergleichsmaßstab, die erste
    ///     erfolgreiche Antwort zählt.
    ///   - fingerprints: Liest die aktuellen Fingerabdrücke frisch vom Server (ohne
    ///     Cache), in derselben Reihenfolge.
    /// - Returns: `true`, sobald **jede** Fassung neu ist; `false` beim Zeitlimit.
    ///
    /// Ausdrücklich **jede** und nicht „irgendeine": Ein Fingerabdruck über beide
    /// zusammengerechnet wäre schon verschieden, sobald das Thumbnail fertig ist — und
    /// genau dann ist das Original noch zwei Sekunden lang alt. Der erste Anlauf dieses
    /// Fixes hatte exakt diesen Fehler und ließ die zweite Drehung wieder wirkungslos
    /// aussehen.
    static func waitForNewRendition(
        before: [String?],
        timeout: Duration = .seconds(25),
        pollInterval: Duration = .milliseconds(300),
        fingerprints: () async -> [String?]
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout

        while true {
            let aktuell = await fingerprints()
            if aktuell.count == before.count, alleNeu(before: before, jetzt: aktuell) {
                return true
            }
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: pollInterval)
        }
    }

    private static func alleNeu(before: [String?], jetzt: [String?]) -> Bool {
        for (alt, neu) in zip(before, jetzt) {
            guard let neu, !neu.isEmpty else { return false }
            // Ohne Vergleichsmaßstab ist jedes Ergebnis das bestmögliche.
            if let alt, alt == neu { return false }
        }
        return true
    }
}
