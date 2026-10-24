import Testing
import SwiftUI
@testable import ImmichPhone

@Suite("PhoneOfflineProgressBanner")
struct PhoneOfflineProgressBannerTests {

    @Test("LabelText zeigt Vorbereitung wenn noch keine Gesamtanzahl feststeht")
    @MainActor
    func labelTextVorbereitung() {
        let fortschritt = OfflineSyncProgress.shared
        let alterZustand = fortschritt.isActive
        let alterTotal = fortschritt.total
        let alterCompleted = fortschritt.completed
        let alterName = fortschritt.currentPinName
        defer {
            fortschritt.isActive = alterZustand
            fortschritt.total = alterTotal
            fortschritt.completed = alterCompleted
            fortschritt.currentPinName = alterName
        }

        fortschritt.isActive = true
        fortschritt.total = 0
        fortschritt.completed = 0
        fortschritt.currentPinName = "Favoriten"

        #expect(fortschritt.labelText.contains("Preparing") || fortschritt.labelText.contains("Vorbereitung"))
    }

    @Test("LabelText zeigt geladene Dateien und den aktuellen Quellennamen")
    @MainActor
    func labelTextFortschrittMitQuelle() {
        let fortschritt = OfflineSyncProgress.shared
        let alterZustand = fortschritt.isActive
        let alterTotal = fortschritt.total
        let alterCompleted = fortschritt.completed
        let alterName = fortschritt.currentPinName
        defer {
            fortschritt.isActive = alterZustand
            fortschritt.total = alterTotal
            fortschritt.completed = alterCompleted
            fortschritt.currentPinName = alterName
        }

        fortschritt.isActive = true
        fortschritt.total = 42
        fortschritt.completed = 15
        fortschritt.currentPinName = "Favoriten"

        let text = fortschritt.labelText
        #expect(text.contains("15/42"))
        #expect(text.contains("Favoriten"))
    }

    @Test("Fortschritts-Berechnung liefert korrekten Quotienten")
    @MainActor
    func fortschrittsBerechnung() {
        let fortschritt = OfflineSyncProgress.shared
        let alterTotal = fortschritt.total
        let alterCompleted = fortschritt.completed
        defer {
            fortschritt.total = alterTotal
            fortschritt.completed = alterCompleted
        }

        fortschritt.total = 100
        fortschritt.completed = 50
        #expect(fortschritt.progress == 0.5)

        fortschritt.total = 0
        #expect(fortschritt.progress == 0)
    }

    @Test("phoneOfflineProgressBanner Modifier lässt sich an eine View anheften")
    @MainActor
    func modifierErzeugtView() {
        let testView = Text("Test").phoneOfflineProgressBanner()
        #expect(testView != nil)
    }
}
