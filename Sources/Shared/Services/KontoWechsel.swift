import Foundation

/// Merkt sich, welches Konto zuletzt angemeldet war, und erkennt einen Wechsel.
///
/// `disconnect()` räumt den Store bewusst nicht ab (siehe ``AccountDataPurge``). Wer
/// sich danach mit dem Schlüssel eines **anderen** Kontos anmeldet — am selben oder
/// an einem anderen Server —, sah bisher zunächst Alben und Fotos des vorigen. Die
/// Kennung liegt deshalb in `UserDefaults`, nicht in der Keychain: Sie muss das
/// Abmelden überleben, sonst gäbe es beim nächsten Anmelden nichts zu vergleichen.
enum KontoWechsel {

    static let schluessel = "letzteKontoKennung"

    /// Nur ein **bekanntes** anderes Konto ist ein Wechsel. Keine frühere Kennung
    /// (Erstanmeldung, Update von einer Version ohne diesen Merker) oder keine neue
    /// (nicht ermittelbar) ist keiner — gelöscht wird nur auf Gewissheit.
    static func istWechsel(bisher: String?, neu: String?) -> Bool {
        guard let bisher, let neu else { return false }
        return bisher != neu
    }

    static func bisher(_ defaults: UserDefaults) -> String? {
        defaults.string(forKey: schluessel)
    }

    static func merke(_ kennung: String?, in defaults: UserDefaults) {
        guard let kennung else { return }
        defaults.set(kennung, forKey: schluessel)
    }

    // MARK: - Rückfall über die Zugangsdaten

    static let zugangSchluessel = "letzterZugang"

    /// Fingerabdruck aus Server-Adresse und API-Key — der Key selbst landet nie in
    /// den `UserDefaults`.
    static func zugang(serverURL: String, apiKey: String) -> String {
        "\(serverURL.lowercased())|\(KeyRechteSpeicher.fingerabdruck(apiKey))"
    }

    /// Mit Rückfall, wenn eine der beiden Kennungen fehlt.
    ///
    /// **Bewusste Entscheidung:** Ist das Konto nicht ermittelbar (Schlüssel ohne
    /// `user.read` und ohne eigenes Album), aber die Zugangsdaten sind andere als beim
    /// letzten Mal (anderer Server **oder** anderer Key), wird vorsichtshalber geleert.
    /// Ein falsches „Wechsel“ kostet einen Nachsync und neu geladene Offline-Alben; ein
    /// falsches „kein Wechsel“ zeigt Fotos eines fremden Kontos. Kein früherer Zugang
    /// (Erstanmeldung, Update) bleibt „kein Wechsel“ — dann gibt es nichts Fremdes.
    static func istWechsel(bisher: String?, neu: String?,
                           bisherZugang: String?, neuZugang: String) -> Bool {
        if let bisher, let neu { return bisher != neu }
        guard let bisherZugang else { return false }
        return bisherZugang != neuZugang
    }

    static func bisherZugang(_ defaults: UserDefaults) -> String? {
        defaults.string(forKey: zugangSchluessel)
    }

    static func merkeZugang(_ zugang: String, in defaults: UserDefaults) {
        defaults.set(zugang, forKey: zugangSchluessel)
    }
}
