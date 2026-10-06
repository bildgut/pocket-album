import Foundation
import SwiftData
import os

struct CacheFreshnessPolicy: Sendable {
    let baseInterval: TimeInterval
    let backoffIntervals: [TimeInterval]
    let jitterRatio: Double
    let metadataSoftTTL: TimeInterval
    let staleWarningThreshold: TimeInterval

    static let balanced = CacheFreshnessPolicy(
        baseInterval: 30,
        backoffIntervals: [30, 60],   // max 60s — was 120s, too slow for new uploads to appear
        jitterRatio: 0.10,
        metadataSoftTTL: 120,
        staleWarningThreshold: 120
    )
}

enum SyncTrigger: String, Sendable {
    case launch
    case manual
    case reconnect
    case localMutation
    case replayCompleted
    case foreground
    case schedule
    /// Server pushed a change notification over the realtime event socket.
    case push
}

struct SyncCoordinatorState: Sendable {
    let isOnline: Bool
    let lastSyncDate: Date?
}

actor SyncCoordinator {
    typealias SyncRunner = @Sendable (_ trigger: SyncTrigger) async -> SyncRunResult
    typealias StateProvider = @Sendable () async -> SyncCoordinatorState

    private let policy: CacheFreshnessPolicy
    private let runSync: SyncRunner
    private let readState: StateProvider

    private var loopTask: Task<Void, Never>?
    private var consecutiveNoChangeCycles = 0
    /// Der laufende Intervall-Schlaf des Loops. Ein Out-of-Band-Event
    /// (foreground, reconnect, push, manual) bricht ihn ab, statt ihn auszusitzen.
    private var sleepTask: Task<Void, Never>?
    /// Serializes sync runs: a trigger arriving mid-run is queued and executed
    /// right after, instead of being silently dropped by SyncEngine's isSyncing guard.
    private var isExecuting = false
    private var pendingTrigger: SyncTrigger?

    init(
        policy: CacheFreshnessPolicy = .balanced,
        runSync: @escaping SyncRunner,
        readState: @escaping StateProvider
    ) {
        self.policy = policy
        self.runSync = runSync
        self.readState = readState
    }

    func start() {
        stop()
        loopTask = Task { await self.runLoop() }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        // Der Schlaf ist ein unstrukturierter Task — er erbt die Cancellation
        // des Loops nicht und muss explizit abgebrochen werden.
        sleepTask?.cancel()
        sleepTask = nil
    }

    func syncNow() async {
        wakeLoop()
        await execute(trigger: .manual)
    }

    func notifyLocalMutation() async {
        await execute(trigger: .localMutation)
    }

    /// The realtime event socket saw a server-side change — sync immediately.
    func notifyRemoteChange() async {
        wakeLoop()
        await execute(trigger: .push)
    }

    func notifyConnectivityChanged(isOnline: Bool) async {
        if isOnline {
            wakeLoop()
            await execute(trigger: .reconnect)
        }
    }

    func notifyAppDidBecomeActive() async {
        guard await !nachholenUeberfluessig(.foreground) else { return }
        wakeLoop()
        await execute(trigger: .foreground)
    }

    /// Der Event-Socket hat (wieder) verbunden: Ereignisse aus der Zeit ohne
    /// Verbindung sind verloren, ein Sync holt sie über den Checkpoint nach.
    func notifyEventSocketConnected() async {
        guard await !nachholenUeberfluessig(.reconnect) else { return }
        wakeLoop()
        await execute(trigger: .reconnect)
    }

    // MARK: - Nachholen

    /// Wie lange nach dem **Checkpoint** eines erfolgreichen Syncs ein Nachhol-Sync
    /// überflüssig ist. Der Checkpoint (`lastSyncTimestamp`) liegt 10 s vor dem
    /// Beginn jenes Syncs (`SyncEngine.nextCheckpoint`) — 20 s heißt also: Der
    /// letzte erfolgreiche Sync hat vor höchstens rund 10 s begonnen.
    ///
    /// Anlass (Messlauf `sync`, 19.09.2026): Beim Start liefen binnen 2 s drei
    /// Syncs mit je 0 Änderungen — Start-Sync, dann das Nachholen des Sockets beim
    /// ersten Verbinden, dann `didBecomeActive`. Beide Nachzügler holten eine
    /// Lücke nach, die es nicht gab.
    ///
    /// Gilt nur für Nachhol-Auslöser (`foreground`, Socket verbunden). Echte
    /// Server-Ereignisse (`push`), `manual`, lokale Änderungen und der Takt
    /// laufen immer. Was in den wenigen Sekunden zwischen Beginn des letzten Syncs
    /// und dem Nachhol-Anlass geschah, meldet der Socket selbst oder spätestens der
    /// nächste Takt (30–60 s).
    static let nachholFenster: TimeInterval = 20

    static func nachholenUeberfluessig(lastSyncDate: Date?, jetzt: Date) -> Bool {
        guard let lastSyncDate else { return false }
        let alter = jetzt.timeIntervalSince(lastSyncDate)
        return alter >= 0 && alter < nachholFenster
    }

    private func nachholenUeberfluessig(_ trigger: SyncTrigger) async -> Bool {
        let state = await readState()
        guard Self.nachholenUeberfluessig(lastSyncDate: state.lastSyncDate, jetzt: Date()) else {
            return false
        }
        AppLogger.sync.debug("Sync \(trigger.rawValue, privacy: .public) übersprungen: letzter Sync liegt erst Sekunden zurück")
        return true
    }

    func notifyOfflineReplayCompleted() async {
        await execute(trigger: .replayCompleted)
    }

    /// Returns true if the last sync finished more than `threshold` seconds ago (or has never run).
    func isLastSyncStale(threshold: TimeInterval) async -> Bool {
        let state = await readState()
        guard let lastSync = state.lastSyncDate else { return true }
        return Date().timeIntervalSince(lastSync) > threshold
    }

    // MARK: - Loop

    private func runLoop() async {
        while !Task.isCancelled {
            let state = await readState()
            if !state.isOnline {
                try? await Task.sleep(for: .seconds(5))
                continue
            }

            let base = nextInterval()
            let jitter = base * policy.jitterRatio
            let delta = Double.random(in: -jitter...jitter)
            let wait = max(5, base + delta)

            // Sleep for `wait` seconds OR until an out-of-band event wakes us early.
            let wokenEarly = await sleepUntilWakeOrTimeout(seconds: wait)

            guard !Task.isCancelled else { break }
            // Geweckt wurden wir nur von einem Trigger, der selbst schon
            // `execute(…)` aufruft (push, manual, foreground, reconnect) —
            // ein zusätzlicher `.schedule`-Lauf direkt dahinter wäre reine
            // Doppelarbeit. Stattdessen beginnt das Intervall neu.
            if wokenEarly { continue }

            await execute(trigger: .schedule)
            await emitStaleWarningIfNeeded()
        }
    }

    /// Schläft `seconds` oder bis `wakeLoop()` den Schlaf abbricht.
    /// - Returns: `true`, wenn der Schlaf durch ein Wake-Event verkürzt wurde.
    ///
    /// Bewusst ein abbrechbarer Task und keine TaskGroup mit einem
    /// Continuation-Waiter: `withCheckedContinuation` ignoriert Cancellation,
    /// die Gruppe hätte also am Ende auf einen Waiter gewartet, den niemand mehr
    /// fortsetzt — der Loop kam aus seinem ersten abgelaufenen Schlaf nie zurück
    /// und pollte danach nie wieder.
    private func sleepUntilWakeOrTimeout(seconds: TimeInterval) async -> Bool {
        let task = Task<Void, Never> { _ = try? await Task.sleep(for: .seconds(seconds)) }
        sleepTask = task
        await task.value
        if sleepTask == task { sleepTask = nil }
        return task.isCancelled
    }

    /// Beendet den laufenden Intervall-Schlaf des Loops sofort.
    private func wakeLoop() {
        sleepTask?.cancel()
    }

    private func nextInterval() -> TimeInterval {
        let index = min(consecutiveNoChangeCycles, policy.backoffIntervals.count - 1)
        return policy.backoffIntervals[index]
    }

    private func execute(trigger: SyncTrigger) async {
        let state = await readState()
        guard state.isOnline else { return }
        if isExecuting {
            pendingTrigger = trigger
            return
        }
        isExecuting = true
        defer { isExecuting = false }
        var next: SyncTrigger? = trigger
        while let current = next {
            let result = await runSync(current)
            if result.changedCount > 0 {
                consecutiveNoChangeCycles = 0
            } else {
                consecutiveNoChangeCycles += 1
            }
            next = pendingTrigger
            pendingTrigger = nil
        }
    }

    private func emitStaleWarningIfNeeded() async {
        let state = await readState()
        guard state.isOnline, let lastSync = state.lastSyncDate else { return }
        if Date().timeIntervalSince(lastSync) > policy.staleWarningThreshold {
            await MainActor.run {
                NotificationCenter.default.post(name: .syncStaleWarning, object: nil)
            }
        }
    }
}

enum SyncTransport: String, Codable, Sendable {
    case none
    case initial
    case stream
    case polling
}

struct SyncRunResult: Sendable {
    let changedCount: Int
    let transport: SyncTransport
    /// Counts written into the Sync-Log for this run.
    var uploadedCount: Int = 0
    var duplicateCount: Int = 0
    var failedCount: Int = 0
    var checksumMismatchCount: Int = 0
    var errorMessage: String? = nil
    var durationSeconds: Double = 0
}

/// Orchestrates metadata sync between the Immich server and local SwiftData store.
@Observable
@MainActor
final class SyncEngine {
    var syncProgress: Double = 0        // 0.0 – 1.0
    /// True while a stream-based sync runs — no chunk-level progress available → show indeterminate bar
    var syncIsStreaming = false
    var syncStatus: String = ""
    var isSyncing = false
    /// True while a background-only operation runs that shouldn't show an overly technical
    /// status label to the user.
    var isSilentBackground = false
    var syncError: String?
    var currentTransport: SyncTransport = .none

    /// User-facing status text used by compact UI surfaces when a phase does not
    /// provide a granular `syncStatus` yet.
    var visibleSyncStatus: String {
        if !syncStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return syncStatus
        }
        if syncIsStreaming {
            return "Live-Sync verarbeitet Aenderungen…"
        }
        if syncProgress > 0 {
            return "Synchronisiere Mediathek…"
        }
        return "Synchronisation wird vorbereitet…"
    }

    /// Last successful sync timestamp — read from SwiftData on demand
    var lastSyncDate: Date? {
        let descriptor = FetchDescriptor<SyncState>()
        return try? modelContext.fetch(descriptor).first?.lastSyncTimestamp
    }

    private let apiClient: ImmichAPIClient
    private let modelContext: ModelContext
    /// Optional stream client — uses session token auth for efficient sync
    private var syncStreamClient: SyncStreamClient?

    init(apiClient: ImmichAPIClient, modelContext: ModelContext, sessionToken: String? = nil) {
        self.apiClient = apiClient
        self.modelContext = modelContext
        if let sessionToken {
            self.syncStreamClient = SyncStreamClient(
                baseURL: apiClient.baseURL,
                sessionToken: sessionToken
            )
            AppLogger.sync.info("Sync Stream client initialized (session auth available)")
        } else {
            // Ohne diese Zeile ist der Polling-Only-Betrieb nur an
            // `streamAuthAvailable` im persistierten SyncState zu erkennen — also
            // praktisch nur per SQLite-Blick in den Store.
            AppLogger.sync.info("Sync Stream nicht verfügbar (kein Session-Token, z. B. bei API-Key-Auth) — jeder Sync läuft über Polling")
        }
    }

    // MARK: - Public API

    /// Determine sync strategy and execute.
    func syncIfNeeded() async -> SyncRunResult {
        await performSync(trigger: .launch)
    }

    /// Force a full delta sync now (for "Sync Now" button in Settings)
    func syncNow() async -> SyncRunResult {
        await performSync(trigger: .manual)
    }

    /// Ob der SwiftData-Store zurückgesetzt wurde, während der Grid-Index überlebt hat.
    ///
    /// - Parameter cachedCount: `nil` heißt **nicht lesbar**. Dann wird *kein* Reset
    ///   angenommen.
    ///
    ///   Zuvor stand am Aufrufer `(try? …) ?? 0`: Ein fehlgeschlagener Zugriff sah
    ///   damit aus wie ein leerer Store und löste einen vollständigen Neuabgleich der
    ///   ganzen Bibliothek aus — bei 155 000 Assets Minuten Arbeit. Zusätzlich wurde
    ///   `exifBackfillCompletedAt` geleert, was den EXIF-Backfill neu anwirft und
    ///   solange den Smart-Album-Mirror anhält (siehe dessen v8-Tor).
    ///
    ///   Die Gegenseite fällt schon sicher aus: `totalAssetCount()` liefert bei einem
    ///   Lesefehler `0`, und `gridCount > 500` ist dann falsch. Nur die SwiftData-Seite
    ///   fiel in die zerstörerische Richtung.
    static func storeLooksReset(cachedCount: Int?, gridCount: Int, isInitialSyncComplete: Bool) -> Bool {
        guard isInitialSyncComplete, let cachedCount else { return false }
        // Schwellenwert aus `GridIndexStore` statt eigener Zahlen: Dieselbe Rechnung
        // steht dort im EXIF-v8-Backfill, und ihr Kommentar verlangt, dass beide
        // Stellen dieselbe Vorstellung von „deutlich weniger" haben.
        return GridIndexStore.swiftDataLooksSmaller(cachedCount: cachedCount, gridCount: gridCount)
    }

    func performSync(trigger: SyncTrigger) async -> SyncRunResult {
        guard !isSyncing else {
            return SyncRunResult(changedCount: 0, transport: currentTransport)
        }

        let start = Date()
        let syncState = fetchOrCreateSyncState()
        var result: SyncRunResult

        // Guard: detect SwiftData-store-reset (e.g. after migration failure).
        // If the GridIndex has significantly more assets than CachedAsset, the
        // SwiftData store was wiped but the SQLite index survived → force full re-sync
        // so EXIF data (cameraModel, city, country, …) gets repopulated.
        // `try?` liefert `nil` für „nicht lesbar" — das ist **nicht** dasselbe wie
        // „leer", und der Unterschied entscheidet hier über einen Komplett-Neuabgleich.
        let cachedCount = try? modelContext.fetchCount(FetchDescriptor<CachedAsset>())
        let gridCount = GridIndexStore.shared.totalAssetCount()
        let storeWasReset = Self.storeLooksReset(
            cachedCount: cachedCount,
            gridCount: gridCount,
            isInitialSyncComplete: syncState.isInitialSyncComplete
        )
        if cachedCount == nil {
            AppLogger.sync.error("Store-Reset-Erkennung übersprungen: CachedAsset-Zählung nicht lesbar")
        }

        if storeWasReset {
            AppLogger.sync.warning("Store-reset detected (cached=\(cachedCount ?? -1), grid=\(gridCount)) — forcing full re-sync to restore EXIF data")
            syncState.isInitialSyncComplete = false
            syncState.exifBackfillCompletedAt = nil
        }

        // Beginnt nach der Store-Reset-Prüfung: Deren `fetchCount` über alle
        // `CachedAsset` läuft zwar ebenfalls je Zyklus, gehört aber in die
        // Zeitprofil-Spur, nicht in die Dauer des Syncs.
        let signpostID = OSSignpostID(log: AppLogger.dataPerf)
        let delta = syncState.isInitialSyncComplete
        os_signpost(.begin, log: AppLogger.dataPerf, name: "Sync", signpostID: signpostID,
                    "%{public}s %{public}s", delta ? "delta" : "initial", trigger.rawValue)

        if delta {
            result = await performDeltaSync(syncState: syncState, trigger: trigger)
        } else {
            result = await performInitialSync(syncState: syncState)
        }
        os_signpost(.end, log: AppLogger.dataPerf, name: "Sync", signpostID: signpostID,
                    "%d changed", result.changedCount)
        result.durationSeconds = Date().timeIntervalSince(start)
        result.errorMessage = syncError

        // Persist log entry
        let entry = SyncLogEntry(
            kind: .sync,
            trigger: trigger.rawValue,
            transport: result.transport,
            changedCount: result.changedCount,
            uploadedCount: result.uploadedCount,
            duplicateCount: result.duplicateCount,
            failedCount: result.failedCount,
            checksumMismatchCount: result.checksumMismatchCount,
            durationSeconds: result.durationSeconds,
            errorMessage: result.errorMessage
        )
        SyncLogStore.shared.append(entry)

        // Der frühere Voll-Backfill lief hier — einmalig im App-Leben, über die gesamte
        // Bibliothek, mit einer SwiftData-Einzelabfrage pro Asset. Ersetzt durch EXIF
        // direkt im Stream (`AssetExifsV1`) für laufende Änderungen und die manuell
        // auslösbare Reparatur in den Einstellungen für den Altbestand.

        return result
    }

    // MARK: - Initial Sync

    /// Uhrenversatz zwischen Mac und Server, abgezogen vom Checkpoint.
    private static let checkpointSkewBuffer: TimeInterval = 10

    /// Der Checkpoint des nächsten Laufs — bezogen auf den **Beginn** dieses Laufs.
    ///
    /// Nicht auf sein Ende: `updatedAfter` fragt nach Serverzeit, und alles, was
    /// *während* des Laufs auf dem Server passiert, hat ein `updatedAt` zwischen
    /// Beginn und Ende. Ein Checkpoint aus `Date()` schöbe sich darüber hinweg, und
    /// der nächste Lauf fragte erst ab diesem späteren Punkt — die Änderungen wären
    /// still verloren. Genau die Gefahr benennt der Kommentar am Aufrufer seit jeher;
    /// er bezifferte das Fenster nur mit den 10 Sekunden Uhrenversatz statt mit der
    /// Laufzeit, die daneben als `lastSyncDuration` steht und Minuten betragen kann.
    ///
    /// Der Preis ist eine Überlappung: Der nächste Lauf sieht noch einmal, was dieser
    /// schon geholt hat. Upserts sind idempotent, das kostet eine Abfrage.
    static func nextCheckpoint(runStartedAt: Date) -> Date {
        runStartedAt.addingTimeInterval(-checkpointSkewBuffer)
    }

    private func performInitialSync(syncState: SyncState) async -> SyncRunResult {
        isSyncing = true
        syncError = nil
        syncStatus = "Starting initial sync…"
        let startTime = Date()

        do {
            // Get total count for progress reporting
            let stats = try await apiClient.getAssetStatistics()
            let expectedTotal = stats.total
            var totalSynced = 0
            var page = 1

            while true {
                let pageStart = Date()
                syncStatus = "Syncing \(totalSynced.formatted()) / \(expectedTotal.formatted()) assets…"
                syncProgress = expectedTotal > 0 ? Double(totalSynced) / Double(expectedTotal) : 0

                let assetPage = try await apiClient.searchAssets(page: page, size: 1000)

                let items = assetPage.items ?? []
                if items.isEmpty { break }

                // Batch insert into SwiftData
                let container = modelContext.container
                try await Task.detached(priority: .userInitiated) {
                    let bgContext = ModelContext(container)
                    bgContext.autosaveEnabled = false
                    for asset in items {
                        let cached = CachedAsset(from: asset)
                        bgContext.insert(cached)
                    }
                    try bgContext.save()
                }.value

                // Keep grid index in sync. `searchAssets(page:size:)` fragt mit
                // `withExif: true` — die Zeilen sind damit geprüft, nicht bloß da.
                GridIndexStore.shared.upsertFromExifFetch(items)

                // Rollback clears tracked objects after save — prevents progressive slowdown
                modelContext.rollback()

                totalSynced += items.count
                let archivedCount = items.filter { $0.isArchived }.count
                let pageTime = String(format: "%.1f", Date().timeIntervalSince(pageStart))
                AppLogger.sync.info("Page \(page): \(items.count) assets (\(archivedCount) archived) in \(pageTime)s (total: \(totalSynced))")

                if assetPage.nextPage == nil || assetPage.nextPage?.isEmpty == true {
                    break
                }
                page += 1
            }

            // Sync albums (owned)
            syncStatus = "Syncing albums…"
            let albums = try await apiClient.getAlbums()
            let container = modelContext.container
            let albumTask = Task.detached(priority: .userInitiated) {
                let bgContext = ModelContext(container)
                bgContext.autosaveEnabled = false
                for album in albums {
                    let cached = CachedAlbum(from: album)
                    bgContext.insert(cached)
                }
                try bgContext.save()
            }
            try await albumTask.value

            // Sync shared albums
            syncStatus = "Syncing shared albums…"
            let sharedAlbums = try await apiClient.getSharedAlbums()
            let sharedTask = Task.detached(priority: .userInitiated) {
                let bgContext = ModelContext(container)
                bgContext.autosaveEnabled = false
                for album in sharedAlbums {
                    let cached = CachedAlbum(from: album)
                    cached.isShared = true
                    bgContext.insert(cached)
                }
                try bgContext.save()
            }
            try await sharedTask.value

            syncState.isInitialSyncComplete = true
            syncState.lastSyncTimestamp = Self.nextCheckpoint(runStartedAt: startTime)
            syncState.totalAssetCount = totalSynced
            syncState.lastSyncDuration = Date().timeIntervalSince(startTime)
            syncState.syncTransport = .initial
            try modelContext.save()
            // Persistenter Flag — ConnectionManager liest ihn beim Kaltstart ohne Netz,
            // um zu entscheiden ob der Offline-Modus verfügbar ist.
            AppEnvironment.defaults.set(true, forKey: "hasCompletedInitialSync")

            syncStatus = "Sync complete — \(totalSynced.formatted()) assets"
            syncProgress = 1.0
            currentTransport = .initial
            AppLogger.sync.info("Initial sync complete: \(totalSynced) assets in \(String(format: "%.1f", syncState.lastSyncDuration))s")
            isSyncing = false
            return SyncRunResult(changedCount: totalSynced, transport: .initial)

        } catch {
            syncError = "Sync failed: \(error.localizedDescription)"
            syncStatus = "Sync error"
            AppLogger.sync.error("Initial sync error: \(error)")
            isSyncing = false
            return SyncRunResult(changedCount: 0, transport: .none)
        }
    }

    // MARK: - Delta Sync

    private func performDeltaSync(syncState: SyncState, trigger: SyncTrigger) async -> SyncRunResult {
        guard let lastSync = syncState.lastSyncTimestamp else {
            // If no timestamp, fall back to initial sync
            return await performInitialSync(syncState: syncState)
        }

        // Keep capability flags updated in persisted state.
        syncState.streamAuthAvailable = (syncStreamClient != nil)

        // The polling path carries the self-healing reconciliation (sweep-miss
        // verification, wrongly-trashed restore, trash purge) that the stream
        // path lacks. Run it as a "deep sync" for every manual sync and at least
        // once per interval, even while stream sync is healthy — otherwise
        // "Empty trash" on web or a wrongly-trashed asset never heals locally.
        let deepSyncInterval: TimeInterval = 6 * 60 * 60
        let timeSinceReconcile = syncState.lastDeletionReconcileAt.map { Date().timeIntervalSince($0) } ?? .infinity
        let needsDeepSync = trigger == .manual || timeSinceReconcile > deepSyncInterval

        // Try Sync Stream API first (if available and not previously marked unsupported).
        if !needsDeepSync, syncState.serverSupportsStream, let streamClient = syncStreamClient {
            do {
                let result = try await performStreamDeltaSync(syncState: syncState, client: streamClient)

                // Einmaliger Checksum-Backfill nach der Grid-v9-Migration:
                // Checkpoint für AssetV2 löschen und sofort erneut streamen —
                // der Replay (~155k Zeilen, gemessen <1 min) füllt die neue
                // Spalte. Die EXIF-Checkpoints bleiben stehen. Die Marke
                // fällt erst nach einem erfolgreichen Replay; jeder
                // Fehlschlag lässt sie stehen, der nächste Sync wiederholt.
                //
                // AssetDeleteV1 wird bewusst NICHT mit zurückgesetzt: Der
                // Delete-Zweig von `applySyncStreamResults` trägt seine IDs
                // ungeprüft (ohne Diff) in `changedIds` ein — ein Tombstone-
                // Replay würde changedIds fluten und einen Cache-/
                // Notification-Sturm auslösen. Checksums stecken ausschließlich
                // in AssetV2-Zeilen, der Delete-Checkpoint bringt für den
                // Backfill nichts.
                if GridIndexStore.shared.isChecksumBackfillPending() {
                    switch GridIndexStore.shared.checksumColumnComplete() {
                    case true:
                        // Deckt zwei Fälle ab: Frischinstallationen, deren initialer
                        // Polling-Sync die Spalte längst gefüllt hat, bevor die Marke
                        // je geprüft wird; und einen schon erfolgreichen Teil-Replay,
                        // nach dem die Marke aus irgendeinem Grund noch stand. Der
                        // Backfill terminiert sich damit selbst statt bei jedem
                        // weiteren Sync erneut zu versuchen.
                        GridIndexStore.shared.clearChecksumBackfillPending()
                        AppLogger.sync.info("Checksum-Backfill: Spalte bereits vollständig — kein Replay nötig")
                    case false:
                        // false deckt auch die leere Tabelle ab (Neuaufbau aus
                        // SwiftData läuft evtl. gerade im Hintergrund) — dort darf
                        // die Marke nicht fallen, siehe `checksumColumnComplete`.
                        var deleteAcksSucceeded = false
                        do {
                            try await streamClient.deleteAcks(types: ["AssetV2"])
                            deleteAcksSucceeded = true
                            AppLogger.sync.info("Checksum-Backfill: Checkpoint zurückgesetzt, Replay startet")
                        } catch SyncStreamError.ackFailed(404), SyncStreamError.ackFailed(405) {
                            // Server kennt DELETE /api/sync/ack nicht (ältere Immich-
                            // Version) — ein Retry würde nie klappen. Marke fällt, die
                            // Spalte füllt sich stattdessen lazy über den Polling-Pfad.
                            GridIndexStore.shared.clearChecksumBackfillPending()
                            AppLogger.sync.info("Server kennt DELETE /sync/ack nicht — Backfill entfällt, Spalte füllt sich über den Polling-Pfad")
                        } catch {
                            let fallbackReason = markFallbackReason(error: error, syncState: syncState)
                            let attempts = GridIndexStore.shared.registerChecksumBackfillFailure()
                            if attempts >= GridIndexStore.checksumBackfillMaxAttempts {
                                GridIndexStore.shared.clearChecksumBackfillPending()
                                AppLogger.sync.warning("Checksum-Backfill: \(attempts). Fehlschlag beim Checkpoint-Reset (\(fallbackReason)) — Versuchsbudget aufgebraucht, Marke fällt: \(error)")
                            } else {
                                AppLogger.sync.error("Checksum-Backfill: Checkpoint-Reset fehlgeschlagen (\(fallbackReason), Versuch \(attempts)/\(GridIndexStore.checksumBackfillMaxAttempts)) — nächster Sync versucht erneut: \(error)")
                            }
                        }

                        if deleteAcksSucceeded {
                            do {
                                _ = try await performStreamDeltaSync(syncState: syncState, client: streamClient)
                                GridIndexStore.shared.clearChecksumBackfillPending()
                                AppLogger.sync.info("Checksum-Backfill abgeschlossen")
                            } catch {
                                // Gleiche Klassifikation wie beim äußeren catch — greift
                                // nur bei httpError/authRequired (401/403 stufen den
                                // Transport herab), nicht bei ackFailed. Der Fehler
                                // bleibt aber innerhalb des Hooks, kein Rethrow.
                                let fallbackReason = markFallbackReason(error: error, syncState: syncState)
                                let attempts = GridIndexStore.shared.registerChecksumBackfillFailure()
                                if attempts >= GridIndexStore.checksumBackfillMaxAttempts {
                                    GridIndexStore.shared.clearChecksumBackfillPending()
                                    AppLogger.sync.warning("Checksum-Backfill: \(attempts). Fehlschlag beim Replay (\(fallbackReason)) — Versuchsbudget aufgebraucht, Marke fällt: \(error)")
                                } else {
                                    AppLogger.sync.error("Checksum-Backfill: Replay fehlgeschlagen (\(fallbackReason), Versuch \(attempts)/\(GridIndexStore.checksumBackfillMaxAttempts)) — nächster Sync versucht erneut: \(error)")
                                }
                            }
                        }
                    case nil:
                        break  // Index nicht lesbar — nächster Sync fragt erneut.
                    }
                }

                // Einmaliger Nachlauf für die EXIF-Orientierung (Grid-Schema v10):
                // Bis dahin dekodierte der Client `orientation` nicht, die Maße im
                // Index sind deshalb die rohen Sensorwerte — bei 67 % der Fotos in der
                // falschen Ausrichtung (gemessen an 60 Assets, siehe ExifOrientation).
                // Der Checkpoint für AssetExifV1 wird einmal gelöscht, der Replay
                // schreibt die Maße mit angewandter Orientierung neu.
                //
                // Nur der EXIF-Checkpoint: AssetV2-Zeilen tragen keine Maße, und ein
                // AssetDeleteV1-Replay würde `changedIds` mit Tombstones fluten
                // (gleiche Begründung wie beim Checksum-Nachlauf oben).
                if GridIndexStore.shared.isOrientationBackfillPending() {
                    await runOrientationBackfill(syncState: syncState, client: streamClient)
                }

                isSyncing = false
                return result
            } catch {
                let fallbackReason = markFallbackReason(error: error, syncState: syncState)
                AppLogger.sync.warning("Stream sync failed (\(fallbackReason)), falling back to polling: \(error)")
                // Fall through to polling
            }
        }

        isSyncing = true
        syncError = nil
        syncStatus = "Checking for changes…"
        let startTime = Date()

        do {
            // One-time fix: if >90% of assets are marked as trashed, the cache
            // was corrupted by the broken getTrash() sync. Purge and re-sync.
            let trashedPredicate = #Predicate<CachedAsset> { $0.isTrashed == true }
            let trashedCount = try modelContext.fetchCount(FetchDescriptor(predicate: trashedPredicate))
            let totalLocal = try modelContext.fetchCount(FetchDescriptor<CachedAsset>())

            if trashedCount > 0 && totalLocal > 0 && Double(trashedCount) / Double(totalLocal) > 0.9 {
                AppLogger.sync.warning("Detected corrupted trash flags (\(trashedCount)/\(totalLocal)) — purging cache for fresh sync")
                try modelContext.delete(model: CachedAsset.self)
                try modelContext.save()
                syncState.isInitialSyncComplete = false
                try modelContext.save()
                isSyncing = false
                return await performInitialSync(syncState: syncState)
            }

            // Quick check: did the total count change?
            let stats = try await apiClient.getAssetStatistics()
            let serverTotal = stats.total

            // Fetch assets modified since last sync.
            // `processedCount` zählt alles, was im Delta-Fenster ankam,
            // `updatedIds` nur das, was sich lokal wirklich geändert hat. Beides
            // auseinanderzuhalten ist wichtig, weil der Checkpoint mit 10 s
            // Sicherheitspuffer gesetzt wird: dieselben Assets laufen dadurch
            // regelmäßig mehrfach durch, ohne sich zu ändern.
            var processedCount = 0
            var updatedIds = Set<String>()
            var page = 1

            while true {
                let assetPage = try await apiClient.searchAssets(updatedAfter: lastSync, page: page, size: 1000)

                let items = assetPage.items ?? []
                if items.isEmpty { break }

                let container = modelContext.container
                let (pageProcessedCount, pageUpdatedIds) = try await Task.detached(priority: .userInitiated) {
                    let bgContext = ModelContext(container)
                    bgContext.autosaveEnabled = false
                    
                    var count = 0
                    var ids = Set<String>()
                    
                    for asset in items {
                        // Try to find existing cached asset
                        let assetId = asset.id
                        let predicate = #Predicate<CachedAsset> { $0.assetId == assetId }
                        var descriptor = FetchDescriptor<CachedAsset>(predicate: predicate)
                        descriptor.fetchLimit = 1

                        if let existing = try bgContext.fetch(descriptor).first {
                            if existing.update(from: asset) {
                                ids.insert(assetId)
                            }
                        } else {
                            let cached = CachedAsset(from: asset)
                            bgContext.insert(cached)
                            ids.insert(assetId)
                        }
                        count += 1
                    }
                    try bgContext.save()
                    return (count, ids)
                }.value
                
                processedCount += pageProcessedCount
                updatedIds.formUnion(pageUpdatedIds)

                // Keep grid index in sync. Auch `searchAssets(updatedAfter:)` fragt mit
                // `withExif: true`. Ohne den Vermerk hier bekäme der Polling-Transport
                // nie einen — der Stream-Transport bekommt EXIF stattdessen direkt
                // über `AssetExifsV1`.
                GridIndexStore.shared.upsertFromExifFetch(assetPage.items ?? [])

                if assetPage.nextPage == nil || assetPage.nextPage?.isEmpty == true {
                    break
                }
                page += 1
            }

            // Handle deletions.
            // The full-ID sweep downloads EVERY server asset id (one page per 1000
            // assets) — for large libraries that takes minutes, starves the sync
            // pipeline (push-triggered syncs queue behind it), and the long request
            // chain dies on any network blip. So it runs only as part of a "deep
            // sync": manual trigger or every 6 hours. Regular trash/restore arrives
            // via updatedAfter deltas anyway (trashing bumps updatedAt).
            //
            // NOTE: server/local count equality is NOT a usable trigger — the stats
            // endpoint and the local cache count different populations (hidden
            // live-photo motion parts, archived), so they disagree permanently and
            // would force the sweep on every cycle.
            let reconcileInterval: TimeInterval = 6 * 60 * 60
            let timeSinceLastReconcile = syncState.lastDeletionReconcileAt.map { Date().timeIntervalSince($0) } ?? .infinity
            let shouldReconcileDeletions = trigger == .manual
                || timeSinceLastReconcile > reconcileInterval

            var deletedIds = [String]()
            var restoredIds = [String]()
            if shouldReconcileDeletions {
                isSilentBackground = true
                syncStatus = "Pruefe geloeschte Medien…"
                // Die lokale Zahl erst hier ermitteln. Sie stand vorher außerhalb
                // dieses `if` und lief damit bei **jedem** Zyklus (30–60 s) — ein
                // `fetchCount` mit Prädikat über 155 000 `CachedAsset` auf dem
                // Main-Actor, dessen einziger Abnehmer diese Log-Zeile ist. Die
                // fällt alle sechs Stunden an.
                //
                // `serverTotal` bleibt oben: Das hat einen zweiten Abnehmer
                // (`syncState.totalAssetCount`).
                let notTrashedPredicate = #Predicate<CachedAsset> { $0.isTrashed == false }
                let actualLocalCount = try modelContext.fetchCount(
                    FetchDescriptor(predicate: notTrashedPredicate)
                )
                AppLogger.sync.debug("Reconciling: server \(serverTotal), local \(actualLocalCount) (trigger=\(trigger.rawValue))")

                // Fetch all server asset IDs (paginated to avoid huge single response)
                var serverIds = Set<String>()
                var idPage = 1
                while true {
                    let idResults = try await apiClient.searchAssets(page: idPage, size: 1000)
                    let items = idResults.items ?? []
                    if items.isEmpty { break }
                    for asset in items {
                        serverIds.insert(asset.id)
                    }
                    if idResults.nextPage == nil || idResults.nextPage?.isEmpty == true { break }
                    idPage += 1
                }

                // Partition local state against the sweep (off-main). The
                // trashed set is the UNION of both stores — grid index and
                // SwiftData have historically diverged, and a wrong flag in
                // either one hides the asset from the timeline.
                let container = modelContext.container
                let sweepIds = serverIds
                let partition = try await Task.detached(priority: .userInitiated) {
                    let bgContext = ModelContext(container)
                    var nonTrashed = [String]()
                    var trashed = Set(GridIndexStore.shared.allTrashedIds())
                    for local in try bgContext.fetch(FetchDescriptor<CachedAsset>()) {
                        if local.isTrashed {
                            trashed.insert(local.assetId)
                        } else if !trashed.contains(local.assetId) {
                            nonTrashed.append(local.assetId)
                        }
                    }
                    return DeletionReconciler.partition(
                        localNonTrashedIds: nonTrashed,
                        localTrashedIds: Array(trashed),
                        serverIds: sweepIds
                    )
                }.value

                // The sweep uses offset pagination over a dataset that can mutate
                // mid-sweep (new uploads, live-photo motion parts flipping to
                // hidden), so a miss is not proof of deletion — confirm each
                // candidate individually before trashing it. Capped per run;
                // leftovers are retried on the next reconcile.
                var confirmedTrashIds = [String]()
                var unverifiedCount = 0
                let verifyCap = 500
                if partition.missingCandidates.count > verifyCap {
                    AppLogger.sync.warning("Reconcile: \(partition.missingCandidates.count) sweep misses — verifying first \(verifyCap) this run")
                }
                for candidateId in partition.missingCandidates.prefix(verifyCap) {
                    do {
                        switch try await apiClient.fetchAssetServerState(id: candidateId) {
                        case .deleted, .trashed:
                            confirmedTrashIds.append(candidateId)
                        case .alive:
                            break // sweep miss (pagination race) — leave untouched
                        }
                    } catch {
                        unverifiedCount += 1 // transient error — leave untouched this run
                    }
                }

                if !confirmedTrashIds.isEmpty || !partition.restoreIds.isEmpty {
                    let trashSet = Set(confirmedTrashIds)
                    let restoreSet = Set(partition.restoreIds)
                    try await Task.detached(priority: .userInitiated) {
                        let bgContext = ModelContext(container)
                        bgContext.autosaveEnabled = false
                        for local in try bgContext.fetch(FetchDescriptor<CachedAsset>()) {
                            if trashSet.contains(local.assetId) {
                                local.isTrashed = true
                            } else if restoreSet.contains(local.assetId), local.isTrashed {
                                local.isTrashed = false
                            }
                        }
                        try bgContext.save()
                    }.value

                    deletedIds.append(contentsOf: confirmedTrashIds)
                    restoredIds.append(contentsOf: partition.restoreIds)
                    modelContext.rollback()
                    // Keep grid index in sync
                    GridIndexStore.shared.markTrashed(ids: confirmedTrashIds)
                    GridIndexStore.shared.unmarkTrashed(ids: partition.restoreIds)
                    AppLogger.sync.info("Reconcile: trashed \(confirmedTrashIds.count), restored \(partition.restoreIds.count) wrongly-trashed, \(unverifiedCount) unverified (of \(partition.missingCandidates.count) sweep misses)")
                }
                // Ein gedeckelter oder unvollständig geprüfter Lauf darf sich nicht als
                // erledigt eintragen — sonst wartet der Rest die vollen sechs Stunden.
                // Begründung und Rechnung stehen an `reconcileStamp`.
                syncState.lastDeletionReconcileAt = DeletionReconciler.reconcileStamp(
                    now: Date(),
                    candidateCount: partition.missingCandidates.count,
                    verifyCap: verifyCap,
                    unverifiedCount: unverifiedCount,
                    interval: reconcileInterval,
                    backlogRetryDelay: DeletionReconciler.reconcileBacklogRetryDelay
                )
                if partition.missingCandidates.count > verifyCap || unverifiedCount > 0 {
                    AppLogger.sync.info("Reconcile: Rückstand offen (\(partition.missingCandidates.count) Kandidaten, \(unverifiedCount) ungeprüft) — nächster Abgleich in \(Int(DeletionReconciler.reconcileBacklogRetryDelay / 60)) min statt in \(Int(reconcileInterval / 3600)) h")
                }
                isSilentBackground = false
            }

            // Sync albums (owned + shared) into SwiftData; notifies UI on changes
            try await syncAlbumsToCache()

            // Reconcile trash: remove locally-trashed assets that no longer exist in server trash.
            // This handles the case where the user empties the trash on the Immich web/app —
            // those permanently-deleted assets must also vanish from our local trash view.
            //
            // PERFORMANCE: This is expensive (paginates server trash), so we only run it
            // if it hasn't run in the last 24 hours, or if this is a manual sync.
            var purgedTrashIds: [String] = []
            let oneDay: TimeInterval = 24 * 60 * 60
            let needsReconcile = trigger == .manual || syncState.lastTrashReconcileAt == nil ||
                                 Date().timeIntervalSince(syncState.lastTrashReconcileAt ?? .distantPast) > oneDay

            if needsReconcile {
                do {
                    let serverTrashIds = try await apiClient.getTrashIds()
                    let serverTrashSet = Set(serverTrashIds)

                    let localTrashedPredicate = #Predicate<CachedAsset> { $0.isTrashed == true }
                    let localTrashed = try modelContext.fetch(FetchDescriptor(predicate: localTrashedPredicate))

                    // Fehlt im Server-Papierkorb — das allein beweist noch keine
                    // endgültige Löschung, siehe `DeletionReconciler.purgeVerdict`.
                    // Jeder Kandidat wird einzeln bestätigt, mit demselben Deckel wie
                    // die Löschabgleichung darüber.
                    let purgeCandidates = localTrashed.filter { !serverTrashSet.contains($0.assetId) }
                    var restoredFromPurge: [String] = []
                    var unverifiedPurgeCount = 0
                    let purgeCap = 500
                    let purgeBacklog = purgeCandidates.count > purgeCap
                    if purgeBacklog {
                        AppLogger.sync.warning("Trash reconcile: \(purgeCandidates.count) Kandidaten — in diesem Lauf werden \(purgeCap) geprüft")
                    }

                    for local in purgeCandidates.prefix(purgeCap) {
                        let verdict: DeletionReconciler.PurgeVerdict
                        do {
                            verdict = DeletionReconciler.purgeVerdict(
                                serverState: try await apiClient.fetchAssetServerState(id: local.assetId)
                            )
                        } catch {
                            unverifiedPurgeCount += 1 // vorübergehender Fehler — unangetastet lassen
                            continue
                        }
                        switch verdict {
                        case .purge:
                            purgedTrashIds.append(local.assetId)
                            modelContext.delete(local)
                        case .restore:
                            local.isTrashed = false
                            restoredFromPurge.append(local.assetId)
                        case .keep:
                            break
                        }
                    }

                    if !purgedTrashIds.isEmpty || !restoredFromPurge.isEmpty {
                        try modelContext.save()
                        modelContext.rollback()
                        GridIndexStore.shared.delete(ids: purgedTrashIds)
                        AlbumMembershipStore.shared.removeAssets(ids: purgedTrashIds)
                        GridIndexStore.shared.unmarkTrashed(ids: restoredFromPurge)
                        restoredIds.append(contentsOf: restoredFromPurge)
                        AppLogger.sync.info("Trash reconcile: \(purgedTrashIds.count) endgültig gelöscht entfernt, \(restoredFromPurge.count) wiederhergestellt, \(unverifiedPurgeCount) ungeprüft (von \(purgeCandidates.count) Kandidaten)")
                    }
                    // Bei vollem Deckel den Zeitstempel **nicht** setzen: Sonst zöge
                    // sich das Leeren eines großen Papierkorbs über Wochen hin, weil
                    // dieser Abgleich nur alle 24 h läuft. So holt ihn der nächste
                    // Sync sofort wieder ein, bis der Rückstand abgetragen ist.
                    if !purgeBacklog {
                        syncState.lastTrashReconcileAt = Date()
                    }
                    try modelContext.save()
                } catch {
                    // Non-fatal: trash reconciliation failure should not fail the whole sync
                    AppLogger.sync.warning("Trash reconciliation failed (non-fatal): \(error)")
                }
            }

            // Finalize. Bezugspunkt ist der Beginn des Laufs — siehe `nextCheckpoint`.
            syncState.lastSyncTimestamp = Self.nextCheckpoint(runStartedAt: startTime)
            syncState.totalAssetCount = serverTotal
            syncState.lastSyncDuration = Date().timeIntervalSince(startTime)
            syncState.syncTransport = .polling
            try modelContext.save()

            let duration = String(format: "%.1f", syncState.lastSyncDuration)
            let updatedCount = updatedIds.count
            let totalChanged = updatedCount + deletedIds.count + restoredIds.count + purgedTrashIds.count
            if totalChanged > 0 {
                syncStatus = "Synced \(totalChanged) changes (\(duration)s)"
            } else {
                syncStatus = "Up to date (\(duration)s)"
            }
            currentTransport = .polling
            if totalChanged > 0 {
                AppLogger.sync.info("Delta sync: +\(updatedCount) updated of \(processedCount) checked, -\(deletedIds.count) deleted, +\(restoredIds.count) restored, \(purgedTrashIds.count) trash-purged in \(duration)s [trigger=\(trigger.rawValue)]")
            } else {
                AppLogger.sync.debug("Delta sync: no changes in \(duration)s (\(processedCount) checked) [trigger=\(trigger.rawValue)]")
            }

            let changedIds = Array(updatedIds.union(Set(deletedIds)).union(Set(restoredIds)).union(Set(purgedTrashIds)))
            postChangedNotification(ids: changedIds)

            // --- Local File Cache: post-sync housekeeping (low-priority background task) ---
            let cacheDays = AppEnvironment.defaults.integer(forKey: "localFileCacheDays")
            let capturedContainer = modelContext.container
            let capturedClient = apiClient
            Task.detached(priority: .background) {
                // 1. Evict expired + trashed files
                await LocalFileCacheManager.shared.evictExpired(container: capturedContainer, cacheDays: cacheDays)
                // 2. Evict deleted/trashed assets from this sync run
                let evictIds = Array(Set(deletedIds).union(Set(purgedTrashIds)))
                if !evictIds.isEmpty {
                    await LocalFileCacheManager.shared.evict(ids: evictIds, container: capturedContainer)
                }
                // 3. Download pending assets (only if cache is enabled)
                if cacheDays > 0 {
                    await LocalFileCacheManager.shared.downloadPendingAssets(
                        container: capturedContainer,
                        apiClient: capturedClient,
                        cacheDays: cacheDays
                    )
                }
                // 4. Download offline albums
                await OfflineDownloadManager.shared.syncOfflineAlbums(
                    container: capturedContainer,
                    apiClient: capturedClient
                )
            }
            isSyncing = false
            isSilentBackground = false
            return SyncRunResult(changedCount: changedIds.count, transport: .polling)

        } catch {
            if let urlError = error as? URLError, urlError.code == .cancelled {
                AppLogger.sync.debug("Delta sync cancelled (likely due to overlapping trigger)")
                isSyncing = false
                isSilentBackground = false
                return SyncRunResult(changedCount: 0, transport: .polling)
            }
            syncError = "Sync failed: \(error.localizedDescription)"
            syncStatus = "Sync error"
            AppLogger.sync.error("Delta sync error: \(error)")
            isSyncing = false
            isSilentBackground = false
            return SyncRunResult(changedCount: 0, transport: .polling)
        }
    }

    // MARK: - EXIF Backfill
    //
    // Runs after a sync to populate missing EXIF data (cameraModel, city, lensModel, …)
    // for assets that were synced before `withExif: true` was added to the API calls.
    // Uses searchAssets in pages — no single-asset calls needed.

    // `exifBackfillIfNeeded` stand hier. Sie lief per `guard exifBackfillCompletedAt == nil`
    // genau einmal im App-Leben, paginierte über die *gesamte* Bibliothek und machte pro
    // Asset eine eigene SwiftData-Abfrage — bei 155.000 Assets 155 Requests und 155.000
    // Roundtrips. Ihr Fortschrittsnenner zählte zudem Assets mit, die nie EXIF haben
    // konnten, weshalb der Balken stehenblieb und dann auf „fertig" sprang.
    //
    // Ersetzt durch `exifCatchUp` (oben, begrenzt auf die Änderungen eines Syncs) und
    // `ExifRepairService` (manuell auslösbar, abbrechbar, fortsetzbar, ehrlich gezählt).
    // `exifCatchUp` ist inzwischen ebenfalls Geschichte: EXIF kommt als `AssetExifsV1`
    // direkt über den Stream.

    // MARK: - Stream-Based Delta Sync

    /// Sync via Immich Sync Stream API — more efficient than polling.
    /// All heavy work (network + SwiftData) runs off main actor via nonisolated function.
    /// Holt die EXIF-Zeilen einmal neu, damit die Maße im Grid-Index die
    /// EXIF-Orientierung tragen (siehe ``ExifOrientation``).
    ///
    /// Aufgebaut wie der Checksum-Nachlauf: Marke fällt erst nach einem erfolgreichen
    /// Replay, jeder Fehlschlag zählt gegen ein Budget, und ein Server ohne
    /// `DELETE /api/sync/ack` beendet die Sache sofort — dort liesse sich der
    /// Checkpoint nie zurücksetzen, ein Wiederholen wäre zwecklos.
    private func runOrientationBackfill(syncState: SyncState, client: SyncStreamClient) async {
        switch GridIndexStore.shared.orientationColumnComplete() {
        case true:
            // Frischinstallationen haben die Spalte längst gefüllt, bevor die Marke je
            // geprüft wird; der Nachlauf beendet sich damit selbst.
            GridIndexStore.shared.clearOrientationBackfillPending()
            AppLogger.sync.info("Orientierungs-Nachlauf: Spalte bereits vollständig — kein Replay nötig")
        case false:
            var resetGelungen = false
            do {
                try await client.deleteAcks(types: ["AssetExifV1"])
                resetGelungen = true
                AppLogger.sync.info("Orientierungs-Nachlauf: EXIF-Checkpoint zurückgesetzt, Replay startet")
            } catch SyncStreamError.ackFailed(404), SyncStreamError.ackFailed(405) {
                GridIndexStore.shared.clearOrientationBackfillPending()
                AppLogger.sync.info("Server kennt DELETE /sync/ack nicht — Orientierungs-Nachlauf entfällt")
            } catch {
                let grund = markFallbackReason(error: error, syncState: syncState)
                let versuche = GridIndexStore.shared.registerOrientationBackfillFailure()
                if versuche >= GridIndexStore.orientationBackfillMaxAttempts {
                    GridIndexStore.shared.clearOrientationBackfillPending()
                    AppLogger.sync.warning("Orientierungs-Nachlauf: \(versuche). Fehlschlag beim Checkpoint-Reset (\(grund)) — Budget aufgebraucht, Marke fällt: \(error)")
                } else {
                    AppLogger.sync.error("Orientierungs-Nachlauf: Checkpoint-Reset fehlgeschlagen (\(grund), Versuch \(versuche)/\(GridIndexStore.orientationBackfillMaxAttempts)): \(error)")
                }
            }

            guard resetGelungen else { return }
            do {
                _ = try await performStreamDeltaSync(syncState: syncState, client: client)
                GridIndexStore.shared.clearOrientationBackfillPending()
                AppLogger.sync.info("Orientierungs-Nachlauf abgeschlossen")
            } catch {
                let grund = markFallbackReason(error: error, syncState: syncState)
                let versuche = GridIndexStore.shared.registerOrientationBackfillFailure()
                if versuche >= GridIndexStore.orientationBackfillMaxAttempts {
                    GridIndexStore.shared.clearOrientationBackfillPending()
                    AppLogger.sync.warning("Orientierungs-Nachlauf: \(versuche). Fehlschlag beim Replay (\(grund)) — Budget aufgebraucht, Marke fällt: \(error)")
                } else {
                    AppLogger.sync.error("Orientierungs-Nachlauf: Replay fehlgeschlagen (\(grund), Versuch \(versuche)/\(GridIndexStore.orientationBackfillMaxAttempts)): \(error)")
                }
            }
        case nil:
            break  // Index nicht lesbar — nächster Sync fragt erneut.
        }
    }

    private func performStreamDeltaSync(syncState: SyncState, client: SyncStreamClient) async throws -> SyncRunResult {
        isSyncing = true
        syncIsStreaming = true
        syncError = nil
        syncStatus = "Streaming changes…"
        defer { syncIsStreaming = false }
        let startTime = Date()

        // Capture everything needed as Sendable values BEFORE going off-main
        let container = modelContext.container
        let apiClient = self.apiClient

        // Fortschritt für den EXIF-Erstlauf: nur sichtbar, wenn der Server
        // massenhaft EXIF ausspielt (erster Lauf nach Einführung des Typs).
        let showExifProgress: @Sendable (Int, Int?) -> Void = { [weak self] applied, total in
            Task { @MainActor in
                guard let self else { return }
                if let total {
                    self.syncStatus = "EXIF-Abgleich: \(applied) von \(total)…"
                } else {
                    self.syncStatus = "EXIF-Abgleich: \(applied)…"
                }
            }
        }

        // Run EVERYTHING (network + SwiftData) off the main actor
        let run = await Task.detached(priority: .userInitiated) {
            () -> (upserts: Int, deletes: Int, deletedIds: [String], changedIds: [String], metadataIds: [String], exifApplied: Int, error: (any Error)?) in

            // `changed`: Asset-Upserts/Deletes/Edits — rendertes Bild kann sich geändert
            // haben, gehört vor die Cache-Invalidierung. `metadataChanged`: reine
            // EXIF-Änderungen (GPS, Ort, Kamera…) — ändern nie das gerenderte Bild,
            // siehe `postChangedNotification`.
            var changed = Set<String>()
            var metadataChanged = Set<String>()
            var upserts = 0
            var deletedIds: [String] = []
            var exifApplied = 0
            var exifRetry: [SyncAssetExif] = []
            var exifTotal: Int?
            // Finding 5: Statistik-Endpunkt nur einmal versuchen — sonst blockiert ein
            // dauerhaft fehlschlagender Abruf jeden Batch mit ≥2500 EXIF-Zeilen erneut.
            var exifTotalAttempted = false
            // Finding 4: IDs, die in irgendeinem Batch bereits erfolgreich gematcht
            // wurden. Ein Nachzügler für dieselbe ID aus einem früheren Batch ist dann
            // veraltet — ein späterer Batch hat schon frischeres EXIF geschrieben.
            var matchedExifIds = Set<String>()

            // Finding 2: Der Sync Stream ackt pro Batch serverseitig — Nachzügler aus
            // bereits geackten Batches kommen nie wieder, egal ob der Lauf danach noch
            // regulär endet oder abbricht. Deshalb muss dieser Drain von BEIDEN Pfaden
            // aus laufen (regulärem Ende und catch), als kleiner Helfer statt Duplikat.
            func drainExifRetry() throws {
                guard !exifRetry.isEmpty else { return }
                // Finding 4: Stale Nachzügler verwerfen — für diese ID kam in einem
                // späteren Batch schon frisches EXIF an, die alte Zeile wäre ein
                // Rückschritt.
                let pending = exifRetry.filter { !matchedExifIds.contains($0.assetId) }
                exifRetry.removeAll()
                guard !pending.isEmpty else { return }
                let retry = try applySyncExifResults(pending, container: container)
                GridIndexStore.shared.updateExifFromSync(retry.matched)
                metadataChanged.formUnion(retry.changedIds)
                exifApplied += retry.matched.count
                if !retry.unmatched.isEmpty {
                    // EXIF-Zeilen, deren Asset-Zeile nicht dekodierbar war, sind geackt
                    // und kommen nicht wieder — exifCheckedAt bleibt NULL, die manuelle
                    // EXIF-Reparatur findet sie.
                    AppLogger.sync.info("\(retry.unmatched.count) EXIF-Zeilen ohne lokales Asset verworfen (vermutlich gesperrt)")
                }
            }

            do {
            // AssetsV1 lehnt der Server seit v3.1 mit HTTP 400 ab
            // ("SyncRequestType.AssetsV1 is deprecated, use SyncRequestType.AssetsV2 instead").
            // `AssetEditsV1`: Bearbeitungen aus Web und Telefon — ohne sie zeigte das
            // Raster dort gedrehte oder beschnittene Fotos im Originalzustand, bis man
            // sie einzeln öffnete (siehe EditedAssetsStore).
            try await client.sync(types: ["AssetsV2", "AssetExifsV1", "AssetEditsV1"]) { batch in
                // Bearbeitungen: Vermerke speichern, Markierungen setzen bzw. entfernen.
                // Beides ändert, welche Fassung die Bild-URLs holen — also `changed`,
                // damit die gecachten Thumbnails fallen.
                if !batch.edits.isEmpty || !batch.editDeletes.isEmpty {
                    let edits = try applySyncEditResults(
                        upserts: batch.edits,
                        deletedEditIds: batch.editDeletes,
                        container: container
                    )
                    EditedAssetsStore.shared.mark(contentsOf: edits.marked)
                    for assetId in edits.unmarked { EditedAssetsStore.shared.unmark(assetId) }
                    changed.formUnion(edits.marked)
                    changed.formUnion(edits.unmarked)
                    if !edits.marked.isEmpty || !edits.unmarked.isEmpty {
                        AppLogger.sync.info("Bearbeitungen aus dem Stream: \(edits.marked.count) markiert, \(edits.unmarked.count) zurückgenommen")
                    }
                }

                // Assets (Upserts + Deletes) — bestehende Logik, jetzt je Batch.
                if !batch.upserted.isEmpty || !batch.deleted.isEmpty {
                    let counts = try applySyncStreamResults(
                        upserted: batch.upserted,
                        deleted: batch.deleted,
                        container: container
                    )
                    upserts += counts.0
                    deletedIds.append(contentsOf: batch.deleted)
                    changed.formUnion(counts.1)
                }

                // EXIF aus dem Stream — ersetzt den früheren Nachzug (exifCatchUp).
                if !batch.exifs.isEmpty {
                    // Ein überwiegend aus EXIF bestehender Batch heißt Massen-Replay
                    // (Erstlauf des Typs) → einmalig den Nenner fürs „von N" holen.
                    // Bewusst nicht == batchSize: Batches können Typen mischen.
                    if !exifTotalAttempted, batch.exifs.count >= 2500 {
                        exifTotalAttempted = true
                        exifTotal = try? await apiClient.getAssetStatistics().total
                    }
                    let result = try applySyncExifResults(batch.exifs, container: container)
                    GridIndexStore.shared.updateExifFromSync(result.matched)
                    // EXIF-only: ändert kein gerendertes Bild, siehe metadataChanged
                    // oben. Nicht in `changed` — sonst würde das Grid EXIF-Zeilen als
                    // Cache-invalidierende Änderung behandeln.
                    metadataChanged.formUnion(result.changedIds)
                    matchedExifIds.formUnion(result.matched.map(\.assetId))
                    exifRetry.append(contentsOf: result.unmatched)
                    exifApplied += result.matched.count
                    if exifTotal != nil {
                        showExifProgress(exifApplied, exifTotal)
                    }
                }
            }

            // Nachzügler: EXIF-Zeilen, deren Asset erst in einem späteren Batch
            // ankam, jetzt genau einmal erneut versuchen. Was dann noch ohne
            // Asset ist, wurde absichtlich nie gespeichert (gesperrt) — die
            // Zeile ist geackt, der Rest wird verworfen.
            try drainExifRetry()
            } catch {
                // Der Sync Stream ackt serverseitig pro Batch — bereits quittierte
                // Batches kommen nie wieder, egal ob ein späterer Batch abbricht.
                // Ohne diesen Zweig blieben ihre Änderungen zwar in SwiftData/
                // GridIndex persistiert, aber das Grid würde nie benachrichtigt
                // und bliebe bis zu einer unabhängigen Änderung oder einem
                // Neustart veraltet. Deshalb Fehler + bisherige changedIds
                // gemeinsam zurückgeben, statt hier zu werfen.
                //
                // Finding 2: Auch hier muss der EXIF-Nachzug laufen — dieselbe
                // Begründung wie oben gilt genauso für einen abgebrochenen Lauf.
                // Ein Fehler im Drain selbst darf aber nicht den eigentlichen
                // Abbruchgrund verschlucken, deshalb separat gefangen und nur geloggt.
                do {
                    try drainExifRetry()
                } catch let drainError {
                    AppLogger.sync.warning("EXIF-Nachzügler-Drain nach Abbruch fehlgeschlagen: \(drainError)")
                }
                let metadataOnly = Array(metadataChanged.subtracting(changed))
                return (upserts, deletedIds.count, deletedIds, Array(changed), metadataOnly, exifApplied, error)
            }

            let metadataOnly = Array(metadataChanged.subtracting(changed))
            return (upserts, deletedIds.count, deletedIds, Array(changed), metadataOnly, exifApplied, nil)
        }.value

        if let runError = run.error {
            postChangedNotification(ids: run.changedIds, metadataIds: run.metadataIds)
            throw runError
        }

        // Back on main actor — only lightweight UI state updates
        // Der Stream quittiert serverseitig; dieser Zeitstempel ist trotzdem der
        // Cursor, den ein späterer Rückfall aufs Polling benutzt (`performDeltaSync`
        // liest ihn als `lastSync`). Also derselbe Bezugspunkt wie dort.
        syncState.lastSyncTimestamp = Self.nextCheckpoint(runStartedAt: startTime)
        syncState.lastSyncDuration = Date().timeIntervalSince(startTime)
        syncState.lastSuccessfulStreamAt = Date()
        syncState.syncTransport = .stream
        syncState.serverSupportsStream = true
        syncState.streamAuthAvailable = true
        try modelContext.save()

        let duration = String(format: "%.1f", syncState.lastSyncDuration)
        let total = run.upserts + run.deletes + run.exifApplied
        syncProgress = 1.0
        if total > 0 {
            syncStatus = "Stream sync: \(run.upserts) updated, \(run.deletes) deleted, \(run.exifApplied) EXIF (\(duration)s)"
        } else {
            syncStatus = "Up to date via stream (\(duration)s)"
        }
        currentTransport = .stream
        AppLogger.sync.info("Stream sync: \(run.upserts) upserts, \(run.deletes) deletes, \(run.exifApplied) EXIF in \(duration)s")
        postChangedNotification(ids: run.changedIds, metadataIds: run.metadataIds)

        // Albums are not part of the AssetsV1 stream — mirror them here so album
        // changes made in web (create/rename/delete/add assets) appear without
        // relying on the polling fallback. Non-fatal on error.
        do {
            try await syncAlbumsToCache()
        } catch {
            AppLogger.sync.warning("Album sync after stream failed (non-fatal): \(error)")
        }

        // --- Local File Cache: post-sync housekeeping (low-priority background task) ---
        // IMPORTANT: This block must mirror the identical block in performDeltaSync.
        // Without it, the file cache is never populated when stream sync is active,
        // because the polling path (which had the cache triggering) is never reached.
        let cacheDays = AppEnvironment.defaults.integer(forKey: "localFileCacheDays")
        let capturedContainer = modelContext.container
        let capturedClient = apiClient
        Task.detached(priority: .background) {
            // 1. Evict expired files
            await LocalFileCacheManager.shared.evictExpired(container: capturedContainer, cacheDays: cacheDays)
            // 1b. Evict permanently deleted assets from this stream run
            if !run.deletedIds.isEmpty {
                await LocalFileCacheManager.shared.evict(ids: run.deletedIds, container: capturedContainer)
            }
            // 2. Download pending assets (only if cache is enabled)
            if cacheDays > 0 {
                await LocalFileCacheManager.shared.downloadPendingAssets(
                    container: capturedContainer,
                    apiClient: capturedClient,
                    cacheDays: cacheDays
                )
            }
            // 3. Download offline albums
            await OfflineDownloadManager.shared.syncOfflineAlbums(
                container: capturedContainer,
                apiClient: capturedClient
            )
        }

        return SyncRunResult(changedCount: run.changedIds.count, transport: .stream)
    }

    // MARK: - Album Sync

    /// Fetch owned + shared albums and mirror them into SwiftData.
    /// Posts `.albumsDidChange` when anything actually changed, so the sidebar
    /// and open album views refresh without user interaction. Used by BOTH
    /// delta paths — the stream API only covers assets, not albums.
    private func syncAlbumsToCache() async throws {
        async let albumsFetch = apiClient.getAlbums()
        async let sharedAlbumsFetch = apiClient.getSharedAlbums()
        let (albums, sharedAlbums) = try await (albumsFetch, sharedAlbumsFetch)

        let container = modelContext.container
        let changed = try await Task.detached(priority: .userInitiated) {
            try applyAlbumSync(owned: albums, shared: sharedAlbums, container: container)
        }.value

        if changed {
            AppLogger.sync.info("Album sync: server-side album changes applied — notifying UI")
            // "source: sync" → the cache already holds fresh server data, so the
            // UI only needs a cache reload, not another round of API fetches.
            NotificationCenter.default.post(
                name: .albumsDidChange,
                object: nil,
                userInfo: ["source": "sync"]
            )
        }

        // Album membership is the one thing neither the stream nor this call returns —
        // it needs a request per album. We already have every album's updatedAt and
        // assetCount here, which is exactly the change signal the indexer diffs against,
        // so this is the natural place to kick it off. Detached and unawaited: the first
        // full fill takes minutes and must never hold up a sync cycle.
        let allAlbums = albums + sharedAlbums
        let capturedClient = apiClient
        Task.detached(priority: .background) {
            await AlbumMembershipIndexer.shared.refresh(albums: allAlbums, apiClient: capturedClient)
        }

        // Albums deleted server-side are already gone from SwiftData (applyAlbumSync);
        // drop their membership rows too, or they'd linger forever — staleAlbumIds only
        // looks at albums that still exist.
        let serverAlbumIds = Set(allAlbums.map(\.id))
        Task.detached(priority: .background) {
            for albumId in AlbumMembershipStore.shared.indexedAlbumIds()
            where !serverAlbumIds.contains(albumId) {
                AlbumMembershipStore.shared.removeAlbum(albumId: albumId)
            }
        }
    }

    // MARK: - Helpers

    private func fetchOrCreateSyncState() -> SyncState {
        let descriptor = FetchDescriptor<SyncState>()
        if let existing = try? modelContext.fetch(descriptor).first {
            return existing
        }
        let state = SyncState()
        modelContext.insert(state)
        try? modelContext.save()
        return state
    }

    private func decodeAckMap(_ serialized: String) -> [String: String] {
        guard let data = serialized.data(using: .utf8) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }

    private func encodeAckMap(_ value: [String: String]) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    /// EXIF ändert kein gerendertes Bild — Metadaten-IDs invalidieren keine
    /// Bild-Caches. Deshalb getrennte Schlüssel: `ids` sind Asset-Upserts/Deletes/
    /// Edits (Cache-Invalidierung darf NUR diese lesen), `metadataIds` sind reine
    /// EXIF-Änderungen (Daten-/Grid-Refresh braucht die Vereinigung aus beiden).
    private func postChangedNotification(ids: [String], metadataIds: [String] = []) {
        guard !ids.isEmpty || !metadataIds.isEmpty else { return }
        NotificationCenter.default.post(
            name: .syncAssetsChanged,
            object: nil,
            userInfo: ["ids": ids, "metadataIds": metadataIds]
        )
    }

    private func markFallbackReason(error: Error, syncState: SyncState) -> String {
        if case let SyncStreamError.httpError(code, _) = error {
            if code == 404 || code == 501 {
                syncState.serverSupportsStream = false
                syncState.syncTransport = .polling
                try? modelContext.save()
                return "stream unsupported"
            }
            if code == 403 || code == 401 {
                syncState.streamAuthAvailable = false
                syncState.syncTransport = .polling
                try? modelContext.save()
                return "stream auth unavailable"
            }
        }
        if case SyncStreamError.authRequired = error {
            syncState.streamAuthAvailable = false
            syncState.syncTransport = .polling
            try? modelContext.save()
            return "stream auth required"
        }
        return "transient stream error"
    }
}

// MARK: - Background Sync Helpers (completely off @MainActor)

/// Mirror the server's album list into SwiftData. Returns true if anything
/// changed (album added/removed/renamed, cover or asset count changed, …).
///
/// `internal` statt `private`, damit die Tests sie direkt aufrufen können —
/// wie `applySyncStreamResults` weiter unten. Der Abgleich löscht lokale
/// Albumzeilen; das gehört abgedeckt.
func applyAlbumSync(
    owned: [Album],
    shared: [Album],
    container: ModelContainer
) throws -> Bool {
    let bgContext = ModelContext(container)
    bgContext.autosaveEnabled = false
    var changed = false

    let existingAlbums = try bgContext.fetch(FetchDescriptor<CachedAlbum>())
    var existingById: [String: CachedAlbum] = [:]
    for album in existingAlbums {
        existingById[album.albumId] = album
    }

    // Remove albums that no longer exist on the server
    let serverAlbumIds = Set(owned.map(\.id)).union(shared.map(\.id))
    for existing in existingAlbums where !serverAlbumIds.contains(existing.albumId) {
        bgContext.delete(existing)
        changed = true
    }

    func upsert(_ album: Album, isShared: Bool) {
        if let existing = existingById[album.id] {
            if existing.update(from: album) { changed = true }
            if existing.isShared != isShared {
                existing.isShared = isShared
                changed = true
            }
        } else {
            let cached = CachedAlbum(from: album)
            cached.isShared = isShared
            bgContext.insert(cached)
            changed = true
        }
    }
    // An owned album that is also shared appears in BOTH lists — upsert each
    // album exactly once (shared wins) or the isShared flag flaps every cycle
    // and reports a phantom change.
    let sharedIds = Set(shared.map(\.id))
    for album in owned where !sharedIds.contains(album.id) {
        upsert(album, isShared: false)
    }
    for album in shared {
        upsert(album, isShared: true)
    }

    try bgContext.save()
    return changed
}

/// Apply sync stream results to SwiftData on the CALLING thread.
/// This is a free function — NOT on @MainActor — so it runs on whatever
/// thread the caller is on (should be a background thread from Task.detached).
///
/// `internal` statt `private`, damit die Tests sie direkt aufrufen können.
func applySyncStreamResults(
    upserted: [SyncAsset],
    deleted: [String],
    container: ModelContainer
) throws -> (Int, [String]) {
    let bgContext = ModelContext(container)
    bgContext.autosaveEnabled = false

    // Apply upserts in batches
    var upsertCount = 0
    var changedIds = Set<String>()
    for syncAsset in upserted {
        let assetId = syncAsset.id
        let predicate = #Predicate<CachedAsset> { $0.assetId == assetId }
        var descriptor = FetchDescriptor(predicate: predicate)
        descriptor.fetchLimit = 1

        // Gesperrte Assets werden nie lokal gespeichert – sie sind nur live
        // abrufbar (der gesperrte Ordner lädt direkt über die API). Wandert ein
        // bereits gecachtes Asset dorthin, muss der vorhandene Datensatz weg:
        // "locked" bildet sich auf keines der Flags ab, das Asset bliebe sonst
        // mit Dateiname, Datum und Thumbhash im Store liegen. Gleiche Regel wie
        // in GridIndexStore.upsertFromSync.
        if syncAsset.visibility == "locked" {
            if let existing = try bgContext.fetch(descriptor).first {
                bgContext.delete(existing)
                changedIds.insert(assetId)
            }
            continue
        }

        if let existing = try bgContext.fetch(descriptor).first {
            if existing.update(fromSync: syncAsset) {
                changedIds.insert(syncAsset.id)
            }
        } else {
            bgContext.insert(CachedAsset(fromSync: syncAsset))
            changedIds.insert(syncAsset.id)
        }
        upsertCount += 1

        // Save in batches of 500 to reduce memory pressure
        if upsertCount % 500 == 0 {
            try bgContext.save()
        }
    }

    // Apply deletions. AssetDeleteV1 means the asset row is GONE on the server
    // (permanent delete / emptied trash) — plain trashing arrives as an AssetV1
    // upsert with deletedAt set. So remove the asset locally instead of merely
    // flagging it trashed, otherwise it lingers in the local trash view.
    for deletedId in deleted {
        let targetId = deletedId
        let predicate = #Predicate<CachedAsset> { $0.assetId == targetId }
        var descriptor = FetchDescriptor(predicate: predicate)
        descriptor.fetchLimit = 1

        if let cached = try bgContext.fetch(descriptor).first {
            bgContext.delete(cached)
        }
        changedIds.insert(deletedId)
    }

    try bgContext.save()

    // Keep grid index in sync
    GridIndexStore.shared.upsertFromSync(upserted)
    if !deleted.isEmpty {
        GridIndexStore.shared.delete(ids: deleted)
        AlbumMembershipStore.shared.removeAssets(ids: deleted)
    }

    return (upsertCount, Array(changedIds))
}

/// Ergebnis eines EXIF-Batch-Abgleichs gegen den lokalen Bestand.
struct SyncExifApplyResult {
    /// Asset lokal vorhanden — EXIF wurde angewendet (auch wenn wertgleich).
    let matched: [SyncAssetExif]
    /// Teilmenge von `matched`: mindestens ein Feld hat sich geändert.
    let changedIds: [String]
    /// Kein lokales Asset. Entweder ein Nachzügler (Asset kommt in einem
    /// späteren Batch) oder absichtlich nicht gespeichert (gesperrt) —
    /// die Unterscheidung trifft der Aufrufer per Einmal-Retry am Laufende.
    let unmatched: [SyncAssetExif]
}

/// Ergebnis von ``applySyncEditResults(upserts:deletedEditIds:container:)``.
struct SyncEditApplyResult: Equatable {
    /// Assets mit (mindestens) einer Bearbeitung aus diesem Batch.
    let marked: [String]
    /// Assets, deren letzte Server-Bearbeitung in diesem Batch entfernt wurde.
    let unmarked: [String]
}

/// Wendet Bearbeitungen aus dem Sync-Stream (`AssetEditsV1`) auf `CachedAssetEdit` an.
///
/// Je Server-Bearbeitung eine Zeile mit der echten Edit-ID; beim Start liest
/// `LibraryViewModel` daraus die Markierungen. Erst die Löschungen, dann die neuen:
/// Der Server ersetzt beim erneuten Drehen alle Bearbeitungen (`PUT /edits`), schickt
/// also Löschen und Anlegen desselben Assets — in dieser Reihenfolge bleibt es markiert.
///
/// Verliert ein Asset seine letzte Server-Bearbeitung, fällt auch der Vermerk des
/// eigenen Drehens (`local-<assetId>`) — er überbrückt nur die Zeit, bis der Stream die
/// Bearbeitung meldet. Sonst hinge `edited=true` an einem Foto, dessen Bearbeitung im
/// Web zurückgenommen wurde.
///
/// Bewusst ohne `EditedAssetsStore`: Der Aufrufer setzt die Markierungen. So bleibt die
/// Funktion mit einem In-Memory-Container testbar.
func applySyncEditResults(
    upserts: [SyncAssetEditV1],
    deletedEditIds: [String],
    container: ModelContainer
) throws -> SyncEditApplyResult {
    guard !upserts.isEmpty || !deletedEditIds.isEmpty else {
        return SyncEditApplyResult(marked: [], unmarked: [])
    }
    let context = ModelContext(container)
    context.autosaveEnabled = false

    var touchedByDelete = Set<String>()
    if !deletedEditIds.isEmpty {
        let ids = Set(deletedEditIds)
        let descriptor = FetchDescriptor<CachedAssetEdit>(predicate: #Predicate { ids.contains($0.id) })
        for row in try context.fetch(descriptor) {
            touchedByDelete.insert(row.assetId)
            context.delete(row)
        }
    }

    var marked: [String] = []
    var seenMarked = Set<String>()
    if !upserts.isEmpty {
        let ids = Set(upserts.map(\.id))
        let descriptor = FetchDescriptor<CachedAssetEdit>(predicate: #Predicate { ids.contains($0.id) })
        let existing = Set(try context.fetch(descriptor).map(\.id))
        for edit in upserts {
            if !existing.contains(edit.id) {
                context.insert(CachedAssetEdit(
                    id: edit.id, assetId: edit.assetId,
                    brightness: nil, contrast: nil, saturation: nil, rotation: nil
                ))
            }
            if seenMarked.insert(edit.assetId).inserted { marked.append(edit.assetId) }
        }
    }
    try context.save()

    var unmarked: [String] = []
    for assetId in touchedByDelete.subtracting(seenMarked).sorted() {
        let descriptor = FetchDescriptor<CachedAssetEdit>(predicate: #Predicate { $0.assetId == assetId })
        let remaining = try context.fetch(descriptor)
        let localId = "local-\(assetId)"
        guard !remaining.contains(where: { $0.id != localId }) else { continue }
        for row in remaining { context.delete(row) }
        unmarked.append(assetId)
    }
    try context.save()

    return SyncEditApplyResult(marked: marked, unmarked: unmarked)
}

/// Wendet EXIF-Zeilen aus dem Sync-Stream auf den SwiftData-Bestand an.
///
/// Bewusst ohne Grid-Index-Zugriff: Der Aufrufer reicht `matched` an
/// `GridIndexStore.updateExifFromSync` weiter. So bleibt diese Funktion mit
/// einem In-Memory-Container testbar, ohne in den echten Index zu schreiben.
func applySyncExifResults(
    _ exifs: [SyncAssetExif],
    container: ModelContainer
) throws -> SyncExifApplyResult {
    guard !exifs.isEmpty else {
        return SyncExifApplyResult(matched: [], changedIds: [], unmatched: [])
    }

    let bgContext = ModelContext(container)
    bgContext.autosaveEnabled = false

    var matched: [SyncAssetExif] = []
    var changedIds: [String] = []
    var unmatched: [SyncAssetExif] = []

    // In 500er-Häppchen: ein FetchDescriptor pro Häppchen statt pro Asset,
    // und die Prädikat-IN-Liste bleibt handlich (gleiches Maß wie die
    // Batch-Saves in applySyncStreamResults).
    var offset = 0
    while offset < exifs.count {
        let chunk = Array(exifs[offset..<min(offset + 500, exifs.count)])
        offset += chunk.count

        let ids = Set(chunk.map(\.assetId))
        let descriptor = FetchDescriptor<CachedAsset>(
            predicate: #Predicate { ids.contains($0.assetId) }
        )
        let cachedById = Dictionary(
            uniqueKeysWithValues: try bgContext.fetch(descriptor).map { ($0.assetId, $0) }
        )

        for exif in chunk {
            guard let cached = cachedById[exif.assetId] else {
                unmatched.append(exif)
                continue
            }
            if cached.update(fromSyncExif: exif) {
                changedIds.append(exif.assetId)
            }
            matched.append(exif)
        }
        try bgContext.save()
    }

    return SyncExifApplyResult(matched: matched, changedIds: changedIds, unmatched: unmatched)
}

// MARK: - Deletion Reconciliation

/// Pure decision logic for deletion reconciliation, kept free of SwiftData and
/// networking so it can be unit-tested.
///
/// The server-ID sweep uses offset pagination over a dataset that can mutate
/// mid-sweep (new uploads, live-photo motion parts flipping to hidden), so an
/// asset missing from the sweep is only a *candidate* for deletion — it must be
/// verified individually before being marked trashed. The reverse direction is
/// the self-healing path: a locally trashed asset that shows up in the sweep is
/// alive on the server and gets its flag cleared.
enum DeletionReconciler {
    struct Partition: Equatable {
        /// Local, not trashed, absent from the server sweep — verify against
        /// the server before marking trashed.
        var missingCandidates: [String] = []
        /// Local, marked trashed, but present in the server sweep — restore.
        var restoreIds: [String] = []
    }

    static func partition(
        localNonTrashedIds: [String],
        localTrashedIds: [String],
        serverIds: Set<String>
    ) -> Partition {
        Partition(
            missingCandidates: localNonTrashedIds.filter { !serverIds.contains($0) },
            restoreIds: localTrashedIds.filter { serverIds.contains($0) }
        )
    }

    /// Was mit einem lokal als gelöscht markierten Asset geschieht, das im
    /// Server-Papierkorb **fehlt**.
    enum PurgeVerdict: Equatable {
        /// Serverseitig endgültig gelöscht — der lokale Datensatz darf weg.
        case purge
        /// Lebt auf dem Server: anderswo aus dem Papierkorb geholt. Die lokale
        /// Markierung ist falsch und wird aufgehoben.
        case restore
        /// Widerspruch (Server meldet „im Papierkorb", die Papierkorbliste kannte
        /// es aber nicht) — nichts tun und beim nächsten Lauf erneut ansehen.
        case keep
    }

    /// Aus „fehlt im Server-Papierkorb" folgt **nicht** „endgültig gelöscht": Genau
    /// so sieht auch ein Asset aus, das auf einem anderen Gerät wiederhergestellt
    /// wurde. Die beiden auseinanderzuhalten kostet einen Einzelabruf — ihn zu
    /// sparen kostet im Zweifel das Asset, denn der Papierkorb-Abgleich löscht den
    /// lokalen Datensatz, und der Delta-Sync holt ihn nicht zurück: Seine
    /// Wiederherstellung liegt dann bereits vor dem Checkpoint.
    ///
    /// Dieselbe Unterscheidung trifft `partition` weiter oben schon in der
    /// Gegenrichtung (`restoreIds`).
    static func purgeVerdict(serverState: ImmichAPIClient.AssetServerState) -> PurgeVerdict {
        switch serverState {
        case .deleted: .purge
        case .alive: .restore
        case .trashed: .keep
        }
    }

    /// Der Wert, der nach einem Löschabgleich in `lastDeletionReconcileAt` gehört.
    ///
    /// Ein Lauf prüft höchstens `verifyCap` Kandidaten und lässt die aus, deren
    /// Einzelabruf an einem vorübergehenden Fehler scheiterte. Beides heißt: Es ist
    /// noch Arbeit offen. Ein Stempel auf `now` behauptete dagegen einen fertigen
    /// Lauf, und der nächste käme erst nach `interval` (sechs Stunden). Bei 3 000
    /// Kandidaten wären das 36 Stunden, in denen serverseitig gelöschte Aufnahmen
    /// weiter in der Timeline stehen.
    ///
    /// Der Papierkorb-Abgleich löst dasselbe Problem, indem er den Zeitstempel bei
    /// vollem Deckel gar nicht setzt (`if !purgeBacklog`). Wörtlich übernehmen lässt
    /// sich das hier nicht: Dieser Abgleich lädt zuvor **alle** Server-IDs, was bei
    /// großen Bibliotheken Minuten dauert und laut dem Kommentar an seinem Aufrufer
    /// die übrige Sync-Pipeline verdrängt. Liefe er nach jedem gedeckelten Lauf
    /// sofort wieder, träte an die Stelle der langen Wartezeit ein Dauerlauf.
    ///
    /// Deshalb eine kurze Nachfrist: zurückdatiert um `interval - backlogRetryDelay`,
    /// womit der nächste Sync nach `backlogRetryDelay` wieder abgleichen darf.
    static func reconcileStamp(
        now: Date,
        candidateCount: Int,
        verifyCap: Int,
        unverifiedCount: Int,
        interval: TimeInterval,
        backlogRetryDelay: TimeInterval
    ) -> Date {
        let vollstaendig = candidateCount <= verifyCap && unverifiedCount == 0
        return vollstaendig ? now : now.addingTimeInterval(backlogRetryDelay - interval)
    }

    /// Nachfrist bis zum nächsten Löschabgleich, wenn der letzte Lauf Arbeit
    /// offen lassen musste. Lang genug, dass die regulären Sync-Zyklen (30–60 s)
    /// dazwischen durchkommen.
    static let reconcileBacklogRetryDelay: TimeInterval = 10 * 60
}
