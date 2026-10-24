import UIKit

/// Hält laufende Offline-Downloads am Leben, wenn die App in den Hintergrund wechselt
/// oder der Bildschirm gesperrt wird.
///
/// iOS gewährt über `UIApplication.beginBackgroundTask` etwa 30 Sekunden zusätzliche
/// Ausführungszeit. Reicht das nicht für alle ausstehenden Dateien, wird vor Ablauf
/// der Frist `cancelSync()` gerufen, damit der Lader sauber stoppt und keine unvollständigen
/// Dateien oder hängende Sockets hinterlässt.
@MainActor
final class PhoneHintergrundLebensdauer {
    typealias TaskStarter = (_ name: String, _ expirationHandler: (() -> Void)?) -> UIBackgroundTaskIdentifier
    typealias TaskEnder = (UIBackgroundTaskIdentifier) -> Void
    typealias Abbrecher = () async -> Void

    private let startTask: TaskStarter
    private let endTask: TaskEnder
    private let abbrechen: Abbrecher

    private(set) var aktiverTask: UIBackgroundTaskIdentifier = .invalid
    private(set) var imHintergrund: Bool = false

    init(
        startTask: @escaping TaskStarter = { name, handler in
            UIApplication.shared.beginBackgroundTask(withName: name, expirationHandler: handler)
        },
        endTask: @escaping TaskEnder = { id in
            UIApplication.shared.endBackgroundTask(id)
        },
        abbrechen: @escaping Abbrecher = {
            await OfflineDownloadManager.shared.cancel(grund: "Hintergrundzeit abgelaufen (~30 s nach Sperre/App-Wechsel)")
        }
    ) {
        self.startTask = startTask
        self.endTask = endTask
        self.abbrechen = abbrechen
    }

    /// Wird gerufen, wenn sich der App-Zustand (Vordergrund/Hintergrund) ändert.
    func phasenWechsel(istHintergrund: Bool, syncLaeuft: Bool) {
        imHintergrund = istHintergrund
        abgleichen(syncLaeuft: syncLaeuft)
    }

    /// Wird gerufen, wenn sich der Sync-Zustand (`OfflineSyncProgress.shared.isActive`) ändert.
    func syncWechsel(syncLaeuft: Bool) {
        abgleichen(syncLaeuft: syncLaeuft)
    }

    private func abgleichen(syncLaeuft: Bool) {
        if imHintergrund && syncLaeuft {
            sichereHintergrundZeit()
        } else {
            beendeHintergrundZeit()
        }
    }

    private func sichereHintergrundZeit() {
        guard aktiverTask == .invalid else { return }
        aktiverTask = startTask("OfflineSync") { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.abbrechen()
                self.beendeHintergrundZeit()
            }
        }
    }

    private func beendeHintergrundZeit() {
        guard aktiverTask != .invalid else { return }
        let id = aktiverTask
        aktiverTask = .invalid
        endTask(id)
    }
}
