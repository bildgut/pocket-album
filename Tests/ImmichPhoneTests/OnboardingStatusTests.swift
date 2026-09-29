import Foundation
import Testing
@testable import ImmichPhone

@Suite("OnboardingStatus")
struct OnboardingStatusTests {
    private func frisch() -> UserDefaults { UserDefaults(suiteName: "OnboardingStatus-\(UUID().uuidString)")! }

    @Test("Erster Start ohne Zugangsdaten: Vorspann")
    func ersterStart() {
        #expect(OnboardingStatus.zeigeVorspann(defaults: frisch()))
    }

    @Test("Nach dem Sehen nicht noch einmal — auch nach Abmelden")
    func gesehen() {
        let d = frisch()
        OnboardingStatus.markiereGesehen(defaults: d)
        #expect(!OnboardingStatus.zeigeVorspann(defaults: d))
    }

    @Test("Wer beim Update schon angemeldet ist, gilt als „gesehen“")
    func bestandsnutzer() {
        let d = frisch()
        OnboardingStatus.merkeBestandsnutzer(istKonfiguriert: true, defaults: d)
        #expect(!OnboardingStatus.zeigeVorspann(defaults: d))
    }

    @Test("Ohne Zugangsdaten macht die Bestandsprüfung nichts")
    func keinBestandsnutzer() {
        let d = frisch()
        OnboardingStatus.merkeBestandsnutzer(istKonfiguriert: false, defaults: d)
        #expect(OnboardingStatus.zeigeVorspann(defaults: d))
    }
}
