import UIKit
import BackgroundTasks
import SwiftData

/// Verwaltet geplante Hintergrundläufe via `BGTaskScheduler`.
///
/// Bietet zwei Arten von Tasks:
/// 1. `refresh` (`BGAppRefreshTask`): Ein kurzer Lauf alle paar Stunden, um den Zustand abzugleichen.
/// 2. `processing` (`BGProcessingTask`): Ein längerer Wartungslauf (vorzugsweise nachts am Ladekabel und im WLAN),
///    um fehlende Offline-Quellen (`OfflineDownloadManager.nachholen`) herunterzuladen.
@MainActor
final class PhoneHintergrundDienst {
    static let shared = PhoneHintergrundDienst()

    static let refreshIdentifier = "com.ralksta.pocketalbum.refresh"
    static let processingIdentifier = "com.ralksta.pocketalbum.processing"

    private(set) var connection: ConnectionManager?
    private(set) var container: ModelContainer?

    func konfiguriere(connection: ConnectionManager, container: ModelContainer = PhoneModelContainer.shared) {
        self.connection = connection
        self.container = container
    }

    /// Registriert die Hintergrund-Aufgaben bei iOS. MUSS beim App-Start gerufen werden.
    func registrieren() {
        guard !AppEnvironment.isRunningTests else { return }

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.refreshIdentifier,
            using: nil
        ) { [weak self] task in
            guard let refreshTask = task as? BGAppRefreshTask else { return }
            self?.fuehreRefreshAus(task: refreshTask)
        }

        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.processingIdentifier,
            using: nil
        ) { [weak self] task in
            guard let processingTask = task as? BGProcessingTask else { return }
            self?.fuehreProcessingAus(task: processingTask)
        }
    }

    /// Plant die nächsten Hintergrundläufe ein (beim Wechsel in den Hintergrund).
    func planeNaechsteLaeufe() {
        guard !AppEnvironment.isRunningTests else { return }
        planeRefresh()
        planeProcessing()
    }

    func planeRefresh() {
        let anfrage = BGAppRefreshTaskRequest(identifier: Self.refreshIdentifier)
        // Frühestens in 20 Minuten
        anfrage.earliestBeginDate = Date(timeIntervalSinceNow: 20 * 60)
        do {
            try BGTaskScheduler.shared.submit(anfrage)
        } catch {
            AppLogger.cache.error("PhoneHintergrundDienst: Konnte Refresh nicht planen: \(error)")
        }
    }

    func planeProcessing() {
        let anfrage = BGProcessingTaskRequest(identifier: Self.processingIdentifier)
        anfrage.requiresNetworkConnectivity = true
        anfrage.requiresExternalPower = true
        // Frühestens in 1 Stunde
        anfrage.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60)
        do {
            try BGTaskScheduler.shared.submit(anfrage)
        } catch {
            AppLogger.cache.error("PhoneHintergrundDienst: Konnte Processing nicht planen: \(error)")
        }
    }

    private func fuehreRefreshAus(task: BGAppRefreshTask) {
        planeRefresh()
        fuehreSyncAus(task: task)
    }

    private func fuehreProcessingAus(task: BGProcessingTask) {
        planeProcessing()
        fuehreSyncAus(task: task)
    }

    /// Führt den eigentlichen Offline-Lauf aus.
    ///
    /// Wichtig: Wenn der Server / Tailscale nicht erreichbar ist, bricht der Lauf
    /// still mit `setTaskCompleted(success: true)` ab, damit iOS die App nicht als
    /// fehlerhaft einstuft und der Nutzer keine Störmeldungen erhält.
    func fuehreSyncAus(task: BGTask) {
        task.expirationHandler = {
            Task {
                await OfflineDownloadManager.shared.cancel(grund: "Hintergrundaufgabe abgelaufen")
            }
        }

        Task { @MainActor in
            guard let client = connection?.apiClient,
                  let c = container ?? (try? PhoneModelContainer.shared) else {
                task.setTaskCompleted(success: true)
                return
            }

            // Kurzer Erreichbarkeits-Check mit 6 s Timeout (kurzeFrist).
            // Wenn Tailscale aus oder Server nicht im Netz ist, sofort still abbrechen.
            let erreichbar = await pruefeErreichbarkeit(client: client)
            guard erreichbar else {
                task.setTaskCompleted(success: true)
                return
            }

            await OfflineDownloadManager.shared.nachholen(container: c, apiClient: client, ausloeser: "Hintergrundaufgabe")
            task.setTaskCompleted(success: true)
        }
    }

    func pruefeErreichbarkeit(client: ImmichAPIClient) async -> Bool {
        let pruefer = ImmichAPIClient(
            baseURL: client.baseURL,
            apiKey: client.apiKey,
            sessionConfiguration: client.sessionConfiguration,
            anfrageFrist: ImmichAPIClient.kurzeFrist
        )
        do {
            return try await pruefer.ping()
        } catch {
            return false
        }
    }
}
