import Foundation
import SwiftData
import SwiftUI

/// Manages a persistent queue of write operations that failed due to network errors.
/// Replays them in FIFO order when connectivity returns.
@Observable
@MainActor
final class OfflineActionQueue {
    /// Number of pending actions (for toolbar badge)
    var pendingCount: Int = 0
    var failedCount: Int = 0

    private let apiClient: ImmichAPIClient
    private let modelContext: ModelContext
    private static let maxRetries = 3
    private var isReplaying = false
    private var periodicReplayTask: Task<Void, Never>?

    init(apiClient: ImmichAPIClient, modelContext: ModelContext) {
        self.apiClient = apiClient
        self.modelContext = modelContext
        refreshCounts()
        startPeriodicReplay()
    }

    /// Replay-Loop für Aktionen, deren direkter API-Call fehlschlug, obwohl die App
    /// nie "offline" wurde (z. B. kurzer Tailscale-/Server-Aussetzer). Ohne diesen
    /// Loop lägen sie bis zum nächsten Verbindungs-WECHSEL — potenziell für immer,
    /// weil der Connectivity-Monitor solche Blips gar nicht sieht.
    /// Der erste Tick nach 30 s deckt zugleich den App-Start ab (Aktionen aus der
    /// letzten Session).
    private func startPeriodicReplay() {
        periodicReplayTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self else { return }
                if self.hasReplayableWork() {
                    await self.replayPendingActions()
                }
            }
        }
    }

    /// Ob der periodische Lauf etwas zu tun hat.
    ///
    /// Zählt **auch** `"syncing"` — und genau daran hing der Fehler. Die Rückholung
    /// hängengebliebener `"syncing"`-Aktionen steht in `replayPendingActions()`, „weil
    /// es jede Eintrittsstelle abdeckt". Diese Eintrittsstelle war aber auf
    /// `pendingCount` gefiltert, und `refreshCounts()` zählt nur `"pending"` und
    /// `"failed"`. Eine Aktion, die beim Abbruch der App in `"syncing"` stehenblieb,
    /// war damit unsichtbar für genau den Lauf, der sie retten sollte.
    ///
    /// Die andere automatische Eintrittsstelle greift beim Start nicht: `MainView`
    /// wird erst gerendert, wenn die Verbindung schon steht — ihr
    /// `.onChange(of: connection.state)` sieht den Übergang nach `connected` also gar
    /// nicht mehr. Blieb der periodische Lauf. Blieb nichts.
    ///
    /// Bei einer nicht durchlaufenden Zählung `true`: Der Replay prüft ohnehin selbst
    /// nach, ein Fehlalarm kostet einen leeren Durchlauf. Ein `?? 0` hieße dagegen
    /// „nichts zu tun" und wäre wieder derselbe Fehler.
    func hasReplayableWork() -> Bool {
        let predicate = #Predicate<PendingAction> {
            $0.status == "pending" || $0.status == "syncing"
        }
        guard let count = try? modelContext.fetchCount(FetchDescriptor(predicate: predicate)) else {
            return true
        }
        return count > 0
    }

    // MARK: - Enqueue

    /// Save a failed action to the persistent queue instead of showing an error.
    func enqueue(actionType: String, assetIds: [String]) {
        enqueueDeduplicated(actionType: actionType, assetIds: assetIds)
        refreshCounts()
        AppLogger.offline.info("Enqueued \(actionType) for \(assetIds.count) assets")
    }

    // MARK: - Replay

    /// Replay all pending actions in FIFO order. Called on connectivity changes
    /// and periodically from `startPeriodicReplay()`.
    func replayPendingActions() async {
        guard !isReplaying else { return }
        isReplaying = true
        defer { isReplaying = false }

        // Aktionen aus einem abgebrochenen Lauf zurückholen.
        //
        // `"syncing"` wird vor dem Netzaufruf gesetzt **und gespeichert**. Wird die
        // App dazwischen beendet, bleibt die Aktion dauerhaft in diesem Zustand —
        // und `"syncing"` wird sonst nirgends gelesen: Der Replay holt nur
        // `"pending"`, die Zähler zählen `"pending"`/`"failed"`, und weder
        // `getFailedActions` noch `retryFailed` noch `clearFailed` fassen ihn an.
        // Der Favorit, das Archivieren oder Löschen des Nutzers verschwände damit
        // lautlos.
        //
        // Hier statt beim App-Start, weil es jede Eintrittsstelle abdeckt. Innerhalb
        // eines Prozesses kann dabei nichts Laufendes zurückgesetzt werden:
        // `isReplaying` schließt einen zweiten Lauf aus, und jeder Ausgang der
        // Schleife hinterlässt einen Endzustand.
        //
        // Gleiche Vorsorge wie `UploadManager.recoverStaleRunningStateIfNeeded()`.
        let stalePredicate = #Predicate<PendingAction> { $0.status == "syncing" }
        if let stale = try? modelContext.fetch(FetchDescriptor(predicate: stalePredicate)),
           !stale.isEmpty {
            for action in stale { action.status = "pending" }
            try? modelContext.save()
            AppLogger.offline.warning(
                "\(stale.count) Aktion(en) aus einem abgebrochenen Lauf zurück auf 'pending' gesetzt"
            )
            refreshCounts()
        }

        let pendingPredicate = #Predicate<PendingAction> { $0.status == "pending" }
        let descriptor = FetchDescriptor(
            predicate: pendingPredicate,
            sortBy: [SortDescriptor(\.createdAt)]
        )

        guard let actions = try? modelContext.fetch(descriptor), !actions.isEmpty else { return }

        AppLogger.offline.info("Replaying \(actions.count) pending actions")

        for action in actions {
            action.status = "syncing"
            try? modelContext.save()

            do {
                try await executeAction(action)
                action.status = "completed"
                AppLogger.offline.info("✓ \(action.actionType) completed")
            } catch let urlError as URLError {
                // Transportfehler: Server nicht erreichbar. Das ist kein Fehlschlag
                // DER AKTION — Zähler nicht erhöhen, sonst kippen Aktionen während
                // längerer Offline-Phasen auf "failed". Rest der Queue überspringen,
                // die scheitert am selben Netzproblem.
                action.status = "pending"
                action.lastError = urlError.localizedDescription
                AppLogger.offline.info("Replay unterbrochen — Server nicht erreichbar: \(urlError.code.rawValue)")
                break
            } catch {
                action.retryCount += 1
                action.lastError = error.localizedDescription

                if action.retryCount >= Self.maxRetries {
                    action.status = "failed"
                    AppLogger.offline.error(" \(action.actionType) permanently failed after \(Self.maxRetries) retries")
                } else {
                    action.status = "pending"
                    AppLogger.offline.warning(" \(action.actionType) retry \(action.retryCount)/\(Self.maxRetries): \(error)")
                }
            }
        }

        // Erst sichern, dann aufräumen. `delete(model:where:)` wertet sein Prädikat
        // gegen den **Store** aus, nicht gegen den Kontext — und `status = "completed"`
        // stand bis hierher nur im Speicher. Der Store sah noch `"syncing"`, das
        // Prädikat traf nichts, und der `save()` danach schrieb `"completed"` fest:
        // Jede erfolgreich zurückgespielte Aktion blieb dauerhaft liegen, der
        // Aufräumcode lief ins Leere. Aufgefallen ist es nie, weil die Zähler nur
        // `"pending"` und `"failed"` zählen und die Deduplizierung `"completed"`
        // ignoriert — die Zeilen störten nicht, sie wuchsen nur.
        try? modelContext.save()

        // Clean up completed actions
        let completedPredicate = #Predicate<PendingAction> { $0.status == "completed" }
        try? modelContext.delete(model: PendingAction.self, where: completedPredicate)
        try? modelContext.save()

        refreshCounts()
        NotificationCenter.default.post(name: .offlineReplayCompleted, object: nil)
    }

    // MARK: - Execute

    /// Execute a single pending action against the API.
    private func executeAction(_ action: PendingAction) async throws {
        switch action.actionType {
        case "favorite":
            for id in action.assetIds {
                try await apiClient.toggleFavorite(assetId: id, isFavorite: true)
            }
        case "unfavorite":
            for id in action.assetIds {
                try await apiClient.toggleFavorite(assetId: id, isFavorite: false)
            }
        case "archive":
            for id in action.assetIds {
                try await apiClient.toggleArchive(assetId: id, isArchived: true)
            }
        case "unarchive":
            for id in action.assetIds {
                try await apiClient.toggleArchive(assetId: id, isArchived: false)
            }
        case "delete":
            try await apiClient.deleteAssets(ids: action.assetIds)
        default:
            AppLogger.offline.warning("Unknown action type: \(action.actionType)")
        }
    }

    // MARK: - Helpers

    private func refreshCounts() {
        let pendingPredicate = #Predicate<PendingAction> { $0.status == "pending" }
        pendingCount = (try? modelContext.fetchCount(FetchDescriptor(predicate: pendingPredicate))) ?? 0

        let failedPredicate = #Predicate<PendingAction> { $0.status == "failed" }
        failedCount = (try? modelContext.fetchCount(FetchDescriptor(predicate: failedPredicate))) ?? 0
    }

    /// Get all failed actions for display in Settings.
    func getFailedActions() -> [PendingAction] {
        let failedPredicate = #Predicate<PendingAction> { $0.status == "failed" }
        let descriptor = FetchDescriptor(
            predicate: failedPredicate,
            sortBy: [SortDescriptor(\.createdAt)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /// Retry failed actions (resets them to pending).
    func retryFailed() {
        for action in getFailedActions() {
            action.status = "pending"
            action.retryCount = 0
        }
        try? modelContext.save()
        refreshCounts()
    }

    /// Clear all completed and failed actions.
    func clearAll() {
        try? modelContext.delete(model: PendingAction.self)
        try? modelContext.save()
        refreshCounts()
    }

    /// Discard only failed actions (the user gave up on them).
    func clearFailed() {
        let failedPredicate = #Predicate<PendingAction> { $0.status == "failed" }
        try? modelContext.delete(model: PendingAction.self, where: failedPredicate)
        try? modelContext.save()
        refreshCounts()
        NotificationCenter.default.post(name: .offlineReplayCompleted, object: nil)
    }

    // MARK: - Deduplication

    private func enqueueDeduplicated(actionType: String, assetIds: [String]) {
        // Collapse per-asset actions with simple contradiction rules — aber nur
        // innerhalb einer Dimension. Favorit und Archiv sind unabhängig
        // voneinander; würden sie zusammengelegt, ginge eine der beiden
        // Änderungen beim nächsten Replay verloren.
        for assetId in Set(assetIds) {
            let pending = pendingActions(for: assetId)

            // Eine Löschung sticht alles andere — und wird von nichts überholt.
            if actionType == "delete" {
                for action in pending { modelContext.delete(action) }
                modelContext.insert(PendingAction(actionType: "delete", assetIds: [assetId]))
                continue
            }
            if pending.contains(where: { $0.actionType == "delete" }) { continue }

            let incomingDimension = Self.dimension(of: actionType)
            if let existing = pending.first(where: { Self.dimension(of: $0.actionType) == incomingDimension }) {
                if collapse(existing: existing.actionType, incoming: actionType) == nil {
                    modelContext.delete(existing)   // Widerspruch — hebt sich auf
                } else {
                    existing.actionType = actionType
                    existing.assetIds = [assetId]
                    existing.createdAt = Date()
                    existing.status = "pending"
                    existing.retryCount = 0
                    existing.lastError = nil
                }
            } else {
                modelContext.insert(PendingAction(actionType: actionType, assetIds: [assetId]))
            }
        }
        try? modelContext.save()
    }

    /// Aktionen derselben Dimension schließen einander aus, Aktionen
    /// unterschiedlicher Dimensionen nicht.
    private static func dimension(of actionType: String) -> String {
        switch actionType {
        case "favorite", "unfavorite": return "favorite"
        case "archive", "unarchive":   return "archive"
        default:                       return actionType
        }
    }

    private func pendingActions(for assetId: String) -> [PendingAction] {
        // NOTE: assetIds.contains() is a Sequence operation that crashes in SwiftData
        // predicates at runtime. Filter by status in the predicate, then filter in-memory.
        var descriptor = FetchDescriptor<PendingAction>(
            predicate: #Predicate<PendingAction> { $0.status == "pending" || $0.status == "failed" },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.propertiesToFetch = [\.assetIds, \.status, \.actionType, \.createdAt, \.retryCount, \.lastError]
        let candidates = (try? modelContext.fetch(descriptor)) ?? []
        return candidates.filter { $0.assetIds.contains(assetId) }
    }

    /// `nil`, wenn sich die beiden Aktionen gegenseitig aufheben. Wird nur für
    /// Aktionen derselben Dimension aufgerufen; `delete` behandelt der Aufrufer.
    private func collapse(existing: String, incoming: String) -> String? {
        switch (existing, incoming) {
        case ("favorite", "unfavorite"), ("unfavorite", "favorite"),
             ("archive", "unarchive"), ("unarchive", "archive"):
            return nil
        default:
            return incoming
        }
    }
}

private struct OfflineActionQueueKey: EnvironmentKey {
    static let defaultValue: OfflineActionQueue? = nil
}

extension EnvironmentValues {
    var offlineActionQueue: OfflineActionQueue? {
        get { self[OfflineActionQueueKey.self] }
        set { self[OfflineActionQueueKey.self] = newValue }
    }
}
