import Foundation

/// Ein Eintrag unter „Zuletzt gesucht“. `titel` ist die fertige Beschriftung zum
/// Zeitpunkt des Merkens — Namen ändern sich selten, und nachschlagen hieße Netz.
struct PhoneZuletztEintrag: Codable, Hashable, Identifiable {
    let auswahl: PhoneSuchAuswahl
    let personenNamen: [String: String]
    let titel: String
    let anzahl: Int?
    var id: PhoneSuchAuswahl { auswahl }
}

/// „Zuletzt gesucht“: nur auf dem Gerät, je Server (Basis-URL), höchstens ``maximum``.
/// Abmelden und „Zugangsdaten ändern“ löschen alles (`PhoneOrtsModell.leere()`).
enum PhoneZuletztGesucht {
    static let maximum = 5
    private static let schluessel = "entdecken.zuletzt.v1"

    private static func alle(_ defaults: UserDefaults) -> [String: [PhoneZuletztEintrag]] {
        guard let daten = defaults.data(forKey: schluessel),
              let werte = try? JSONDecoder().decode([String: [PhoneZuletztEintrag]].self, from: daten)
        else { return [:] }
        return werte
    }

    private static func schreibe(_ werte: [String: [PhoneZuletztEintrag]], _ defaults: UserDefaults) {
        if let daten = try? JSONEncoder().encode(werte) { defaults.set(daten, forKey: schluessel) }
    }

    static func lade(basis: String, defaults: UserDefaults = AppEnvironment.defaults) -> [PhoneZuletztEintrag] {
        alle(defaults)[basis] ?? []
    }

    /// Vorn einfügen; dieselbe Auswahl rückt nach oben statt doppelt zu stehen.
    static func merke(_ eintrag: PhoneZuletztEintrag, basis: String, defaults: UserDefaults = AppEnvironment.defaults) {
        var werte = alle(defaults)
        var liste = (werte[basis] ?? []).filter { $0.auswahl != eintrag.auswahl }
        liste.insert(eintrag, at: 0)
        werte[basis] = Array(liste.prefix(maximum))
        schreibe(werte, defaults)
    }

    static func entferne(_ auswahl: PhoneSuchAuswahl, basis: String, defaults: UserDefaults = AppEnvironment.defaults) {
        var werte = alle(defaults)
        werte[basis] = (werte[basis] ?? []).filter { $0.auswahl != auswahl }
        schreibe(werte, defaults)
    }

    static func vergiss(defaults: UserDefaults = AppEnvironment.defaults) {
        defaults.removeObject(forKey: schluessel)
    }
}
