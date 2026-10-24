import Foundation

/// Wiederholt einen Offline-Download, wenn die Strecke nur kurz gestockt hat.
///
/// Über lange, verlustreiche Strecken (z. B. Tailscale Japan ↔ Deutschland, ~300 ms)
/// bleibt einzelne Dateien manchmal liegen. Ein zweiter Anlauf holt sie meist nach —
/// ohne ihn zählte jede davon sofort als fehlgeschlagen.
enum OfflineWiederholung {

    /// Wie oft eine Datei insgesamt versucht wird (erster Anlauf + Wiederholungen).
    static let versuche = 3
    /// Wartezeit zwischen zwei Anläufen.
    static let pause: Duration = .seconds(2)

    /// Führt `operation` bis zu `versuche`-mal aus und gibt den **letzten** Fehler weiter.
    /// Abbruch und 4xx (die Datei gibt es nicht / darf man nicht lesen) werden nicht
    /// wiederholt: Ein zweiter Anlauf änderte daran nichts.
    static func mitWiederholung<T>(
        versuche: Int = OfflineWiederholung.versuche,
        pause: Duration = OfflineWiederholung.pause,
        _ operation: () async throws -> T
    ) async throws -> T {
        var letzterFehler: Error = CancellationError()
        for versuch in 1...max(1, versuche) {
            do {
                return try await operation()
            } catch {
                guard lohntWiederholung(error) else { throw error }
                letzterFehler = error
                if versuch < versuche { try await Task.sleep(for: pause) }
            }
        }
        throw letzterFehler
    }

    static func lohntWiederholung(_ fehler: Error) -> Bool {
        if fehler is CancellationError { return false }
        if let url = fehler as? URLError, url.code == .cancelled { return false }
        // 408 (Zeitüberschreitung) und 429 (zu viele Anfragen) sind vorübergehend.
        if case APIError.httpError(let code) = fehler, (400..<500).contains(code), code != 408, code != 429 {
            return false
        }
        return true
    }
}
