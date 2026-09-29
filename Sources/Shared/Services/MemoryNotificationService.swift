import Foundation
import UserNotifications
import SwiftUI

// MARK: - MemoryNotificationService
//
// Schedules a daily local notification for "Erinnerungen" (On This Day).
// The notification fires at a user-configurable time (default 09:00).
// Tapping it opens the app and deep-links into the correct memory year.
//
// Usage:
//   await MemoryNotificationService.shared.requestAuthorisationIfNeeded()
//   await MemoryNotificationService.shared.scheduleDaily(hour: 9, minute: 0, apiClient: client)
//   MemoryNotificationService.shared.cancel()

@MainActor
final class MemoryNotificationService: NSObject, ObservableObject {

    static let shared = MemoryNotificationService()

    // MARK: Published state
    @Published var authorizationStatus: UNAuthorizationStatus = .notDetermined
    @Published var isScheduled: Bool = false

    // MARK: Private constants
    private let categoryIdentifier  = "MEMORY_DAILY"
    private let requestIdentifier   = "immichmac.memory.daily"

    // MARK: - Init
    private override init() {
        super.init()
    }

    // MARK: - Public API

    /// Ask for notification permission (only prompts user once; subsequent calls are no-ops).
    func requestAuthorisationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        authorizationStatus = settings.authorizationStatus

        guard settings.authorizationStatus == .notDetermined else { return }

        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            authorizationStatus = granted ? .authorized : .denied
        } catch {
            AppLogger.app.error("Notification auth error: \(error)")
        }
    }

    /// Refresh the cached `authorizationStatus` from the system.
    func refreshStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationStatus = settings.authorizationStatus
        // Check if our identifier is still pending
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        isScheduled = pending.contains { $0.identifier == requestIdentifier }
    }

    /// Schedule (or re-schedule) the daily memory notification at `hour`:`minute`.
    /// Fetches today's memories from the API to build a meaningful body text.
    func scheduleDaily(hour: Int, minute: Int, apiClient: ImmichAPIClient?) async {
        let center = UNUserNotificationCenter.current()

        // Cancel existing before rescheduling
        center.removePendingNotificationRequests(withIdentifiers: [requestIdentifier])

        guard authorizationStatus == .authorized else { return }

        // Build content — try to enrich with live memory data
        let content = await buildContent(apiClient: apiClient)

        // Daily repeating trigger at hh:mm local time
        var dateComponents = DateComponents()
        dateComponents.hour   = hour
        dateComponents.minute = minute
        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)

        let request = UNNotificationRequest(
            identifier: requestIdentifier,
            content: content,
            trigger: trigger
        )

        do {
            try await center.add(request)
            isScheduled = true
            AppLogger.app.info("Memory notification scheduled for \(hour):\(String(format: "%02d", minute))")
        } catch {
            AppLogger.app.error("Failed to schedule memory notification: \(error)")
        }
    }

    /// Remove the daily notification.
    func cancel() {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [requestIdentifier])
        isScheduled = false
        AppLogger.app.info("Memory notification cancelled")
    }

    // MARK: - Content Builder

    private func buildContent(apiClient: ImmichAPIClient?) async -> UNMutableNotificationContent {
        // Try fetching today's memory years for a richer message
        if let client = apiClient,
           // Nur die heutigen — ohne `for` zählte die Mitteilung jede je angelegte
           // Erinnerung mit (auf diesem Server 445 statt 10).
           let memories = try? await client.getMemories(for: Date()),
           !memories.isEmpty {

            // Group by year — same logic as MemoriesView
            var assetsByYear: [Int: Int] = [:]
            for m in memories {
                guard let year = m.data?.year,
                      let assets = m.assets, !assets.isEmpty else { continue }
                assetsByYear[year, default: 0] += assets.count
            }

            let currentYear = Calendar.current.component(.year, from: Date())

            if let message = Self.message(assetsByYear: assetsByYear, currentYear: currentYear) {
                let c = UNMutableNotificationContent()
                c.title = "Erinnerungen 📷"
                c.body  = message.body
                c.sound = .default
                c.categoryIdentifier = categoryIdentifier
                if let year = message.deepLinkYear { c.userInfo = ["year": year] }
                return c
            }
        }

        return defaultContent()
    }

    /// Der Text der täglichen Erinnerung, getrennt von `UNMutableNotificationContent` —
    /// so ist er prüfbar, ohne das Benachrichtigungssystem anzufassen.
    ///
    /// - Returns: `nil`, wenn keine Jahre mit Fotos vorliegen. Dann greift
    ///   ``defaultContent()``.
    nonisolated static func message(
        assetsByYear: [Int: Int],
        currentYear: Int
    ) -> MemoryNotificationMessage? {
        let years = assetsByYear.keys.sorted(by: >)
        guard let neuestes = years.first else { return nil }

        if years.count == 1 {
            let diff  = currentYear - neuestes
            let count = assetsByYear[neuestes] ?? 0
            return MemoryNotificationMessage(
                body: "Vor \(diff) \(jahrForm(diff)): \(count) \(fotoForm(count))",
                deepLinkYear: neuestes
            )
        }

        let gesamt = assetsByYear.values.reduce(0, +)
        // `years` ist absteigend sortiert und nicht leer — das älteste steht hinten.
        let aeltesterAbstand = currentYear - (years.last ?? neuestes)
        return MemoryNotificationMessage(
            body: "\(years.count) Jahres-Erinnerungen · \(gesamt) \(fotoForm(gesamt))"
                + " · bis vor \(aeltesterAbstand) \(jahrForm(aeltesterAbstand))",
            deepLinkYear: neuestes
        )
    }

    /// Der Einjahresfall beugte „Jahr/Jahren", der Mehrjahresfall nicht — bei genau
    /// einem Jahr Abstand stand dort „bis vor 1 Jahren". Eine Form für beide.
    private nonisolated static func jahrForm(_ n: Int) -> String {
        n == 1 ? "Jahr" : "Jahren"
    }

    private nonisolated static func fotoForm(_ n: Int) -> String {
        n == 1 ? "Foto" : "Fotos"
    }

    private func defaultContent() -> UNMutableNotificationContent {
        let c = UNMutableNotificationContent()
        c.title = "Erinnerungen 📷"
        c.body  = "Schau was heute vor einigen Jahren passiert ist."
        c.sound = .default
        c.categoryIdentifier = categoryIdentifier
        return c
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension MemoryNotificationService: UNUserNotificationCenterDelegate {

    /// Called when notification is tapped while app is in background or closed.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        // Apple-Fotos-Mitteilung: Importfenster öffnen. Die App nach vorn holen
        // übernimmt MainView — Shared bleibt AppKit-frei.
        if userInfo[ApplePhotosMeldung.userInfoKey] as? Bool == true {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .applePhotosSyncPromptRequested, object: nil)
            }
        }
        if let year = userInfo["year"] as? Int {
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .openMemoryDeepLink,
                    object: nil,
                    userInfo: ["year": year]
                )
            }
        }
        completionHandler()
    }

    /// Show notification as banner even when app is in foreground.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

/// Der Textinhalt der täglichen Erinnerung.
struct MemoryNotificationMessage: Equatable {
    let body: String
    /// Jahr, das ein Tipp auf die Mitteilung öffnet.
    let deepLinkYear: Int?
}
