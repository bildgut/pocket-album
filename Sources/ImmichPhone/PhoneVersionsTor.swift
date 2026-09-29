import Foundation

/// Die Versionsprüfung des Onboardings (``ImmichVersion/mindestens``), auch beim
/// Wiederverbinden.
///
/// Das Onboarding lässt nur Server ab 3.2 zu. Wird der Server danach aber
/// zurückgespielt (oder die App hatte ihn vor der Prüfung schon gespeichert),
/// scheiterte jede strukturierte Suche still mit HTTP 400 — Fotos- und
/// Entdecken-Reiter blieben leer, ohne Grund. Stattdessen wird die Verbindung
/// als Fehler mit derselben Meldung wie im Onboarding gemeldet; die Wurzel-Weiche
/// zeigt sie dann groß samt „Erneut versuchen" und „Zugangsdaten ändern".
enum PhoneVersionsTor {

    /// Meldung für einen zu alten Server, sonst `nil`. Eine unlesbare Version
    /// sperrt nicht — lieber einzelne Fehler als ein ausgesperrter Nutzer.
    static func meldung(fuerVersion text: String) -> String? {
        guard let version = ImmichVersion(text), version < .mindestens else { return nil }
        return OnboardingTexts.serverZuAlt(version.description)
    }

    /// Setzt eine bestehende Verbindung zu einem zu alten Server auf `.error`.
    @MainActor
    static func pruefe(_ connection: ConnectionManager) {
        guard case .connected(let version) = connection.state,
              let meldung = meldung(fuerVersion: version) else { return }
        AppLogger.connection.error("Server zu alt: \(version, privacy: .public)")
        connection.state = .error(meldung)
    }
}
