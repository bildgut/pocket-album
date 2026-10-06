import Foundation

/// Wie der Verbindungszustand in den Einstellungen erscheint — Text und Symbol als
/// reiner Wertetyp, damit die Zuordnung geprüft werden kann, ohne eine Ansicht zu
/// bauen.
///
/// Derselbe Gedanke wie bei ``PhoneStorageSummary``: `ConnectionState`
/// (`Sources/Shared/Services/ConnectionManager.swift:5`) ist ein Enum mit
/// zugeordneten Werten, und genau diese Werte — die Serverversion, die
/// Fehlermeldung — sind die Stelle, an der eine Ansicht still etwas Falsches
/// zeigen kann (eine leere Version hinter einem Mittelpunkt, eine leere
/// Fehlermeldung als ganze Zeile). Beides steht hier und ist damit prüfbar.
///
/// **Kein `Text`-Literal irgendwo:** Die zusammengesetzten Zeichenfolgen gehen als
/// `String` in die Ansicht. SwiftUI parst `Text`-Literale als Markdown, und eine
/// Fehlermeldung des Servers kann durchaus eine URL enthalten — als Literal würde
/// daraus ein `Link`, der Taps schluckt.
struct PhoneServerStatus: Equatable, Sendable {

    /// Die Zeile, die neben „Zustand" steht.
    let text: String
    /// SF-Symbol davor.
    let symbol: String
    /// Nur bei `.connected` wahr — die Ansicht färbt das Symbol dann mit
    /// `Marke.akzent` statt grau. `.offline` ist ausdrücklich **nicht** verbunden:
    /// Es heißt „zeigt Zwischengespeichertes", nicht „Server antwortet".
    let istVerbunden: Bool

    static func from(_ state: ConnectionState) -> PhoneServerStatus {
        switch state {
        case .connected(let version):
            // Die Version kommt vom Server und kann leer sein (`getServerVersion`
            // liefert eine zusammengesetzte Zeichenfolge). Ein Mittelpunkt mit
            // nichts dahinter sähe nach einem Anzeigefehler aus.
            let sauber = version.trimmingCharacters(in: .whitespacesAndNewlines)
            return PhoneServerStatus(
                text: sauber.isEmpty ? String(localized: "Connected") : String(localized: "Connected · Immich \(sauber)"),
                symbol: "checkmark.circle.fill",
                istVerbunden: true
            )
        case .offline:
            return PhoneServerStatus(
                text: String(localized: "Offline · showing saved data"),
                symbol: "wifi.slash",
                istVerbunden: false
            )
        case .connecting:
            return PhoneServerStatus(
                text: String(localized: "Connecting…"),
                symbol: "arrow.triangle.2.circlepath",
                istVerbunden: false
            )
        case .disconnected:
            return PhoneServerStatus(
                text: String(localized: "Not Connected"),
                symbol: "xmark.circle",
                istVerbunden: false
            )
        case .error(let meldung):
            // Wie in `PhoneStorageSummary.Eintrag.zustand`: Leerraum ist keine
            // Meldung. Eine leere Fehlerzeile wäre schlechter als das nackte Wort.
            let sauber = meldung.trimmingCharacters(in: .whitespacesAndNewlines)
            return PhoneServerStatus(
                text: sauber.isEmpty ? String(localized: "Error") : String(localized: "Error · \(sauber)"),
                symbol: "exclamationmark.triangle",
                istVerbunden: false
            )
        }
    }
}
