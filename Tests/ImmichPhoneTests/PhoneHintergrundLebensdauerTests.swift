import Testing
import UIKit
@testable import ImmichPhone

@Suite("PhoneHintergrundLebensdauer")
struct PhoneHintergrundLebensdauerTests {

    private final class MockTaskManager: @unchecked Sendable {
        var naechsteId = 1
        var aktiveTasks = Set<UIBackgroundTaskIdentifier>()
        var beendeteTasks = [UIBackgroundTaskIdentifier]()
        var gespeicherterHandler: (() -> Void)?
        var abbruchAufgerufen = false

        @MainActor
        func makeLebensdauer() -> PhoneHintergrundLebensdauer {
            PhoneHintergrundLebensdauer(
                startTask: { [weak self] name, handler in
                    guard let self else { return .invalid }
                    let id = UIBackgroundTaskIdentifier(rawValue: self.naechsteId)
                    self.naechsteId += 1
                    self.aktiveTasks.insert(id)
                    self.gespeicherterHandler = handler
                    return id
                },
                endTask: { [weak self] id in
                    guard let self else { return }
                    self.aktiveTasks.remove(id)
                    self.beendeteTasks.append(id)
                },
                abbrechen: { [weak self] in
                    self?.abbruchAufgerufen = true
                }
            )
        }
    }

    @Test("Im Vordergrund wird kein BackgroundTask gestartet")
    @MainActor
    func imVordergrundKeinTask() {
        let mock = MockTaskManager()
        let lebensdauer = mock.makeLebensdauer()

        lebensdauer.syncWechsel(syncLaeuft: true)
        #expect(lebensdauer.aktiverTask == .invalid)
        #expect(mock.aktiveTasks.isEmpty)
    }

    @Test("Wechsel in Hintergrund bei laufendem Sync startet BackgroundTask")
    @MainActor
    func wechselInHintergrundStartetTask() {
        let mock = MockTaskManager()
        let lebensdauer = mock.makeLebensdauer()

        lebensdauer.syncWechsel(syncLaeuft: true)
        lebensdauer.phasenWechsel(istHintergrund: true, syncLaeuft: true)

        #expect(lebensdauer.aktiverTask != .invalid)
        #expect(mock.aktiveTasks.count == 1)
    }

    @Test("Sync-Ende im Hintergrund beendet BackgroundTask")
    @MainActor
    func syncEndeBeendetTask() {
        let mock = MockTaskManager()
        let lebensdauer = mock.makeLebensdauer()

        lebensdauer.phasenWechsel(istHintergrund: true, syncLaeuft: true)
        let taskId = lebensdauer.aktiverTask
        #expect(taskId != .invalid)

        lebensdauer.syncWechsel(syncLaeuft: false)
        #expect(lebensdauer.aktiverTask == .invalid)
        #expect(mock.beendeteTasks == [taskId])
    }

    @Test("Rückkehr in den Vordergrund beendet BackgroundTask")
    @MainActor
    func rueckkehrInVordergrundBeendetTask() {
        let mock = MockTaskManager()
        let lebensdauer = mock.makeLebensdauer()

        lebensdauer.phasenWechsel(istHintergrund: true, syncLaeuft: true)
        let taskId = lebensdauer.aktiverTask
        #expect(taskId != .invalid)

        lebensdauer.phasenWechsel(istHintergrund: false, syncLaeuft: true)
        #expect(lebensdauer.aktiverTask == .invalid)
        #expect(mock.beendeteTasks == [taskId])
    }

    @Test("Ablauf der Frist ruft Abbruch und beendet Task")
    @MainActor
    func fristAblaufBrichtAb() async {
        let mock = MockTaskManager()
        let lebensdauer = mock.makeLebensdauer()

        lebensdauer.phasenWechsel(istHintergrund: true, syncLaeuft: true)
        let taskId = lebensdauer.aktiverTask
        #expect(taskId != .invalid)
        #expect(mock.gespeicherterHandler != nil)

        // Simuliere Ausruf durch iOS
        mock.gespeicherterHandler?()

        // Kurze Atempause für async MainActor-Task
        try? await Task.sleep(for: .milliseconds(20))

        #expect(mock.abbruchAufgerufen)
        #expect(lebensdauer.aktiverTask == .invalid)
        #expect(mock.beendeteTasks.contains(taskId))
    }
}
