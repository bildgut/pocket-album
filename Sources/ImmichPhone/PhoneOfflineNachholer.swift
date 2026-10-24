import SwiftUI
import SwiftData
import UIKit

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
    @State private var lebensdauer = PhoneHintergrundLebensdauer()

    func body(content: Content) -> some View {
        content
            .task(id: connection.apiClient.map(ObjectIdentifier.init)) { stosseAn() }
            .onChange(of: phase) { _, neu in
                if neu == .active { stosseAn() }
                if neu == .background {
                    PhoneHintergrundDienst.shared.planeNaechsteLaeufe()
                }
                lebensdauer.phasenWechsel(
                    istHintergrund: neu == .background,
                    syncLaeuft: OfflineSyncProgress.shared.isActive
                )
                haltBildschirmWach(syncLaeuft: OfflineSyncProgress.shared.isActive, aktiv: neu == .active)
            }
            .onChange(of: OfflineSyncProgress.shared.isActive) { _, laeuft in
                lebensdauer.syncWechsel(syncLaeuft: laeuft)
                haltBildschirmWach(syncLaeuft: laeuft, aktiv: phase == .active)
            }
    }

    /// Solange ein Lauf im Vordergrund lädt, dunkelt das Gerät nicht ab: Die Sperre
    /// schickte die App in den Hintergrund, wo iOS nach rund 30 s den Download
    /// abbrach (Gerätebefund 24.10.2026, Protokoll „abgebrochen“).
    private func haltBildschirmWach(syncLaeuft: Bool, aktiv: Bool) {
        UIApplication.shared.isIdleTimerDisabled = PhoneBildschirmWach.soll(syncLaeuft: syncLaeuft, aktiv: aktiv)
    }

    private func stosseAn() {
        guard !AppEnvironment.isRunningTests, let client = connection.apiClient else { return }
        let c = container
        Task { await OfflineDownloadManager.shared.nachholen(container: c, apiClient: client) }
    }
}

/// Wann der Bildschirm wach bleiben soll. Eigener Typ, damit die Regel prüfbar ist —
/// ein dauerhaft gesetzter `isIdleTimerDisabled` frisst den Akku.
enum PhoneBildschirmWach {
    static func soll(syncLaeuft: Bool, aktiv: Bool) -> Bool { syncLaeuft && aktiv }
}
