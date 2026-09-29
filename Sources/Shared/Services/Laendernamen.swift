import Foundation

/// Deutsche Anzeige für die Ländernamen, die Immich liefert.
///
/// Immich führt Länder **englisch**, teils in der amtlichen Langform („Islamic Republic
/// of Iran", „United States of America"); Städte und Regionen dagegen gemischt
/// (Munich neben Köln). Übersetzt werden hier nur Länder — für sie gibt es über den
/// ISO-Code eine verlässliche Zuordnung, für Städte nicht.
///
/// **Nur für die Anzeige.** Filter, Katalog und Suchtreffer tragen weiter den
/// Servernamen, denn den erwartet `SearchFilter.country`.
///
/// Standard ist Deutsch, wie alle Texte der Mac-App; der iOS-Client übergibt die
/// Gerätesprache (``anzeigename(fuer:sprache:)``). Liegt in `Shared`,
/// weil auch die Mac-Suche deutsche Ländernamen auf Servernamen abbildet
/// (``servernamen(fuerDeutsch:katalog:)``).
enum Laendernamen {

    private static let deutsch = Locale(identifier: "de_DE")

    /// Immichs Namen, die Apples englische Länderliste anders führt — gemessen am
    /// 13.09.2026 an den 25 Ländern des eigenen Servers. Ein weiteres Land, das hier
    /// fehlt, erscheint schlicht englisch.
    private static let ausnahmen: [String: String] = [
        "bosnia and herzegovina": "BA",
        "czech republic": "CZ",
        "islamic republic of iran": "IR",
        "united states of america": "US",
    ]

    /// Apples englischer Name → ISO-Code, einmal aufgebaut.
    private static let englischZuCode: [String: String] = {
        let englisch = Locale(identifier: "en_US")
        var zuordnung: [String: String] = [:]
        for region in Locale.Region.isoRegions {
            if let name = englisch.localizedString(forRegionCode: region.identifier) {
                zuordnung[schluessel(name)] = region.identifier
            }
        }
        return zuordnung
    }()

    /// Apples deutscher Name → ISO-Code, einmal aufgebaut.
    private static let deutschZuCode: [String: String] = {
        var zuordnung: [String: String] = [:]
        for region in Locale.Region.isoRegions {
            if let name = deutsch.localizedString(forRegionCode: region.identifier) {
                zuordnung[schluessel(name)] = region.identifier
            }
        }
        return zuordnung
    }()

    /// ISO-Code zum Servernamen, `nil` wenn unbekannt.
    static func regionCode(fuer servername: String) -> String? {
        let key = schluessel(servername)
        return ausnahmen[key] ?? englischZuCode[key]
    }

    /// „Greece" → „Griechenland". Unbekannte Namen kommen unverändert zurück.
    static func anzeigename(fuer servername: String, sprache: Locale = deutsch) -> String {
        guard let code = regionCode(fuer: servername),
              let name = sprache.localizedString(forRegionCode: code)
        else { return servername }
        return name
    }

    /// „Italien" → die Servernamen aus `katalog`, die dasselbe Land meinen („Italy").
    ///
    /// Nur ganze Namen, kein Präfix: Die Suche zerlegt Sätze Wort für Wort, und „Ital"
    /// ist dort kein Land. Mehrere Treffer sind möglich, wenn der Server dasselbe Land
    /// unter zwei Schreibweisen führt.
    static func servernamen(fuerDeutsch eingabe: String, katalog: [String]) -> [String] {
        guard let code = deutschZuCode[schluessel(eingabe)] else { return [] }
        return katalog.filter { regionCode(fuer: $0) == code }
    }

    private static func schluessel(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
