import Foundation

/// Wie viele Uploads gleichzeitig laufen — einstellbar, Vorgabe 8.
///
/// Gemessen am 02.11.2026 aus Korea über Tailscale zum Server in Deutschland
/// (iperf3): 1 Verbindung 9 Mbit/s, 4 → 18, 8 → 23, 16 → 28. Auf einer Strecke mit
/// Paketverlust bremst sich jede TCP-Verbindung selbst aus, mehrere teilen sich die
/// Leitung. Die frühere feste 3 ließ dort gut die Hälfte liegen. Über 8 hinaus wächst
/// der Durchsatz kaum noch, belastet aber Server und Fotos-Export — daher die Vorgabe.
///
/// Gilt für den `UploadManager` **und** die Aufgabengruppen der Apple-Fotos-Läufe
/// (`runSync`, Alben, Favoriten). Die Gruppen warten je Kandidat auf den Upload; mit
/// eigener fester 3 deckelten sie den Upload, egal was der `UploadManager` erlaubt.
enum UploadParallelitaet {
    static let settingsKey = "uploadParallelitaet"
    static let vorgabe = 8
    static let bereich = 1...16

    /// Der gespeicherte Wert, in den Bereich gezwungen; ohne Eintrag die Vorgabe.
    static func wert(defaults: UserDefaults = AppEnvironment.defaults) -> Int {
        // `integer(forKey:)` liefert ohne Eintrag 0 — das hieße „gar kein Upload".
        guard defaults.object(forKey: settingsKey) != nil else { return vorgabe }
        return min(max(defaults.integer(forKey: settingsKey), bereich.lowerBound), bereich.upperBound)
    }
}
