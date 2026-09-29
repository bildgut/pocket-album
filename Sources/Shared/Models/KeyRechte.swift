import CryptoKit
import Foundation

/// Was der API-Key darf — damit die Oberfläche Aktionen ausblendet, die ohnehin
/// scheitern würden (Nur-Lese-Keys: kein Favorit, kein Löschen).
///
/// Zwei Quellen:
/// - **gemeldet**: `GET /api/api-keys/me` beim Verbinden. Der Endpunkt verlangt
///   selbst kein Recht. `nil` heißt unbekannt (Abruf gescheitert, offline) —
///   dann wird nichts gesperrt, und ein Fehlschlag lehrt es.
/// - **abgelehnt**: Rechte, an denen ein Aufruf mit 403 gescheitert ist. Fängt
///   ab, was die Meldung nicht weiß, und wird je Key gespeichert
///   (``KeyRechteSpeicher``).
struct KeyRechte: Equatable, Sendable {
    /// `PUT /api/assets/:id` — Favorit setzen.
    static let favorit = "asset.update"
    /// `DELETE /api/assets` — in den Papierkorb legen.
    static let loeschen = "asset.delete"

    var gemeldet: Set<String>?
    var abgelehnt: Set<String> = []

    func darf(_ recht: String) -> Bool {
        if abgelehnt.contains(recht) { return false }
        guard let gemeldet else { return true }
        return gemeldet.contains("all") || gemeldet.contains(recht)
    }

    mutating func merkeAbgelehnt(_ recht: String) {
        abgelehnt.insert(recht)
    }

    /// Übernimmt eine frische Meldung des Servers. Ein Recht, das dort (wieder)
    /// steht, hebt die gelernte Sperre auf: Die Rechte eines Keys lassen sich in
    /// Immich nachträglich ändern, und die Meldung ist jünger als der 403.
    mutating func uebernimmMeldung(_ rechte: Set<String>) {
        gemeldet = rechte
        if rechte.contains("all") {
            abgelehnt.removeAll()
        } else {
            abgelehnt.subtract(rechte)
        }
    }
}

/// Speichert gelernte Sperren je Key. Abgelegt wird nur ein Fingerabdruck
/// (SHA-256) des Keys, nie der Key selbst — der gehört in die Keychain.
enum KeyRechteSpeicher {
    private static let schluessel = "keyRechte.abgelehnt.v1"

    private struct Eintrag: Codable {
        let fingerabdruck: String
        let abgelehnt: [String]
    }

    static func fingerabdruck(_ apiKey: String) -> String {
        SHA256.hash(data: Data(apiKey.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func ladeAbgelehnt(apiKey: String, defaults: UserDefaults = AppEnvironment.defaults) -> Set<String> {
        guard let daten = defaults.data(forKey: schluessel),
              let eintrag = try? JSONDecoder().decode(Eintrag.self, from: daten),
              eintrag.fingerabdruck == fingerabdruck(apiKey)
        else { return [] }
        return Set(eintrag.abgelehnt)
    }

    static func speichereAbgelehnt(_ abgelehnt: Set<String>, apiKey: String, defaults: UserDefaults = AppEnvironment.defaults) {
        let eintrag = Eintrag(fingerabdruck: fingerabdruck(apiKey), abgelehnt: abgelehnt.sorted())
        if let daten = try? JSONEncoder().encode(eintrag) {
            defaults.set(daten, forKey: schluessel)
        }
    }

    static func vergiss(defaults: UserDefaults = AppEnvironment.defaults) {
        defaults.removeObject(forKey: schluessel)
    }
}
