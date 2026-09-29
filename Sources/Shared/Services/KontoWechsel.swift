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
}
