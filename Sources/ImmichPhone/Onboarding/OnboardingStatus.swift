import Foundation

/// Ob der Vorspann schon gesehen wurde. Nach Abmelden oder „Zugangsdaten ändern“
/// kommt nur die Einrichtung; wer beim Update schon angemeldet ist, gilt als „gesehen“.
enum OnboardingStatus {
    static let schluessel = "onboardingIntroGesehen"

    /// Reine Abfrage — schreibt nichts, darf also aus `body` gerufen werden.
    static func zeigeVorspann(defaults: UserDefaults = AppEnvironment.defaults) -> Bool {
        !defaults.bool(forKey: schluessel)
    }

    /// Beim Start: Wer schon Zugangsdaten hat, kennt die App — spätere Abmeldungen
    /// führen dann direkt in die Einrichtung. Muss **außerhalb** des Onboarding-Zweigs
    /// laufen, denn der ist mit Zugangsdaten nie erreicht.
    static func merkeBestandsnutzer(istKonfiguriert: Bool, defaults: UserDefaults = AppEnvironment.defaults) {
        if istKonfiguriert { markiereGesehen(defaults: defaults) }
    }

    static func markiereGesehen(defaults: UserDefaults = AppEnvironment.defaults) {
        defaults.set(true, forKey: schluessel)
    }
}
