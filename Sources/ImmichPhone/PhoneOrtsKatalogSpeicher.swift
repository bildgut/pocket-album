import Foundation

/// Liest und schreibt den Ortskatalog als JSON. Bewusst kein SwiftData-`@Model`:
/// Ein neues Modell zwänge den geteilten `ModelContainer` in eine weitere
/// Schema-Stufe, und der Katalog ist Wegwerfdaten — fehlt er, wird er neu gebaut.
struct PhoneOrtsKatalogSpeicher: Sendable {
    let datei: URL

    static var standard: PhoneOrtsKatalogSpeicher {
        PhoneOrtsKatalogSpeicher(datei: AppEnvironment.supportDirectory.appending(path: "orte_katalog.json"))
    }

    /// `nil`, wenn nichts da ist, die Datei nicht lesbar ist, eine andere Version
    /// trägt oder zu einem anderen Server gehört. Wirft nie: Ein kaputter Katalog
    /// ist ein fehlender Katalog, kein Fehler, den jemand sehen muss.
    func laden(basis: URL) -> PhoneOrtsKatalog? {
        guard let data = try? Data(contentsOf: datei) else { return nil }
        let katalog: PhoneOrtsKatalog
        do {
            katalog = try JSONDecoder().decode(PhoneOrtsKatalog.self, from: data)
        } catch {
            AppLogger.cache.error("Ortskatalog nicht lesbar, wird neu aufgebaut: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard katalog.version == PhoneOrtsKatalog.aktuelleVersion,
              katalog.basis == basis.absoluteString
        else { return nil }
        return katalog
    }

    func speichern(_ katalog: PhoneOrtsKatalog) throws {
        try JSONEncoder().encode(katalog).write(to: datei, options: .atomic)
    }

    func loeschen() {
        try? FileManager.default.removeItem(at: datei)
    }
}
