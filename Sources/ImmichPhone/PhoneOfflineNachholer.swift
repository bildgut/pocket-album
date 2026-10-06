import SwiftUI
import SwiftData

/// Stößt am Telefon Offline-Läufe an, die am Mac die SyncEngine anstößt: beim
/// Start (sobald ein Client steht) und bei jeder Rückkehr in den Vordergrund.
/// Ohne das lüde ein Album, das beim App-Ende mitten im Download war oder auf
/// WLAN wartete, erst beim nächsten Tipp auf „Jetzt laden“ weiter. Den Wechsel
/// auf WLAN beobachtet der ``OfflineDownloadManager`` selbst, sobald er hier
/// einmal Container und Client bekommen hat.
struct PhoneOfflineNachholer: ViewModifier {
    let connection: ConnectionManager
    let container: ModelContainer
    @Environment(\.scenePhase) private var phase

    func body(content: Content) -> some View {
        content
            .task(id: connection.apiClient.map(ObjectIdentifier.init)) { stosseAn() }
            .onChange(of: phase) { _, neu in
                if neu == .active { stosseAn() }
            }
    }

    private func stosseAn() {
        guard !AppEnvironment.isRunningTests, let client = connection.apiClient else { return }
        let c = container
        Task { await OfflineDownloadManager.shared.nachholen(container: c, apiClient: client) }
    }
}
