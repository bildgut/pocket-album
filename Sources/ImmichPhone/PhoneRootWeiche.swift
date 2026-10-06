import Foundation

/// Welche Wurzelansicht `PhoneRootView` zeigt — als reiner Wert, damit die
/// Reihenfolge der Bedingungen prüfbar ist (`PhoneRootWeicheTests`).
enum PhoneRootWeiche: Equatable {
    case inhalt, verbindet, unerreichbar, einrichtung

    /// `bereit`: API-Client und `AlbumManager` stehen.
    ///
    /// `.connecting` **ohne** gespeicherte Zugangsdaten kommt nur aus dem Onboarding
    /// („Open Albums“). Dort muss das Onboarding stehen bleiben: Schaltete die Weiche
    /// auf „Verbinde…“, verlöre `OnboardingAblauf` seinen Zustand, und ein Fehlschlag
    /// begänne wortlos wieder beim ersten Schritt.
    static func zweig(state: ConnectionState, istKonfiguriert: Bool, bereit: Bool) -> PhoneRootWeiche {
        if state.canBrowse, bereit { return .inhalt }
        if state.canBrowse || (state == .connecting && istKonfiguriert) { return .verbindet }
        if istKonfiguriert { return .unerreichbar }
        return .einrichtung
    }
}
