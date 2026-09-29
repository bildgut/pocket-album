import Foundation
import Photos
import SwiftData
import CryptoKit
import ImageIO
import AVFoundation

// MARK: - Upload Session

/// Groups related uploads (e.g. one drag-drop batch or one album sync) for UI and retry.
struct UploadSession: Identifiable {
    let id: UUID
    let label: String
    let createdAt: Date

    init(id: UUID = UUID(), label: String, createdAt: Date = Date()) {
        self.id = id
        self.label = label
        self.createdAt = createdAt
    }
}

// MARK: - Upload Item

/// Tracks the state of a single upload
struct UploadItem: Identifiable {
    let id: UUID
    let fileURL: URL
    let fileName: String
    let albumId: String?           // nil = upload to library only
    let sourceLocalIdentifier: String?
    let livePhotoVideoId: String?  // Immich asset ID of the paired video (for Live Photos)
    let sessionId: UUID
    /// Whether this item was persisted to SwiftData (file-based uploads only; not Apple Photos temp-exports)
    let isPersisted: Bool
    var state: UploadState = .pending
    var progress: Double = 0
    var retryCount: Int = 0

    init(
        id: UUID = UUID(),
        fileURL: URL,
        fileName: String,
        albumId: String?,
        sourceLocalIdentifier: String?,
        livePhotoVideoId: String? = nil,
        sessionId: UUID = UUID(),
        isPersisted: Bool = false,
        retryCount: Int = 0
    ) {
        self.id = id
        self.fileURL = fileURL
        self.fileName = fileName
        self.albumId = albumId
        self.sourceLocalIdentifier = sourceLocalIdentifier
        self.livePhotoVideoId = livePhotoVideoId
        self.sessionId = sessionId
        self.isPersisted = isPersisted
        self.retryCount = retryCount
    }

    enum UploadState: Equatable {
        case pending
        case uploading
        case complete(assetId: String)
        case duplicate(assetId: String)
        case failed(String)
        case retrying(attempt: Int, after: TimeInterval)
        /// Upload succeeded but the server checksum does not match the local SHA-1.
        case checksumMismatch(assetId: String, localHash: String, serverHash: String)
    }
}

// MARK: - Retry Policy

enum RetryPolicy {
    static let maxAttempts = 3
    /// Backoff delays in seconds: 5s, 30s, 5min
    static let backoffDelays: [TimeInterval] = [5, 30, 300]

    static func delay(for attempt: Int) -> TimeInterval {
        backoffDelays[min(attempt, backoffDelays.count - 1)]
    }

    /// Returns true for transient errors (network, server overload) that are worth retrying.
    static func isRetryable(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost,
                 .timedOut, .cannotConnectToHost, .cannotFindHost,
                 .dnsLookupFailed, .dataNotAllowed:
                return true
            default:
                return false
            }
        }
        if case APIError.httpError(let code) = error, (500...599).contains(code) {
            return true
        }
        return false
    }
}

/// Manages concurrent file uploads to Immich.
@Observable
@MainActor
final class UploadManager {
    var items: [UploadItem] = []
    var sessions: [UploadSession] = []

    var isUploading: Bool {
        items.contains(where: {
            $0.state == .uploading || $0.state == .pending
            || { if case .retrying = $0.state { return true }; return false }($0)
        })
    }

    var completedCount: Int {
        items.filter {
            if case .complete = $0.state { return true }
            if case .duplicate = $0.state { return true }
            if case .checksumMismatch = $0.state { return true }
            return false
        }.count
    }
    var duplicateCount: Int { items.filter { if case .duplicate = $0.state { return true }; return false }.count }
    var failedCount: Int { items.filter { if case .failed = $0.state { return true }; return false }.count }
    var checksumMismatchCount: Int { items.filter { if case .checksumMismatch = $0.state { return true }; return false }.count }

    /// Fraction of uploads that should trigger a stichproben-style checksum validation.
    /// 10 % of completed (non-duplicate) uploads are spot-checked.
    nonisolated private static let checksumSampleRate: Double = 0.10

    private let apiClient: ImmichAPIClient
    private let maxConcurrent = 3
    private var completionHandlers: [UUID: (Result<String, Error>) -> Void] = [:]

    // SwiftData context for persistent queue (optional – set after init by the owning view)
    var modelContext: ModelContext?

    /// Anteil der Uploads, der stichprobenartig per Checksumme geprüft wird.
    /// Injizierbar für Tests (1.0 = jeder Upload wird geprüft).
    private let checksumSampleRate: Double

    init(apiClient: ImmichAPIClient, checksumSampleRate: Double = UploadManager.checksumSampleRate) {
        self.apiClient = apiClient
        self.checksumSampleRate = checksumSampleRate
    }

    // MARK: - Restore on launch

    /// Reload any previously persisted pending/failed uploads and re-enqueue them.
    /// Call once after `modelContext` is set (e.g. from `.onAppear`).
    func restorePendingUploads() {
        guard let ctx = modelContext else { return }
        let entries = (try? ctx.fetch(FetchDescriptor<UploadQueueEntry>())) ?? []
        guard !entries.isEmpty else { return }

        AppLogger.upload.info("UploadManager: restoring \(entries.count) persisted upload(s) from queue")

        // Group entries by session so we can restore session labels
        var seenSessions: [String: UploadSession] = [:]
        for entry in entries {
            let sessionUUID = UUID(uuidString: entry.sessionId) ?? UUID()
            if seenSessions[entry.sessionId] == nil {
                seenSessions[entry.sessionId] = UploadSession(
                    id: sessionUUID,
                    label: entry.sessionLabel,
                    createdAt: entry.createdAt
                )
            }
        }
        for session in seenSessions.values {
            if !sessions.contains(where: { $0.id == session.id }) {
                sessions.append(session)
            }
        }

        let restoredItems = entries.map { entry in
            UploadItem(
                id: UUID(uuidString: entry.entryId) ?? UUID(),
                fileURL: entry.fileURL,
                fileName: entry.fileName,
                albumId: entry.albumId,
                sourceLocalIdentifier: nil,
                livePhotoVideoId: nil,
                sessionId: UUID(uuidString: entry.sessionId) ?? UUID(),
                isPersisted: true,
                retryCount: entry.retryCount
            )
        }
        items.append(contentsOf: restoredItems)
        processQueue()
    }

    // MARK: - Enqueue (file-based)

    /// Enqueue files for upload (optionally to specific album).
    /// A new session is created for this batch and all items are persisted to SwiftData.
    @discardableResult
    func enqueue(urls: [URL], albumId: String? = nil, sessionLabel: String? = nil) -> UploadSession {
        let session = UploadSession(
            label: sessionLabel ?? (urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) Dateien")
        )
        sessions.append(session)

        let newItems = urls.map { url in
            UploadItem(
                fileURL: url,
                fileName: url.lastPathComponent,
                albumId: albumId,
                sourceLocalIdentifier: nil,
                livePhotoVideoId: nil,
                sessionId: session.id,
                isPersisted: true
            )
        }
        items.append(contentsOf: newItems)
        persistItems(newItems, session: session)
        processQueue()
        return session
    }

    /// Enqueue a single Apple Photos export and receive upload completion.
    /// Apple Photos temp-exports are NOT persisted (files are ephemeral temp paths).
    func enqueueApplePhoto(
        url: URL,
        localIdentifier: String,
        livePhotoVideoId: String? = nil,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let item = UploadItem(
            fileURL: url,
            fileName: url.lastPathComponent,
            albumId: nil,
            sourceLocalIdentifier: localIdentifier,
            livePhotoVideoId: livePhotoVideoId,
            sessionId: UUID(),
            isPersisted: false
        )
        completionHandlers[item.id] = completion
        items.append(item)
        processQueue()
    }

    // MARK: - Retry

    /// Retry all failed items (optionally filtered to one session).
    func retryFailed(sessionId: UUID? = nil) {
        for i in items.indices {
            guard case .failed = items[i].state else { continue }
            if let sid = sessionId, items[i].sessionId != sid { continue }
            items[i].state = .pending
            items[i].retryCount = 0
            // Update persisted retry count
            updatePersistedRetryCount(for: items[i])
        }
        processQueue()
    }

    /// Ob ein Eintrag fertig ist — gleich mit welchem Ausgang.
    ///
    /// Eine Stelle statt zwei: In `clearCompleted` stand diese Aufzählung wörtlich
    /// zweimal, einmal für `removePersistedItems` und einmal für das Entfernen aus
    /// `items`. Liefen die beiden auseinander — etwa weil ein fünfter Endzustand nur in
    /// einer der Listen landet —, bliebe ein gespeicherter Eintrag ohne Zeile in der
    /// Oberfläche zurück oder umgekehrt: Er wäre weder sichtbar noch löschbar.
    ///
    /// Bewusst **nicht** dieselbe Menge wie `completedCount`: Die zählt `failed` nicht
    /// mit, weil sie den Fortschritt misst. Hier geht es darum, ob noch etwas passiert.
    nonisolated static func isFinished(_ item: UploadItem) -> Bool {
        switch item.state {
        case .complete, .duplicate, .failed, .checksumMismatch: return true
        case .pending, .uploading, .retrying:                   return false
        }
    }

    /// Clear completed/failed items from the list
    func clearCompleted() {
        removePersistedItems(items.filter(Self.isFinished))
        items.removeAll(where: Self.isFinished)
        pruneEmptySessions()
    }

    func clearAll() {
        removePersistedItems(items)
        items.removeAll()
        sessions.removeAll()
    }

    // MARK: - Queue Processing

    private func processQueue() {
        let activeCount = items.filter { $0.state == .uploading }.count
        let remaining = maxConcurrent - activeCount

        guard remaining > 0 else { return }

        // Der Zustandswechsel gehört **hierhin** und nicht in `upload`: `Task { }`
        // startet erst nach dem laufenden Durchlauf. Setzte erst `upload` den
        // Zustand, stünde das Item bis dahin weiter auf `.pending` — und jeder
        // weitere `processQueue`-Aufruf im selben Durchlauf reihte es erneut ein.
        //
        // Das ist keine graue Theorie: `MainView` und `AlbumDetailView` reihen beim
        // Ziehen **je Datei** einzeln ein, alle im selben Durchlauf. Sechs gezogene
        // Dateien ergaben so 27 gleichzeitige Uploads statt sechs, `maxConcurrent`
        // war wirkungslos, und der Vorab-Abgleich per Prüfsumme konnte nicht
        // greifen, weil alle Läufe gleichzeitig starteten — der Server kannte die
        // Datei noch nicht. Bei großen Videos ging das direkt in die Leitung.
        let claimed = items.indices.filter { items[$0].state == .pending }.prefix(remaining)
        for index in claimed {
            items[index].state = .uploading
        }

        for item in claimed.map({ items[$0] }) {
            Task { await upload(item) }
        }
    }

    private func upload(_ item: UploadItem) async {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        // `processQueue` hat das Item bereits belegt; die Zuweisung hält `upload`
        // für sich genommen vollständig und ist ein reiner Selbstläufer.
        items[index].state = .uploading

        do {
            // 1. Hash the file — ausdrücklich vom Hauptthread herunter.
            //
            // `computeSHA1` ist synchron und streamt die ganze Datei. `nonisolated`
            // hebt nur die Isolationspflicht auf, es wechselt nicht den Thread: Aus
            // diesem `@MainActor`-Kontext heraus lief der Lesevorgang bisher auf dem
            // Hauptthread, und bei einem mehrere Gigabyte großen Video stand die
            // Oberfläche so lange. `.utility` statt `.background`, weil letzteres
            // neben einem laufenden Sync verhungert.
            let fileURL = item.fileURL
            guard let hash = await Task.detached(priority: .utility, operation: {
                Self.computeSHA1(url: fileURL)
            }).value else {
                throw NSError(domain: "UploadError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to compute file hash"])
            }

            // 2. Preflight duplicate check
            let checkItem = AssetBulkUploadCheckItem(id: item.fileName, checksum: hash)
            let checkResults = try await apiClient.checkBulkUpload(assets: [checkItem])

            let assetId: String
            let isDuplicate: Bool

            if let result = checkResults.first, result.action == "reject", let existingId = result.assetId {
                // Server already has this image! Skip actual upload.
                AppLogger.upload.info("File \(item.fileName) is a duplicate (assetId: \(existingId)), skipping upload.")
                assetId = existingId
                isDuplicate = true
            } else {
                // Not a duplicate (or server didn't provide assetId), proceed to upload
                let uploadResult = try await performUpload(item)
                assetId = uploadResult.id
                isDuplicate = uploadResult.isDuplicate
            }

            // MARK: Checksum spot-check (stichprobenartig, ~10 % der Uploads)
            var finalState: UploadItem.UploadState
            if isDuplicate {
                finalState = .duplicate(assetId: assetId)
            } else if shouldValidateChecksum(), let serverAssetChecksum = try? await fetchServerChecksum(assetId: assetId) {
                // Compare server SHA-1 against the local hash computed during preflight.
                // Wiederverwendet statt neu gerechnet: Es ist dieselbe Datei und
                // derselbe Wert, und ein zweiter Durchlauf läse sie noch einmal
                // vollständig — bei jedem zehnten Upload, für nichts.
                let localHash = hash
                // Immich returns checksum as base64 — convert to hex for comparison
                let serverHex = base64ToHex(serverAssetChecksum)
                if !localHash.isEmpty && !serverHex.isEmpty && localHash != serverHex {
                    AppLogger.upload.error("Checksum mismatch for \(item.fileName): local=\(localHash) server=\(serverHex) — retrying upload")

                    // Delete the corrupted asset on the server, then re-upload once.
                    try? await apiClient.deleteAssets(ids: [assetId], force: true)
                    let retryResult = try await performUpload(item)
                    let retryId = retryResult.id

                    // Validate retry checksum
                    if let retryServerChecksum = try? await fetchServerChecksum(assetId: retryId) {
                        let retryServerHex = base64ToHex(retryServerChecksum)
                        if !localHash.isEmpty && !retryServerHex.isEmpty && localHash != retryServerHex {
                            AppLogger.upload.error("Checksum mismatch persists after retry for \(item.fileName): local=\(localHash) server=\(retryServerHex)")
                            finalState = .checksumMismatch(assetId: retryId, localHash: localHash, serverHash: retryServerHex)
                        } else {
                            AppLogger.upload.info("Checksum OK after retry for \(item.fileName): \(localHash)")
                            finalState = .complete(assetId: retryId)
                        }
                    } else {
                        // Could not re-verify — treat as success to avoid false positives
                        finalState = .complete(assetId: retryId)
                    }
                } else {
                    AppLogger.upload.debug("Checksum OK for \(item.fileName): \(localHash)")
                    finalState = .complete(assetId: assetId)
                }
            } else {
                finalState = .complete(assetId: assetId)
            }

            if let idx = items.firstIndex(where: { $0.id == item.id }) {
                items[idx].state = finalState
            }
            removePersistedItem(id: item.id)
            // Die endgültige Asset-ID kann von `assetId` abweichen: bei einem
            // Checksummen-Fehler wird das hochgeladene Asset gelöscht und neu
            // hochgeladen — `assetId` zeigt danach auf ein gelöschtes Asset.
            // Alles Nachgelagerte muss deshalb `finalAssetId` verwenden.
            // For persistent checksumMismatch the caller is notified with success so the grid
            // still shows the asset; the mismatch is surfaced via the warning banner / log.
            let finalAssetId: String
            if case .checksumMismatch(let aid, _, _) = finalState { finalAssetId = aid }
            else if case .complete(let aid) = finalState { finalAssetId = aid }
            else { finalAssetId = assetId }
            completionHandlers.removeValue(forKey: item.id)?(.success(finalAssetId))

            // If album specified, add asset to album
            //
            // Der Fehlschlag wird vermerkt statt verschluckt. Der Upload selbst ist
            // geglückt — das Foto liegt in der Bibliothek —, aber die Zuordnung ist
            // genau das, was der Nutzer wollte: Dieser Pfad läuft beim Ziehen in ein
            // Album (`AlbumDetailView`) und beim Import mit gewähltem Album. Ohne
            // Vermerk meldete der Lauf „vollständig hochgeladen", und niemand erführe,
            // dass das Album leer blieb.
            //
            // Der Zustand des Items bleibt `.complete`: Das Hochladen *ist* gelungen,
            // und eine Meldung als Fehlschlag ließe das Foto aus dem Raster
            // verschwinden. Sichtbar wird es über den Sitzungs-Log — derselbe Weg, den
            // der Kommentar oben für die Prüfsummen-Abweichung beschreibt.
            if let albumId = item.albumId {
                do {
                    try await apiClient.addAssetsToAlbum(albumId: albumId, assetIds: [finalAssetId])
                } catch {
                    albumAssignmentFailures[item.id] = "Album-Zuordnung fehlgeschlagen: \(error.localizedDescription)"
                    AppLogger.upload.error(
                        "Album-Zuordnung für \(finalAssetId) → \(albumId) fehlgeschlagen: \(error)"
                    )
                }
            }

            // Fetch fresh asset from server so the grid can show it immediately
            // For videos, Immich may still be processing — getAssetDetail could fail
            var uploadedAsset: Asset
            if let serverAsset = try? await apiClient.getAssetDetail(id: finalAssetId) {
                AppLogger.upload.info("Fetched asset detail for \(assetId): type=\(String(describing: serverAsset.type))")
                uploadedAsset = serverAsset
            } else {
                // Build a minimal asset from upload metadata so it still appears in the grid
                AppLogger.upload.warning("getAssetDetail failed for \(assetId), building from upload metadata")
                let createdAt = await EXIFExtractor.extractCreationDate(from: item.fileURL) ?? 
                    (try? FileManager.default.attributesOfItem(atPath: item.fileURL.path))?[.creationDate] as? Date ?? Date()
                    
                // Millisekunden sind Pflicht: Asset.createdDate (und die
                // gleichnamige Property auf CachedAsset) parsen nur mit
                // .withFractionalSeconds — ohne sie bleibt das Datum des
                // Assets im Grid unlesbar.
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let videoExtensions: Set<String> = ["mp4", "mov", "avi", "mkv", "webm", "m4v", "mxf"]
                let isVideo = videoExtensions.contains(item.fileURL.pathExtension.lowercased())

                uploadedAsset = Asset(
                    id: finalAssetId,
                    type: isVideo ? .video : .image,
                    originalFileName: item.fileName,
                    fileCreatedAt: formatter.string(from: createdAt),
                    fileModifiedAt: formatter.string(from: createdAt),
                    isFavorite: false
                )
            }

            NotificationCenter.default.post(
                name: .assetsDidChange,
                object: nil,
                userInfo: ["uploadedAsset": uploadedAsset]
            )
            NotificationCenter.default.post(name: .localAssetMutation, object: nil)

            // If the first getAssetDetail fetch returned nil or an asset without a
            // thumbhash (server was still processing), schedule a retry after 4 seconds
            // so the thumbnail appears without waiting for the next background sync.
            if uploadedAsset.thumbhash == nil {
                let retryId = finalAssetId
                let client = apiClient
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(4))
                    guard let refreshed = try? await client.getAssetDetail(id: retryId),
                          refreshed.thumbhash != nil else { return }
                    NotificationCenter.default.post(
                        name: .assetsDidChange,
                        object: nil,
                        userInfo: ["uploadedAsset": refreshed]
                    )
                }
            }
        } catch {
            let currentRetry = items.first(where: { $0.id == item.id })?.retryCount ?? 0
            let canRetry = item.isPersisted
                && RetryPolicy.isRetryable(error)
                && currentRetry < RetryPolicy.maxAttempts

            if canRetry {
                let delay = RetryPolicy.delay(for: currentRetry)
                let attempt = currentRetry + 1
                AppLogger.upload.warning("Upload '\(item.fileName)' failed (attempt \(attempt)/\(RetryPolicy.maxAttempts)): \(error.localizedDescription) — retrying in \(Int(delay))s")

                if let idx = items.firstIndex(where: { $0.id == item.id }) {
                    items[idx].retryCount = attempt
                    items[idx].state = .retrying(attempt: attempt, after: delay)
                    updatePersistedRetryCount(for: items[idx])
                }
                let itemId = item.id
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(delay))
                    if let idx = self.items.firstIndex(where: { $0.id == itemId }),
                       case .retrying = self.items[idx].state {
                        self.items[idx].state = .pending
                        self.processQueue()
                    }
                }
            } else {
                AppLogger.upload.error("Upload '\(item.fileName)' permanently failed: \(error.localizedDescription)")
                if let idx = items.firstIndex(where: { $0.id == item.id }) {
                    items[idx].state = .failed(error.localizedDescription)
                    // Keep in SwiftData so the user can inspect / retry manually
                    updatePersistedRetryCount(for: items[idx])
                }
                completionHandlers.removeValue(forKey: item.id)?(.failure(error))
            }
        }

        processQueue()
        writeSessionLogIfComplete(sessionId: item.sessionId)
    }

    /// Album-Zuordnungen, die nach geglücktem Upload fehlschlugen — je Item.
    ///
    /// Getrennt vom `state` des Items gehalten: Der Upload ist gelungen, das Item
    /// bleibt `.complete`. Nur der Sitzungs-Log nennt den Rest.
    private var albumAssignmentFailures: [UUID: String] = [:]

    /// Write a SyncLogEntry for a session once all its items have finished.
    private func writeSessionLogIfComplete(sessionId: UUID) {
        let sessionItems = items.filter { $0.sessionId == sessionId }
        // Über `isFinished`, nicht über ein eigenes `switch`: Das trug hier ein
        // `default:` und hätte einen neuen Zustand still als „nicht fertig" behandelt —
        // der Sitzungs-Log wäre dann für die ganze Sitzung nie geschrieben worden.
        let allDone = sessionItems.allSatisfy(Self.isFinished)
        guard allDone, !sessionItems.isEmpty else { return }

        let label = sessions.first(where: { $0.id == sessionId })?.label ?? "Upload"
        let uploadedCount  = sessionItems.filter { if case .complete       = $0.state { return true }; return false }.count
        let duplicateCount = sessionItems.filter { if case .duplicate      = $0.state { return true }; return false }.count
        let failedCount    = sessionItems.filter { if case .failed         = $0.state { return true }; return false }.count
        let mismatchCount  = sessionItems.filter { if case .checksumMismatch = $0.state { return true }; return false }.count

        let errorMessages = sessionItems.compactMap { item -> String? in
            if case .failed(let msg) = item.state { return "\(item.fileName): \(msg)" }
            if case .checksumMismatch(_, let l, let s) = item.state {
                return "\(item.fileName): checksum mismatch (local \(l.prefix(8))… ≠ server \(s.prefix(8))…)"
            }
            // Hochgeladen, aber nicht ins gewünschte Album übernommen.
            if let hinweis = albumAssignmentFailures[item.id] { return "\(item.fileName): \(hinweis)" }
            return nil
        }
        for item in sessionItems { albumAssignmentFailures.removeValue(forKey: item.id) }

        let entry = SyncLogEntry(
            kind: .upload,
            trigger: label,
            transport: .none,
            changedCount: uploadedCount + duplicateCount,
            uploadedCount: uploadedCount,
            duplicateCount: duplicateCount,
            failedCount: failedCount,
            checksumMismatchCount: mismatchCount,
            errorMessage: errorMessages.isEmpty ? nil : errorMessages.joined(separator: "\n")
        )
        SyncLogStore.shared.append(entry)
    }

    // MARK: - Checksum Validation Helpers

    /// Returns true for ~10 % of non-duplicate uploads (deterministic via arc4random).
    private func shouldValidateChecksum() -> Bool {
        Double(arc4random()) / Double(UInt32.max) < checksumSampleRate
    }

    /// Fetch the server-side checksum (base64) via GET /api/assets/:id.
    private func fetchServerChecksum(assetId: String) async throws -> String? {
        let asset = try await apiClient.getAssetDetail(id: assetId)
        return asset.checksum
    }

    /// Convert a base64-encoded SHA-1 (Immich API format) to lowercase hex.
    private func base64ToHex(_ base64: String) -> String {
        ChecksumHex.fromBase64(base64) ?? ""
    }

    // MARK: - Persistence Helpers

    private func persistItems(_ items: [UploadItem], session: UploadSession) {
        guard let ctx = modelContext else { return }
        for item in items where item.isPersisted {
            let entry = UploadQueueEntry(
                entryId: item.id,
                fileURL: item.fileURL,
                fileName: item.fileName,
                albumId: item.albumId,
                sessionId: session.id,
                sessionLabel: session.label,
                retryCount: item.retryCount
            )
            ctx.insert(entry)
        }
        try? ctx.save()
    }

    private func removePersistedItem(id: UUID) {
        guard let ctx = modelContext else { return }
        let idStr = id.uuidString
        let descriptor = FetchDescriptor<UploadQueueEntry>(
            predicate: #Predicate { $0.entryId == idStr }
        )
        if let entry = try? ctx.fetch(descriptor).first {
            ctx.delete(entry)
            try? ctx.save()
        }
    }

    private func removePersistedItems(_ items: [UploadItem]) {
        guard let ctx = modelContext, !items.isEmpty else { return }
        let ids = Set(items.map(\.id.uuidString))
        let descriptor = FetchDescriptor<UploadQueueEntry>()
        let entries = (try? ctx.fetch(descriptor)) ?? []
        for entry in entries where ids.contains(entry.entryId) {
            ctx.delete(entry)
        }
        try? ctx.save()
    }

    private func updatePersistedRetryCount(for item: UploadItem) {
        guard let ctx = modelContext, item.isPersisted else { return }
        let idStr = item.id.uuidString
        let descriptor = FetchDescriptor<UploadQueueEntry>(
            predicate: #Predicate { $0.entryId == idStr }
        )
        if let entry = try? ctx.fetch(descriptor).first {
            entry.retryCount = item.retryCount
            try? ctx.save()
        }
    }

    private func pruneEmptySessions() {
        let activeSessions = Set(items.map(\.sessionId))
        sessions.removeAll { !activeSessions.contains($0.id) }
    }

    // MARK: - Upload Logic

    private func performUpload(_ item: UploadItem) async throws -> UploadResult {
        let url = apiClient.baseURL.appending(path: "api/assets")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiClient.apiKey, forHTTPHeaderField: "x-api-key")

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let mimeType = mimeTypeFor(item.fileURL)

        // EXIF Extraction ensures files are sorted deeply into the right timeline spot instead of "now"
        let formatter = ISO8601DateFormatter()
        let fileAttrs = try? FileManager.default.attributesOfItem(atPath: item.fileURL.path)
        let exactCreationDate = await EXIFExtractor.extractCreationDate(from: item.fileURL)
        let createdAt = exactCreationDate ?? fileAttrs?[.creationDate] as? Date ?? Date()
        let modifiedAt = fileAttrs?[.modificationDate] as? Date ?? Date()

        // Write multipart body to a temp file (avoids loading entire video into memory)
        let tempURL = FileManager.default.temporaryDirectory
            .appending(path: "upload-\(UUID().uuidString).multipart")

        let outputStream = OutputStream(url: tempURL, append: false)!
        outputStream.open()
        defer {
            outputStream.close()
            try? FileManager.default.removeItem(at: tempURL)
        }

        func writeString(_ s: String) {
            let data = s.data(using: .utf8)!
            _ = data.withUnsafeBytes { outputStream.write($0.baseAddress!.assumingMemoryBound(to: UInt8.self), maxLength: data.count) }
        }

        // Multipart fields
        writeString("--\(boundary)\r\nContent-Disposition: form-data; name=\"deviceAssetId\"\r\n\r\n\(item.fileName)\r\n")
        writeString("--\(boundary)\r\nContent-Disposition: form-data; name=\"deviceId\"\r\n\r\nImmichMac\r\n")
        writeString("--\(boundary)\r\nContent-Disposition: form-data; name=\"fileCreatedAt\"\r\n\r\n\(formatter.string(from: createdAt))\r\n")
        writeString("--\(boundary)\r\nContent-Disposition: form-data; name=\"fileModifiedAt\"\r\n\r\n\(formatter.string(from: modifiedAt))\r\n")

        // Live Photo pairing: link this image to its video counterpart in Immich
        if let liveVideoId = item.livePhotoVideoId {
            writeString("--\(boundary)\r\nContent-Disposition: form-data; name=\"livePhotoVideoId\"\r\n\r\n\(liveVideoId)\r\n")
        }

        // File data header
        writeString("--\(boundary)\r\nContent-Disposition: form-data; name=\"assetData\"; filename=\"\(item.fileName)\"\r\nContent-Type: \(mimeType)\r\n\r\n")

        // Stream file data in 256KB chunks (never loads entire file into memory)
        let inputStream = InputStream(url: item.fileURL)!
        inputStream.open()
        defer { inputStream.close() }

        let bufferSize = 256 * 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while inputStream.hasBytesAvailable {
            let read = inputStream.read(&buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            outputStream.write(buffer, maxLength: read)
        }

        // Close boundary
        writeString("\r\n--\(boundary)--\r\n")
        outputStream.close()

        // Upload from temp file (streamed, no memory spike)
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: tempURL, delegate: SichereWeiterleitung.shared)
        guard let http = response as? HTTPURLResponse, (200...201).contains(http.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw APIError.httpError(statusCode)
        }

        let result = try JSONDecoder().decode(UploadResponse.self, from: data)
        let statusValue = result.status?.lowercased() ?? ""
        let isDuplicate = statusValue.contains("duplicate") || statusValue.contains("exists")
        return UploadResult(id: result.id, isDuplicate: isDuplicate)
    }

    private func mimeTypeFor(_ url: URL) -> String {
        MIMEType.mimeType(for: url)
    }
    
    // MARK: - Hashing Helper
    
    /// SHA-1 über den gesamten Dateiinhalt, gepuffert statt am Stück im Speicher.
    ///
    /// `static` und nicht mehr `private`, damit der Aufruf in einen
    /// `Task.detached` wandern kann, ohne `self` einzufangen — und damit die
    /// Pufferschleife testbar wird. **Nie direkt aus `@MainActor`-Kontext
    /// aufrufen:** Die Funktion ist synchron und liest die ganze Datei; auf dem
    /// Hauptthread friert dabei die Oberfläche ein.
    nonisolated static func computeSHA1(url: URL) -> String? {
        guard let inputStream = InputStream(url: url) else { return nil }
        inputStream.open()
        defer { inputStream.close() }

        // `InputStream(url:)` prüft nicht, ob die Datei existiert, und `open()`
        // meldet den Fehlschlag ausschließlich über den Status. Ohne diese Prüfung
        // lief die Schleife null Mal durch und die Funktion lieferte den SHA-1 der
        // *leeren* Datei — einen gültig aussehenden, falschen Wert. Der `guard let
        // hash`-Wächter im Upload greift dann nicht, und der Vorab-Abgleich fragt
        // den Server nach dem Leer-Hash: Existiert dort irgendein 0-Byte-Asset,
        // gilt der Upload als dessen Dublette und ein fremdes Asset landet im Album.
        guard inputStream.streamStatus != .error, inputStream.streamError == nil else {
            return nil
        }

        var hasher = Insecure.SHA1()
        let bufferSize = 256 * 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)

        while inputStream.hasBytesAvailable {
            let readBytes = inputStream.read(&buffer, maxLength: bufferSize)
            // −1 heißt Lesefehler, 0 heißt Dateiende. Beides gemeinsam abzubrechen
            // gab den Hash des bis dahin Gelesenen als den der ganzen Datei aus —
            // bei einem Fehler mitten in einer großen Datei also den Hash eines
            // Bruchstücks.
            if readBytes < 0 { return nil }
            if readBytes == 0 { break }
            hasher.update(data: buffer[0..<readBytes])
        }
        
        let hash = hasher.finalize()
        return hash.compactMap { String(format: "%02x", $0) }.joined()
    }
}

private struct UploadResult {
    let id: String
    let isDuplicate: Bool
}

// MARK: - EXIF Extraction Helper

/// Extracts the original capture date from media files (EXIF for images, Metadata for videos).
private final class EXIFExtractor {
    
    /// Extracts the true creation date from a file URL.
    static func extractCreationDate(from url: URL) async -> Date? {
        let ext = url.pathExtension.lowercased()
        let videoExtensions: Set<String> = ["mp4", "mov", "avi", "mkv", "webm", "m4v", "mxf"]
        
        if videoExtensions.contains(ext) {
            return await extractVideoCreationDate(from: url)
        } else {
            return extractImageCreationDate(from: url)
        }
    }
    
    // MARK: - Image Extraction
    
    private static func extractImageCreationDate(from url: URL) -> Date? {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] else {
            return nil
        }
        
        // 1. Try standard EXIF DateTimeOriginal
        if let exifDict = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let dateString = exifDict[kCGImagePropertyExifDateTimeOriginal] as? String {
            if let date = parseExifDate(dateString) { return date }
        }
        
        // 2. Try EXIF DateTimeDigitized
        if let exifDict = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let dateString = exifDict[kCGImagePropertyExifDateTimeDigitized] as? String {
            if let date = parseExifDate(dateString) { return date }
        }
        
        // 3. Try TIFF DateTime
        if let tiffDict = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
           let dateString = tiffDict[kCGImagePropertyTIFFDateTime] as? String {
            if let date = parseExifDate(dateString) { return date }
        }
        
        return nil
    }
    
    private static func parseExifDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // EXIF dates format: "yyyy:MM:dd HH:mm:ss"
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        
        if let date = formatter.date(from: string) { return date }
        
        // Try fallback ISO-ish format just in case
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: string)
    }
    
    // MARK: - Video Extraction
    
    private static func extractVideoCreationDate(from url: URL) async -> Date? {
        let asset = AVURLAsset(url: url)
        if let creationDate = try? await asset.load(.creationDate),
           let date = try? await creationDate.load(.dateValue) {
            return date
        }
        
        // Fallback: Check metadata directly
        guard let metadata = try? await asset.load(.metadata) else { return nil }
        for item in metadata {
            if let key = item.commonKey, key == .commonKeyCreationDate {
                if let stringValue = try? await item.load(.stringValue),
                   let date = ISO8601DateFormatter().date(from: stringValue) {
                    return date
                }
                if let dateValue = try? await item.load(.dateValue) {
                    return dateValue
                }
            }
        }
        return nil
    }
}

enum ApplePhotosSyncError: LocalizedError {
    case authorizationDenied
    case exportFailed(String)
    case uploadFailed(String)

    var errorDescription: String? {
        switch self {
        case .authorizationDenied:
            return "Apple Photos access is denied."
        case .exportFailed(let reason):
            return "Failed to export from Photos: \(reason)"
        case .uploadFailed(let reason):
            return "Failed to upload exported file: \(reason)"
        }
    }
}

enum ApplePhotosSyncPreviewStatus: String, Sendable {
    case new
    case retry
}

struct ApplePhotosSyncPreviewItem: Identifiable, Hashable, Sendable {
    var id: String { localIdentifier }

    let localIdentifier: String
    let originalFilename: String
    let creationDate: Date?
    let modificationDate: Date?
    let mediaType: PHAssetMediaType
    let isLivePhoto: Bool
    let duration: TimeInterval
    let status: ApplePhotosSyncPreviewStatus
    let lastError: String?
}

struct ApplePhotosSyncPlan: Sendable {
    let items: [ApplePhotosSyncPreviewItem]
    let retryCount: Int
    let skippedByMappingCount: Int
    let alreadyPresentCount: Int
    let windowAssetCount: Int
    let scannedCount: Int
    let usedSinceLastSync: Bool
    let recentDays: Int?
    /// Gesetzt wenn der erste Lauf (kein lastSuccessfulSyncAt) auf ein
    /// begrenztes Fenster statt eines Voll-Scans der Mediathek fiel.
    let firstRunWindowDays: Int?
    let lastSuccessfulSyncAt: Date?
    /// Gesamtzahl dauerhaft ignorierter Assets (nicht nur im aktuellen Fenster) —
    /// der Dialog braucht sie, um das Ignorieren rücknehmbar zu machen.
    let ignoredCount: Int
}

/// Ein ignoriertes Asset in der Form, die die UI zum Anzeigen und Zurücknehmen braucht.
struct ApplePhotosIgnoredEntry: Identifiable, Hashable, Sendable {
    var id: String { localIdentifier }

    let localIdentifier: String
    let originalFilename: String
    let creationDate: Date?
    let ignoredAt: Date
    let reason: ApplePhotosIgnoreReason
}

/// Entscheidet, was mit einem Apple-Photos-Asset angesichts seines Mapping-Zustands passiert.
/// `PHAsset.modificationDate` ist verrauscht (Favorit, Album-Zuordnung, Bildanalyse bumpen es
/// ohne Pixel-Änderung) — ein neueres Datum allein rechtfertigt keinen Re-Upload.
enum ApplePhotosReuploadDecision: Equatable, Sendable {
    /// Kein Mapping bzw. echter neuer Edit — hochladen.
    case upload
    /// Mapping ist aktuell — nichts zu tun.
    case skip
    /// modificationDate wurde ohne Inhaltsänderung gebumpt — nur den
    /// gespeicherten Zeitstempel (und ggf. die Dateigröße) fortschreiben.
    case reseed

    static func decide(
        hasMapping: Bool,
        lastKnownModificationDate: Date?,
        assetModificationDate: Date,
        hasEditedResource: Bool,
        lastUploadedFileSize: Int64?,
        currentFileSize: Int64?
    ) -> ApplePhotosReuploadDecision {
        guard hasMapping else { return .upload }
        // Legacy-Mapping ohne Zeitstempel: einmal seeden statt re-uploaden.
        guard let known = lastKnownModificationDate else { return .reseed }
        guard assetModificationDate > known else { return .skip }
        // Kein Edit-Artefakt vorhanden → reiner Metadaten-Bump.
        guard hasEditedResource else { return .reseed }
        // Edit vorhanden, aber Dateigröße unverändert → dieser Edit wurde bereits hochgeladen.
        if let stored = lastUploadedFileSize, let current = currentFileSize, stored == current { return .reseed }
        return .upload
    }
}

/// Manual sync of Apple Photos assets into Immich uploads.
@MainActor
final class ApplePhotosSyncManager {
    private let modelContext: ModelContext
    private let uploadManager: UploadManager
    private let apiClient: ImmichAPIClient
    /// Small overlap between incremental runs so we do not miss assets around
    /// the previous sync boundary because of timestamp jitter or slow writes.
    private let deltaSafetyBuffer: TimeInterval = 10 * 60
    private let maxPerAssetAttempts = 3
    private let perAssetRetryDelays: [TimeInterval] = [5, 30, 120]

    private struct ApplePhotoCandidate {
        let asset: PHAsset
        let localIdentifier: String
        let originalFilename: String
        let modificationDate: Date?
        let creationDate: Date?
        let isRetry: Bool
        let lastError: String?
        let hasMapping: Bool
        let resourceFileSize: Int64?
    }

    /// Metadaten-Bump ohne Inhaltsänderung: Mapping-Zeitstempel wird nur fortgeschrieben.
    private struct ReseedInfo: Sendable {
        let localIdentifier: String
        let modificationDate: Date
        let fileSize: Int64?
    }

    private enum ApplePhotoProcessResult {
        case skippedMappingSeeded
        case alreadyPresent
        case uploaded
        case failed(String)
    }

    init(modelContext: ModelContext, uploadManager: UploadManager, apiClient: ImmichAPIClient) {
        self.modelContext = modelContext
        self.uploadManager = uploadManager
        self.apiClient = apiClient
        recoverStaleRunningStateIfNeeded()
    }

    /// - Parameters:
    ///   - callerFile/callerLine: füllen sich automatisch mit der Aufrufstelle und
    ///     landen im Log. Die Sync-Trigger sind im Unified Log `<private>`, und ein
    ///     Scan der Mediathek lief schon einmal ohne auffindbaren Auslöser — ohne
    ///     diese Herkunft ist so etwas nachträglich nicht mehr zuzuordnen.
    func syncNow(
        forceFullSync: Bool = false,
        recentDays: Int? = nil,
        callerFile: String = #fileID,
        callerLine: Int = #line
    ) async {
        // Ein Tages-Fenster deckt nicht zwingend alles seit dem letzten Sync ab —
        // die Baseline darf dann nicht fortgeschrieben werden, sonst gehen Fotos verloren.
        await runSync(
            forceFullSync: forceFullSync,
            recentDays: recentDays,
            selectedLocalIdentifiers: nil,
            advanceBaseline: recentDays == nil,
            origin: "\(callerFile):\(callerLine)"
        )
    }

    /// - Parameter advanceBaseline: nur `true` wenn die zugrundeliegende Vorschau
    ///   den kompletten Zeitraum seit dem letzten Sync abdeckte ("Seit letztem Sync").
    @discardableResult
    func syncSelected(
        localIdentifiers: Set<String>,
        advanceBaseline: Bool = false,
        verwerfen: [ApplePhotoVerwerfKandidat] = [],
        callerFile: String = #fileID,
        callerLine: Int = #line
    ) async -> ApplePhotoDeletionOutcome? {
        guard !localIdentifiers.isEmpty else { return nil }
        return await runSync(
            forceFullSync: false,
            recentDays: nil,
            selectedLocalIdentifiers: localIdentifiers,
            advanceBaseline: advanceBaseline,
            verwerfen: verwerfen,
            origin: "\(callerFile):\(callerLine)"
        )
    }

    func previewSync(
        recentDays: Int? = nil,
        sinceLastSync: Bool = true,
        callerFile: String = #fileID,
        callerLine: Int = #line
    ) async throws -> ApplePhotosSyncPlan {
        // Eine Vorschau scannt das komplette Fenster der Mediathek — teuer genug,
        // um im Log zu sehen, wer sie angefordert hat.
        AppLogger.upload.info("AppleSync: Vorschau angefordert aus \(callerFile):\(callerLine) (recentDays=\(recentDays.map(String.init) ?? "—"), sinceLastSync=\(sinceLastSync))")
        let authorized = await ensurePhotoAuthorization()
        guard authorized else { throw ApplePhotosSyncError.authorizationDenied }

        let state = fetchOrCreateState()
        // Erster Lauf: kein Voll-Scan der Mediathek in der Vorschau — der friert die UI
        // bei großen Bibliotheken ein. Stattdessen begrenztes Fenster; das komplette
        // Erst-Backup läuft über "Vollständig syncen".
        let firstRunWindowDays: Int? =
            (sinceLastSync && recentDays == nil && state.lastSuccessfulSyncAt == nil)
            ? Self.firstRunWindowDays : nil
        let (candidateLoadResult, _) = await loadCandidates(
            forceFullSync: false,
            lastSuccessfulSyncAt: sinceLastSync ? state.lastSuccessfulSyncAt : nil,
            recentDays: recentDays ?? firstRunWindowDays
        )
        let retryCandidates = loadFailureCandidates(now: Date(), onlyDue: false, deleteMissing: false)

        return await buildPlan(
            candidateLoadResult: candidateLoadResult,
            retryCandidates: retryCandidates,
            usedSinceLastSync: sinceLastSync && recentDays == nil,
            recentDays: recentDays,
            firstRunWindowDays: firstRunWindowDays
        )
    }

    /// Vorschau für eine explizit vorgegebene Menge an `localIdentifier`s statt eines
    /// Datumsfensters — z.B. für Apples eigenes "Zuletzt importiert"-Smart-Album, das
    /// nach Import-/Hinzufügedatum filtert statt nach `creationDate`/EXIF.
    func previewSync(
        localIdentifiers: Set<String>,
        callerFile: String = #fileID,
        callerLine: Int = #line
    ) async throws -> ApplePhotosSyncPlan {
        AppLogger.upload.info("AppleSync: Vorschau (feste Auswahl) angefordert aus \(callerFile):\(callerLine), \(localIdentifiers.count) Kandidat(en)")
        let authorized = await ensurePhotoAuthorization()
        guard authorized else { throw ApplePhotosSyncError.authorizationDenied }

        // Bewusst NICHT `loadCandidates(localIdentifiers:)`: das ist der Pfad für die
        // explizite Nutzerauswahl und überspringt absichtlich nichts, damit ein
        // handverlesenes Foto auch dann hochgeladen wird, wenn es schon gemappt ist.
        // Als Browsing-Filter gebraucht, blieben gerade gesicherte Fotos dadurch für
        // immer in der Liste stehen.
        let (candidateLoadResult, _) = await loadCandidates(
            forceFullSync: false,
            lastSuccessfulSyncAt: nil,
            recentDays: nil,
            restrictToLocalIdentifiers: localIdentifiers
        )
        let retryCandidates = loadFailureCandidates(now: Date(), onlyDue: false, deleteMissing: false)
            .filter { localIdentifiers.contains($0.localIdentifier) }

        return await buildPlan(
            candidateLoadResult: candidateLoadResult,
            retryCandidates: retryCandidates,
            usedSinceLastSync: false,
            recentDays: nil,
            firstRunWindowDays: nil
        )
    }

    /// Gemeinsame Tail-Logik beider `previewSync`-Varianten: Retry- und Fenster-Kandidaten
    /// zu einem `ApplePhotosSyncPlan` zusammenführen, dabei bereits serverseitig vorhandene
    /// (aber ungemappte) Assets über den lokalen Dateiname/Datum-Index herausfiltern.
    private func buildPlan(
        candidateLoadResult: CandidateLoadResult,
        retryCandidates: [ApplePhotoCandidate],
        usedSinceLastSync: Bool,
        recentDays: Int?,
        firstRunWindowDays: Int?
    ) async -> ApplePhotosSyncPlan {
        let retryIds = Set(retryCandidates.map(\.localIdentifier))
        // Der Index (Voll-Fetch aller CachedAssets) wird nur gebraucht, wenn es
        // ungemappte Kandidaten gibt — Retries und gemappte Edits umgehen den Filter.
        let localIndex = candidateLoadResult.candidates.contains(where: { !$0.hasMapping })
            ? await buildLocalFilenameIndex() : [:]

        var alreadyPresentCount = 0
        var items: [ApplePhotosSyncPreviewItem] = []
        var seenIds = Set<String>()

        for candidate in retryCandidates + candidateLoadResult.candidates {
            guard seenIds.insert(candidate.localIdentifier).inserted else { continue }
            // Gemappte Kandidaten sind echte Edits — die dürfen nicht als
            // "bereits vorhanden" wegfallen, nur ungemappte Neuzugänge.
            if candidate.isRetry == false,
               !candidate.hasMapping,
               let createdAt = candidate.creationDate,
               findInLocalIndex(localIndex, filename: candidate.originalFilename, localIdentifier: candidate.localIdentifier, createdAt: createdAt) != nil {
                alreadyPresentCount += 1
                continue
            }

            items.append(
                ApplePhotosSyncPreviewItem(
                    localIdentifier: candidate.localIdentifier,
                    originalFilename: candidate.originalFilename,
                    creationDate: candidate.creationDate,
                    modificationDate: candidate.modificationDate,
                    mediaType: candidate.asset.mediaType,
                    isLivePhoto: candidate.asset.mediaSubtypes.contains(.photoLive),
                    duration: candidate.asset.duration,
                    status: retryIds.contains(candidate.localIdentifier) ? .retry : .new,
                    lastError: candidate.lastError
                )
            )
        }

        let state = fetchOrCreateState()
        return ApplePhotosSyncPlan(
            items: items,
            retryCount: retryCandidates.count,
            skippedByMappingCount: candidateLoadResult.skippedByMappingCount,
            alreadyPresentCount: alreadyPresentCount,
            windowAssetCount: candidateLoadResult.totalWindowAssets,
            scannedCount: candidateLoadResult.candidates.count,
            usedSinceLastSync: usedSinceLastSync,
            recentDays: recentDays,
            firstRunWindowDays: firstRunWindowDays,
            lastSuccessfulSyncAt: state.lastSuccessfulSyncAt,
            ignoredCount: ignoredAssetCount()
        )
    }

    // MARK: - Ignorier-Liste

    /// IDs, die dauerhaft nicht mehr vorgeschlagen werden.
    private func loadIgnoredIdentifiers() -> Set<String> {
        let ignored = (try? modelContext.fetch(FetchDescriptor<ApplePhotosIgnoredAsset>())) ?? []
        return Set(ignored.map(\.localIdentifier))
    }

    func ignoredAssetCount() -> Int {
        (try? modelContext.fetchCount(FetchDescriptor<ApplePhotosIgnoredAsset>())) ?? 0
    }

    /// Ignorierte Assets, neueste zuerst — für die Verwaltungsansicht im Dialog.
    ///
    /// Bewusst ohne `FetchDescriptor(sortBy:)`: Der sortierte Fetch lieferte in der
    /// laufenden App eine leere Liste, während `fetchCount` auf demselben Context
    /// korrekt zählte und die Zeile nachweislich im Store lag. Ein unsortierter
    /// Fetch plus Sortierung in Swift ist bei dieser Listengröße ohnehin gratis.
    func ignoredAssets() -> [ApplePhotosIgnoredEntry] {
        let ignored: [ApplePhotosIgnoredAsset]
        do {
            ignored = try modelContext.fetch(FetchDescriptor<ApplePhotosIgnoredAsset>())
        } catch {
            // Nicht schlucken: eine leere Liste sieht sonst aus wie "nichts ignoriert",
            // obwohl die Einträge existieren.
            AppLogger.upload.error("AppleSync: Laden der Ignorier-Liste fehlgeschlagen: \(error)")
            return []
        }
        return ignored.sorted { $0.ignoredAt > $1.ignoredAt }.map {
            ApplePhotosIgnoredEntry(
                localIdentifier: $0.localIdentifier,
                originalFilename: $0.originalFilename,
                creationDate: $0.creationDate,
                ignoredAt: $0.ignoredAt,
                reason: $0.reason
            )
        }
    }

    /// Markiert Assets als dauerhaft ignoriert. Ein vorhandener Retry-Eintrag wird
    /// mit entfernt, sonst käme das Asset über den Retry-Pfad zurück.
    func ignore(_ items: [ApplePhotosSyncPreviewItem], reason: ApplePhotosIgnoreReason) {
        guard !items.isEmpty else { return }
        let existing = loadIgnoredIdentifiers()
        var inserted = 0
        for item in items where !existing.contains(item.localIdentifier) {
            modelContext.insert(
                ApplePhotosIgnoredAsset(
                    localIdentifier: item.localIdentifier,
                    originalFilename: item.originalFilename,
                    creationDate: item.creationDate,
                    reason: reason
                )
            )
            removeFailure(localIdentifier: item.localIdentifier)
            inserted += 1
        }
        guard inserted > 0 else { return }
        saveState()
        AppLogger.upload.info("AppleSync: \(inserted) Asset(s) als ignoriert markiert (\(reason.rawValue))")
    }

    /// Nimmt das Ignorieren zurück — die Assets tauchen beim nächsten Scan wieder auf.
    func unignore(localIdentifiers: Set<String>) {
        guard !localIdentifiers.isEmpty else { return }
        let ignored = (try? modelContext.fetch(FetchDescriptor<ApplePhotosIgnoredAsset>())) ?? []
        var removed = 0
        for entry in ignored where localIdentifiers.contains(entry.localIdentifier) {
            modelContext.delete(entry)
            removed += 1
        }
        guard removed > 0 else { return }
        saveState()
        AppLogger.upload.info("AppleSync: \(removed) Asset(s) wieder freigegeben")
    }

    func clearAllIgnored() {
        let ignored = (try? modelContext.fetch(FetchDescriptor<ApplePhotosIgnoredAsset>())) ?? []
        guard !ignored.isEmpty else { return }
        for entry in ignored {
            modelContext.delete(entry)
        }
        saveState()
        AppLogger.upload.info("AppleSync: alle \(ignored.count) ignorierten Assets wieder freigegeben")
    }

    /// Fenster für den ersten Lauf und den Startup-Check, solange noch kein
    /// erfolgreicher Sync stattgefunden hat — verhindert Voll-Scans der Mediathek.
    static let firstRunWindowDays = 30

    /// Ob gerade ein Apple-Fotos-Lauf läuft. Während eines Laufs liefert
    /// `startupPendingIdentifiers()` bewusst `nil` — wer zählt, muss das unterscheiden.
    var isSyncRunning: Bool { fetchOrCreateState().isRunning }

    /// Leichtgewichtiger Check beim App-Start: zählt neue/geänderte Fotos seit dem
    /// letzten erfolgreichen Sync (Fallback: `firstRunWindowDays`), lädt nichts hoch.
    /// Bei noch unbestimmter Berechtigung wird sie einmal angefordert (Debug-Builds
    /// verlieren TCC-Grants nach Rebuilds — stilles Aufgeben ließe das Feature
    /// dauerhaft tot wirken); bei verweigerter Berechtigung passiert nichts.
    /// Nutzt exakt dieselbe Pipeline wie das Preview-Sheet, damit die im Prompt
    /// genannte Anzahl mit der anschließend angezeigten Vorschau übereinstimmt.
    /// Liefert die `localIdentifier` der Kandidaten; ob gefragt wird, entscheidet der
    /// Aufrufer mit `ApplePhotosStartupPromptMemory`.
    ///
    /// `nil` heißt „nicht zählbar" (Berechtigung fehlt/verweigert, Sync läuft bereits,
    /// oder die Vorschau ist fehlgeschlagen) — zu unterscheiden von einem echten Zählwert
    /// `0` ohne ausstehende Fotos. Ein Aufrufer, der `nil` wie `[]` behandelt, würde beim
    /// nächsten „zählbaren" Lauf jedes zuvor schon gemeldete Foto erneut melden, weil er
    /// das Gedächtnis mit einem falschen Nullstand überschreibt.
    func startupPendingIdentifiers() async -> Set<String>? {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .denied, .restricted:
            AppLogger.upload.info("AppleSync Startup-Check: Photos-Berechtigung verweigert — kein Prompt")
            return nil
        case .notDetermined:
            AppLogger.upload.info("AppleSync Startup-Check: Photos-Berechtigung unbestimmt — fordere an")
            guard await ensurePhotoAuthorization() else {
                AppLogger.upload.info("AppleSync Startup-Check: Berechtigung nicht erteilt — kein Prompt")
                return nil
            }
        default:
            break
        }

        let state = fetchOrCreateState()
        guard !state.isRunning else {
            AppLogger.upload.info("AppleSync Startup-Check: Sync läuft bereits — übersprungen")
            return nil
        }

        do {
            let plan = try await previewSync()
            AppLogger.upload.info("AppleSync Startup-Check: \(plan.items.count) neue/geänderte Fotos gefunden (Fenster: \(plan.firstRunWindowDays.map { "\($0) Tage (erster Lauf)" } ?? "seit letztem Sync"))")
            return Set(plan.items.map(\.localIdentifier))
        } catch {
            AppLogger.upload.warning("AppleSync Startup-Check fehlgeschlagen: \(error.localizedDescription)")
            return nil
        }
    }

    @discardableResult
    private func runSync(
        forceFullSync: Bool,
        recentDays: Int?,
        selectedLocalIdentifiers: Set<String>?,
        advanceBaseline: Bool,
        verwerfen: [ApplePhotoVerwerfKandidat] = [],
        origin: String
    ) async -> ApplePhotoDeletionOutcome? {
        let state = fetchOrCreateState()
        guard !state.isRunning else {
            AppLogger.upload.info("AppleSync: Lauf aus \(origin) übersprungen — Sync läuft bereits")
            return nil
        }

        AppLogger.upload.info("AppleSync: Lauf gestartet aus \(origin) (forceFullSync=\(forceFullSync), recentDays=\(recentDays.map(String.init) ?? "—"), selected=\(selectedLocalIdentifiers?.count ?? 0))")

        state.isRunning = true
        state.lastAttemptAt = Date()
        state.lastError = nil
        saveState()
        notifyProgress(state)

        do {
            let authorized = await ensurePhotoAuthorization()
            guard authorized else { throw ApplePhotosSyncError.authorizationDenied }

            let candidateLoadResult: CandidateLoadResult
            let mappings: [String: ApplePhotosAssetMapping]
            if let selectedLocalIdentifiers {
                (candidateLoadResult, mappings) = await loadCandidates(localIdentifiers: selectedLocalIdentifiers)
            } else {
                (candidateLoadResult, mappings) = await loadCandidates(
                    forceFullSync: forceFullSync,
                    lastSuccessfulSyncAt: state.lastSuccessfulSyncAt,
                    recentDays: recentDays
                )
            }
            let candidates = selectedLocalIdentifiers.map { ids in
                candidateLoadResult.candidates.filter { ids.contains($0.localIdentifier) }
            } ?? candidateLoadResult.candidates
            state.lastRunWindowAssetCount = candidateLoadResult.totalWindowAssets
            state.lastRunScannedCount = candidates.count
            state.lastRunSkippedByMappingCount = candidateLoadResult.skippedByMappingCount
            state.lastRunAlreadyPresentCount = 0
            state.lastRunEnqueuedCount = 0
            state.lastRunRetriedCount = 0
            state.lastRunFailedCount = 0
            refreshPendingFailureCount(state)
            saveState()
            notifyProgress(state)

            let runDirectory = FileManager.default.temporaryDirectory
                .appending(path: "app-photos-sync")
                .appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: runDirectory) }

            let retryCandidates = selectedLocalIdentifiers.map { ids in
                loadFailureCandidates(now: Date(), onlyDue: false, deleteMissing: true)
                    .filter { ids.contains($0.localIdentifier) }
            } ?? loadFailureCandidates(now: Date(), onlyDue: true, deleteMissing: true)

            // Build a local filename→[assetId] index from the already-synced SwiftData cache.
            // This replaces the previous per-asset HTTP call to searchByOriginalFilename()
            // which was making up to 77k network requests and silently stalling the sync.
            // Nur nötig, wenn ungemappte Kandidaten dabei sind — der Fetch materialisiert
            // sonst umsonst die gesamte CachedAsset-Tabelle.
            let localIndex = (retryCandidates + candidates).contains(where: { !$0.hasMapping })
                ? await buildLocalFilenameIndex() : [:]
            state.lastRunRetriedCount = retryCandidates.count
            if !retryCandidates.isEmpty {
                AppLogger.upload.info("AppleSync: retrying \(retryCandidates.count) persisted failure(s) before normal candidates")
            }

            var processedLocalIdentifiers = Set<String>()
            var newlyMappedLocalIdentifiers = Set<String>()
            if !retryCandidates.isEmpty {
                try await withThrowingTaskGroup(of: (ApplePhotoCandidate, ApplePhotoProcessResult).self) { group in
                    var iterator = retryCandidates.makeIterator()
                    for _ in 0..<3 {
                        if let candidate = iterator.next() {
                            processedLocalIdentifiers.insert(candidate.localIdentifier)
                            group.addTask { @MainActor in
                                let result = await self.processCandidate(
                                    candidate,
                                    localIndex: localIndex,
                                    mappings: mappings,
                                    runDirectory: runDirectory
                                )
                                return (candidate, result)
                            }
                        }
                    }
                    while let (candidate, result) = try await group.next() {
                        if self.apply(result: result, for: candidate, to: state) {
                            newlyMappedLocalIdentifiers.insert(candidate.localIdentifier)
                        }
                        if let nextCandidate = iterator.next() {
                            processedLocalIdentifiers.insert(nextCandidate.localIdentifier)
                            group.addTask { @MainActor in
                                let result = await self.processCandidate(
                                    nextCandidate,
                                    localIndex: localIndex,
                                    mappings: mappings,
                                    runDirectory: runDirectory
                                )
                                return (nextCandidate, result)
                            }
                        }
                    }
                }
            }

            let remainingCandidates = candidates.filter { !processedLocalIdentifiers.contains($0.localIdentifier) }
            if !remainingCandidates.isEmpty {
                try await withThrowingTaskGroup(of: (ApplePhotoCandidate, ApplePhotoProcessResult).self) { group in
                    var iterator = remainingCandidates.makeIterator()
                    for _ in 0..<3 {
                        if let candidate = iterator.next() {
                            group.addTask { @MainActor in
                                let result = await self.processCandidate(
                                    candidate,
                                    localIndex: localIndex,
                                    mappings: mappings,
                                    runDirectory: runDirectory
                                )
                                return (candidate, result)
                            }
                        }
                    }
                    while let (candidate, result) = try await group.next() {
                        if self.apply(result: result, for: candidate, to: state) {
                            newlyMappedLocalIdentifiers.insert(candidate.localIdentifier)
                        }
                        if let nextCandidate = iterator.next() {
                            group.addTask { @MainActor in
                                let result = await self.processCandidate(
                                    nextCandidate,
                                    localIndex: localIndex,
                                    mappings: mappings,
                                    runDirectory: runDirectory
                                )
                                return (nextCandidate, result)
                            }
                        }
                    }
                }
            }

            if advanceBaseline {
                state.lastSuccessfulSyncAt = Date()
            }
            state.isRunning = false
            refreshPendingFailureCount(state)
            saveState()
            notifyProgress(state)

            // Nur hier, am Ende eines vollständig durchgelaufenen Laufs, wird
            // gelöscht — auch das Verwerfen abgewählter Fotos. Abbruch, Fehler oder
            // ein gar nicht gestarteter Lauf erreichen diese Zeile nie.
            return await ApplePhotoDeletionService(modelContext: modelContext, apiClient: apiClient)
                .considerDeletion(
                    newlyMappedLocalIdentifiers: newlyMappedLocalIdentifiers,
                    verwerfen: verwerfen
                )
        } catch {
            state.lastError = error.localizedDescription
            state.isRunning = false
            refreshPendingFailureCount(state)
            saveState()
            notifyProgress(state)
            return nil
        }
    }

    private func processCandidate(
        _ candidate: ApplePhotoCandidate,
        localIndex: [String: [(id: String, createdAt: String)]],
        mappings: [String: ApplePhotosAssetMapping],
        runDirectory: URL
    ) async -> ApplePhotoProcessResult {
        let existingMapping = mappings[candidate.localIdentifier]
        let hasExistingMapping = existingMapping != nil

        // Legacy mappings created before we tracked modification dates should
        // not be treated as edited assets immediately. Seed the timestamp once
        // and only re-upload on a future real modification.
        if let existingMapping, existingMapping.lastKnownModificationDate == nil {
            existingMapping.lastKnownModificationDate = candidate.modificationDate ?? candidate.creationDate
            existingMapping.lastUploadedFileSize = existingMapping.lastUploadedFileSize ?? candidate.resourceFileSize
            removeFailure(localIdentifier: candidate.localIdentifier)
            AppLogger.upload.debug("AppleSync: seeded missing modification date for existing mapping \(candidate.originalFilename)")
            return .skippedMappingSeeded
        }

        // Pre-check: look up by filename + date in local SwiftData cache (zero network cost).
        // Only use this for unmapped assets. If the asset already has a mapping and
        // became a candidate again, it means Apple Photos reports a newer modification,
        // so we intentionally upload the edited version as a new Immich asset.
        if let createdAt = candidate.creationDate,
           !hasExistingMapping,
           let existingId = findInLocalIndex(localIndex, filename: candidate.originalFilename, localIdentifier: candidate.localIdentifier, createdAt: createdAt) {
            AppLogger.upload.debug("AppleSync: local match for \(candidate.originalFilename) → \(existingId), skipping upload")
            upsertMapping(
                localIdentifier: candidate.localIdentifier,
                immichAssetId: existingId,
                modificationDate: candidate.modificationDate ?? candidate.creationDate,
                fileSize: candidate.resourceFileSize,
                existingMappings: mappings
            )
            removeFailure(localIdentifier: candidate.localIdentifier)
            return .alreadyPresent
        }

        for attempt in 0..<maxPerAssetAttempts {
            var exportedURL: URL?
            do {
                exportedURL = try await export(asset: candidate.asset, into: runDirectory)

                // Live Photo handling: upload paired video first, then link it.
                // If the video keeps failing, continue with an image-only upload and
                // log the paired-video failure separately.
                var livePhotoVideoId: String? = nil
                if let pairedVideoResource = livePhotoPairedVideoResource(for: candidate.asset) {
                    let liveVideoLocalIdentifier = candidate.localIdentifier + "/live-video"
                    if let existingLiveVideo = mappings[liveVideoLocalIdentifier]?.immichAssetId {
                        livePhotoVideoId = existingLiveVideo
                        AppLogger.upload.debug("AppleSync: reusing mapped Live Photo video for \(candidate.originalFilename) → \(existingLiveVideo)")
                    } else {
                        do {
                            let videoURL = try await exportResource(pairedVideoResource, asset: candidate.asset, into: runDirectory)
                            defer { try? FileManager.default.removeItem(at: videoURL) }
                            let videoAssetId = try await uploadApplePhoto(url: videoURL, localIdentifier: liveVideoLocalIdentifier)
                            livePhotoVideoId = videoAssetId
                            upsertMapping(
                                localIdentifier: liveVideoLocalIdentifier,
                                immichAssetId: videoAssetId,
                                modificationDate: candidate.modificationDate ?? candidate.creationDate,
                                fileSize: nil,
                                existingMappings: mappings
                            )
                            AppLogger.upload.info("AppleSync: uploaded Live Photo video for \(candidate.originalFilename) → \(videoAssetId)")
                        } catch {
                            AppLogger.upload.warning("AppleSync: Live Photo video upload failed for \(candidate.originalFilename): \(error.localizedDescription)")
                        }
                    }
                }

                guard let exportedURL else {
                    throw ApplePhotosSyncError.exportFailed("Missing exported file URL.")
                }
                let assetId = try await uploadApplePhoto(
                    url: exportedURL,
                    localIdentifier: candidate.localIdentifier,
                    livePhotoVideoId: livePhotoVideoId
                )
                try? FileManager.default.removeItem(at: exportedURL)
                upsertMapping(
                    localIdentifier: candidate.localIdentifier,
                    immichAssetId: assetId,
                    modificationDate: candidate.modificationDate ?? candidate.creationDate,
                    fileSize: candidate.resourceFileSize,
                    existingMappings: mappings
                )
                removeFailure(localIdentifier: candidate.localIdentifier)
                AppLogger.upload.info("AppleSync: uploaded \(candidate.originalFilename) → \(assetId)")
                return .uploaded
            } catch {
                if let exportedURL {
                    try? FileManager.default.removeItem(at: exportedURL)
                }

                if attempt < maxPerAssetAttempts - 1 {
                    let delay = perAssetRetryDelays[min(attempt, perAssetRetryDelays.count - 1)]
                    AppLogger.upload.warning("AppleSync: \(candidate.originalFilename) failed on attempt \(attempt + 1)/\(self.maxPerAssetAttempts): \(error.localizedDescription) — retrying in \(Int(delay))s")
                    try? await Task.sleep(for: .seconds(delay))
                    continue
                }

                let message = error.localizedDescription
                AppLogger.upload.warning("AppleSync: \(candidate.originalFilename) failed permanently for this run: \(message)")
                recordFailure(candidate: candidate, errorMessage: message)
                return .failed(message)
            }
        }

        let fallbackMessage = "Unknown Apple Photos sync failure."
        recordFailure(candidate: candidate, errorMessage: fallbackMessage)
        return .failed(fallbackMessage)
    }

    /// - Returns: `true`, wenn dieses Ergebnis bedeutet, dass `candidate.localIdentifier`
    ///   in diesem Lauf neu mit Immich verknüpft wurde (Kandidat für die automatische
    ///   Apple-Photos-Löschung) — `false` für reine Metadaten-Seeds oder Fehler.
    @discardableResult
    private func apply(result: ApplePhotoProcessResult, for candidate: ApplePhotoCandidate, to state: ApplePhotosSyncState) -> Bool {
        var isNewMapping = false
        switch result {
        case .skippedMappingSeeded:
            state.lastRunSkippedByMappingCount += 1
        case .alreadyPresent:
            state.lastRunAlreadyPresentCount += 1
            isNewMapping = true
        case .uploaded:
            state.lastRunEnqueuedCount += 1
            isNewMapping = true
        case .failed(let message):
            state.lastRunFailedCount += 1
            SyncLogStore.shared.append(
                SyncLogEntry(
                    kind: .upload,
                    trigger: "Apple Photos Sync",
                    failedCount: 1,
                    errorMessage: "\(candidate.originalFilename): \(message)"
                )
            )
        }
        refreshPendingFailureCount(state)
        saveState()
        notifyProgress(state)
        return isNewMapping
    }

    /// Builds a filename → [(assetId, fileCreatedAt)] lookup from the local SwiftData cache.
    /// Includes trashed assets on purpose so Apple Photos sync does not try to
    /// re-upload items that still exist in Immich's trash.
    /// Läuft über einen Background-ModelContext — bei großen Bibliotheken (100k+)
    /// würde der Fetch auf dem Main Thread die UI sekundenlang einfrieren.
    private func buildLocalFilenameIndex() async -> [String: [(id: String, createdAt: String)]] {
        let container = modelContext.container
        return await Task.detached(priority: .userInitiated) {
            let backgroundContext = ModelContext(container)
            let cached = (try? backgroundContext.fetch(FetchDescriptor<CachedAsset>())) ?? []
            var index: [String: [(id: String, createdAt: String)]] = [:]
            for asset in cached {
                index[asset.originalFileName, default: []].append((asset.assetId, asset.fileCreatedAt))
            }
            return index
        }.value
    }

    /// Returns the Immich asset ID if the local cache index contains a filename+date match.
    /// Requires a known `createdAt` — without it we cannot safely distinguish assets with
    /// identical filenames (e.g. IMG_0001.HEIC from different devices/years).
    private func findInLocalIndex(
        _ index: [String: [(id: String, createdAt: String)]],
        filename: String,
        localIdentifier: String,
        createdAt: Date
    ) -> String? {
        let safeId = localIdentifier.replacingOccurrences(of: "/", with: "_")
        let prefixedFilename = "\(safeId)-\(filename)"
        let entries = (index[filename] ?? []) + (index[prefixedFilename] ?? [])
        guard !entries.isEmpty else { return nil }
        let tolerance: TimeInterval = 60  // 1-minute slack for timezone/rounding differences
        let isoFull = ISO8601DateFormatter(); isoFull.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoBasic = ISO8601DateFormatter(); isoBasic.formatOptions = [.withInternetDateTime]
        for entry in entries {
            let serverDate = isoFull.date(from: entry.createdAt) ?? isoBasic.date(from: entry.createdAt)
            if let serverDate, abs(serverDate.timeIntervalSince(createdAt)) <= tolerance {
                return entry.id
            }
        }
        return nil
    }

    /// Lightweight Sendable snapshot of a mapping — safe to pass into background closures.
    private struct MappingSnapshot: Sendable {
        let lastKnownModificationDate: Date?
        let lastUploadedFileSize: Int64?
    }

    private struct CandidateLoadResult: Sendable {
        let candidates: [ApplePhotoCandidate]
        let totalWindowAssets: Int
        let skippedByMappingCount: Int
        /// Getrennt von `skippedByMappingCount`: das sind bewusst ignorierte Assets,
        /// die der Dialog separat ausweisen und zurücknehmen können muss.
        let ignoredCount: Int
        let reseeds: [ReseedInfo]
    }

    /// Schreibt Mapping-Zeitstempel für Metadaten-Bumps fort, damit dieselben
    /// Assets nicht bei jedem Lauf erneut als "geändert" auftauchen.
    /// Wird von `loadCandidates` selbst angewendet — Aufrufer können es nicht vergessen.
    private func applyReseeds(_ reseeds: [ReseedInfo], mappings: [String: ApplePhotosAssetMapping]) {
        guard !reseeds.isEmpty else { return }
        for reseed in reseeds {
            guard let mapping = mappings[reseed.localIdentifier] else { continue }
            mapping.lastKnownModificationDate = reseed.modificationDate
            if let size = reseed.fileSize {
                mapping.lastUploadedFileSize = size
            }
        }
        saveState()
        AppLogger.upload.info("AppleSync: reseeded \(reseeds.count) mapping(s) after metadata-only changes")
    }

    /// - Parameter restrictToLocalIdentifiers: Statt eines Datumsfensters genau diese
    ///   Assets betrachten (z.B. Apples "Zuletzt importiert"-Smart-Album, das nach
    ///   Import- statt Aufnahmedatum geht). Die Mapping- und Ignorier-Filter darunter
    ///   laufen unverändert weiter — anders als bei `loadCandidates(localIdentifiers:)`,
    ///   das für die *explizite* Nutzerauswahl gedacht ist und bewusst nichts überspringt.
    private func loadCandidates(
        forceFullSync: Bool,
        lastSuccessfulSyncAt: Date?,
        recentDays: Int?,
        restrictToLocalIdentifiers: Set<String>? = nil
    ) async -> (CandidateLoadResult, [String: ApplePhotosAssetMapping]) {
        // Fetch SwiftData mappings on the main actor, then convert to a plain Sendable dict
        // so we can safely cross the actor boundary into the background DispatchQueue below.
        let mappings = (try? modelContext.fetch(FetchDescriptor<ApplePhotosAssetMapping>())) ?? []
        let mappingByIdentifier = Dictionary(uniqueKeysWithValues: mappings.map { ($0.localIdentifier, $0) })

        // Sendable snapshot — only the fields we need on the background thread.
        let snapshots: [String: MappingSnapshot] = mappingByIdentifier.mapValues {
            MappingSnapshot(
                lastKnownModificationDate: $0.lastKnownModificationDate,
                lastUploadedFileSize: $0.lastUploadedFileSize
            )
        }

        let ignoredIdentifiers = loadIgnoredIdentifiers()

        let candidateAssets: CandidateLoadResult = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {

                // --- Predicate strategy ---
                //
                // forceFullSync:  no date filter — check every asset against its mapping.
                //
                // Normal sync with a known lastSuccessfulSyncAt:
                //   Filter on `creationDate >= baseline` OR `modificationDate >= baseline`.
                //   • creationDate = reliable "new photo taken/imported recently" signal
                //   • modificationDate = covers edits to already-uploaded photos
                //   Assets that pass the date filter are then checked per-mapping; assets
                //   that have an up-to-date mapping are skipped cheaply before any
                //   PHAssetResource call.
                //
                // First sync (lastSuccessfulSyncAt == nil):
                //   No date predicate — we must consider every asset because we don't yet
                //   know what's on the server.  The local-index pre-check in syncNow()
                //   will skip anything already in Immich without an upload.

                let baseMediaPredicate = NSPredicate(
                    format: "mediaType == %d OR mediaType == %d",
                    PHAssetMediaType.image.rawValue,
                    PHAssetMediaType.video.rawValue
                )

                let fetchPredicate: NSPredicate
                if !forceFullSync, let recentDays, recentDays > 0 {
                    let safeBaseline = Calendar.current.date(byAdding: .day, value: -recentDays, to: Date()) ?? Date()
                    let datePredicate = NSPredicate(
                        format: "creationDate >= %@ OR modificationDate >= %@",
                        safeBaseline as NSDate,
                        safeBaseline as NSDate
                    )
                    fetchPredicate = NSCompoundPredicate(andPredicateWithSubpredicates: [baseMediaPredicate, datePredicate])
                } else if !forceFullSync, let since = lastSuccessfulSyncAt {
                    // Continue from the last successful sync, with only a small
                    // overlap to avoid edge cases around the sync timestamp.
                    let safeBaseline = since.addingTimeInterval(-self.deltaSafetyBuffer)
                    let datePredicate = NSPredicate(
                        format: "creationDate >= %@ OR modificationDate >= %@",
                        safeBaseline as NSDate,
                        safeBaseline as NSDate
                    )
                    fetchPredicate = NSCompoundPredicate(andPredicateWithSubpredicates: [baseMediaPredicate, datePredicate])
                } else {
                    // First sync or force: no date restriction, but we still need the media-type filter.
                    fetchPredicate = baseMediaPredicate
                }

                let options = PHFetchOptions()
                options.predicate = fetchPredicate
                options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]

                // Eine feste ID-Menge ersetzt nur den *Fetch* — die Filterschleife darunter
                // (ignoriert / Mapping aktuell / Reupload-Entscheidung) bleibt dieselbe.
                // `fetchAssets(withLocalIdentifiers:)` kennt keinen Predicate, deshalb wird
                // der Medientyp hier nachträglich geprüft.
                let results: PHFetchResult<PHAsset>
                if let restrictToLocalIdentifiers {
                    let idOptions = PHFetchOptions()
                    idOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
                    results = PHAsset.fetchAssets(withLocalIdentifiers: Array(restrictToLocalIdentifiers), options: idOptions)
                } else {
                    results = PHAsset.fetchAssets(with: options)
                }
                var candidates: [ApplePhotoCandidate] = []
                var skippedByMappingCount = 0
                var ignoredCount = 0
                var reseeds: [ReseedInfo] = []

                results.enumerateObjects { asset, _, _ in
                    // Beim ID-Fetch greift `baseMediaPredicate` nicht (siehe oben).
                    guard asset.mediaType == .image || asset.mediaType == .video else { return }

                    let modified = asset.modificationDate ?? asset.creationDate ?? .distantPast
                    let snapshot = snapshots[asset.localIdentifier]

                    // Dauerhaft ignoriert → noch vor dem Mapping-Check raus, damit ein
                    // ignoriertes Asset auch bei forceFullSync nie hochgeladen wird.
                    if ignoredIdentifiers.contains(asset.localIdentifier) {
                        ignoredCount += 1
                        return
                    }

                    // Up-to-date mapping → skip cheaply without any PHAssetResource IPC (common case).
                    if let snapshot, let known = snapshot.lastKnownModificationDate, modified <= known {
                        skippedByMappingCount += 1
                        return
                    }

                    // PHAssetResource.assetResources() triggers disk/IPC — only call it
                    // for actual candidates.
                    let resources = PHAssetResource.assetResources(for: asset)
                    guard let resource = ApplePhotosSyncManager.preferredResourceStatic(in: resources, mediaType: asset.mediaType) else { return }
                    let fileSize = ApplePhotosSyncManager.resourceFileSize(resource)

                    switch ApplePhotosReuploadDecision.decide(
                        hasMapping: snapshot != nil,
                        lastKnownModificationDate: snapshot?.lastKnownModificationDate,
                        assetModificationDate: modified,
                        hasEditedResource: ApplePhotosSyncManager.hasEditedResource(in: resources),
                        lastUploadedFileSize: snapshot?.lastUploadedFileSize,
                        currentFileSize: fileSize
                    ) {
                    case .skip:
                        skippedByMappingCount += 1
                    case .reseed:
                        skippedByMappingCount += 1
                        reseeds.append(ReseedInfo(
                            localIdentifier: asset.localIdentifier,
                            modificationDate: modified,
                            fileSize: fileSize
                        ))
                    case .upload:
                        candidates.append(ApplePhotoCandidate(
                            asset: asset,
                            localIdentifier: asset.localIdentifier,
                            originalFilename: resource.originalFilename,
                            modificationDate: asset.modificationDate,
                            creationDate: asset.creationDate,
                            isRetry: false,
                            lastError: nil,
                            hasMapping: snapshot != nil,
                            resourceFileSize: fileSize
                        ))
                    }
                }

                AppLogger.upload.info("AppleSync: \(candidates.count) candidates from \(results.count) assets in window, \(skippedByMappingCount) skipped by mapping, \(ignoredCount) ignored, \(reseeds.count) reseeds (forceFullSync=\(forceFullSync))")
                continuation.resume(returning: CandidateLoadResult(
                    candidates: candidates,
                    totalWindowAssets: results.count,
                    skippedByMappingCount: skippedByMappingCount,
                    ignoredCount: ignoredCount,
                    reseeds: reseeds
                ))
            }
        }

        applyReseeds(candidateAssets.reseeds, mappings: mappingByIdentifier)
        return (candidateAssets, mappingByIdentifier)
    }

    private func loadCandidates(localIdentifiers: Set<String>) async -> (CandidateLoadResult, [String: ApplePhotosAssetMapping]) {
        let mappings = (try? modelContext.fetch(FetchDescriptor<ApplePhotosAssetMapping>())) ?? []
        let mappingByIdentifier = Dictionary(uniqueKeysWithValues: mappings.map { ($0.localIdentifier, $0) })
        // Auch der explizit ausgewählte Pfad respektiert die Ignorier-Liste: sonst
        // würde ein Asset, das im selben Lauf ignoriert wurde, trotzdem hochgeladen.
        let ignoredIdentifiers = loadIgnoredIdentifiers()
        let requestedIds = localIdentifiers.subtracting(ignoredIdentifiers)
        let ids = Array(requestedIds)
        guard !ids.isEmpty else {
            return (
                CandidateLoadResult(
                    candidates: [],
                    totalWindowAssets: 0,
                    skippedByMappingCount: 0,
                    ignoredCount: localIdentifiers.count,
                    reseeds: []
                ),
                mappingByIdentifier
            )
        }

        let mappedIds = Set(mappingByIdentifier.keys)
        let candidates: [ApplePhotoCandidate] = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
                var candidates: [ApplePhotoCandidate] = []
                assets.enumerateObjects { asset, _, _ in
                    let resources = PHAssetResource.assetResources(for: asset)
                    guard let resource = ApplePhotosSyncManager.preferredResourceStatic(in: resources, mediaType: asset.mediaType) else { return }
                    candidates.append(
                        ApplePhotoCandidate(
                            asset: asset,
                            localIdentifier: asset.localIdentifier,
                            originalFilename: resource.originalFilename,
                            modificationDate: asset.modificationDate,
                            creationDate: asset.creationDate,
                            isRetry: false,
                            lastError: nil,
                            hasMapping: mappedIds.contains(asset.localIdentifier),
                            resourceFileSize: ApplePhotosSyncManager.resourceFileSize(resource)
                        )
                    )
                }
                continuation.resume(returning: candidates)
            }
        }

        return (
            CandidateLoadResult(
                candidates: candidates,
                totalWindowAssets: requestedIds.count,
                skippedByMappingCount: 0,
                ignoredCount: localIdentifiers.count - requestedIds.count,
                reseeds: []
            ),
            mappingByIdentifier
        )
    }

    /// True wenn das Asset Edit-Artefakte hat. Reine Metadaten-Änderungen
    /// (Favorit, Album, Bildanalyse) erzeugen keine dieser Ressourcen.
    nonisolated fileprivate static func hasEditedResource(in resources: [PHAssetResource]) -> Bool {
        resources.contains {
            $0.type == .adjustmentData
                || $0.type == .fullSizePhoto
                || $0.type == .alternatePhoto
                || $0.type == .fullSizeVideo
        }
    }

    /// Dateigröße einer PHAssetResource. Läuft über KVC ("fileSize" ist kein
    /// dokumentiertes API), daher optional — bei Fehlschlag entscheidet die
    /// Heuristik konservativ (Upload statt Verlust eines echten Edits).
    nonisolated fileprivate static func resourceFileSize(_ resource: PHAssetResource) -> Int64? {
        (resource.value(forKey: "fileSize") as? NSNumber)?.int64Value
    }

    /// Static helper so it can be called from the nonisolated background queue closure above.
    /// Vorgabewert entfernt: `.unknown` nahm den Foto-Zweig, ein weggelassener
    /// Parameter hätte für ein Video also stillschweigend ein Standbild geliefert.
    /// Alle Aufrufer geben den Typ ohnehin an.
    nonisolated private static func preferredResourceStatic(in resources: [PHAssetResource], mediaType: PHAssetMediaType) -> PHAssetResource? {
        AppleResourcePicker.preferred(resources, mediaType: mediaType)
    }

    private func upsertMapping(
        localIdentifier: String,
        immichAssetId: String,
        modificationDate: Date?,
        fileSize: Int64?,
        existingMappings: [String: ApplePhotosAssetMapping]
    ) {
        if let existing = existingMappings[localIdentifier] {
            existing.immichAssetId = immichAssetId
            existing.lastKnownModificationDate = modificationDate
            existing.uploadedAt = Date()
            existing.lastUploadedFileSize = fileSize ?? existing.lastUploadedFileSize
        } else {
            modelContext.insert(
                ApplePhotosAssetMapping(
                    localIdentifier: localIdentifier,
                    immichAssetId: immichAssetId,
                    lastKnownModificationDate: modificationDate,
                    lastUploadedFileSize: fileSize
                )
            )
        }
        saveState()
    }

    private func loadFailureCandidates(now: Date, onlyDue: Bool, deleteMissing: Bool) -> [ApplePhotoCandidate] {
        let failures = (try? modelContext.fetch(FetchDescriptor<ApplePhotosSyncFailure>())) ?? []
        // Retries umgehen bewusst den "bereits vorhanden"-Filter — ohne diese
        // Bereinigung käme ein ignoriertes Asset über die Failure-Zeile zurück.
        let ignoredIdentifiers = loadIgnoredIdentifiers()
        let (ignoredFailures, activeFailures) = failures.reduce(
            into: ([ApplePhotosSyncFailure](), [ApplePhotosSyncFailure]())
        ) { partial, failure in
            if ignoredIdentifiers.contains(failure.localIdentifier) {
                partial.0.append(failure)
            } else {
                partial.1.append(failure)
            }
        }
        if !ignoredFailures.isEmpty {
            for failure in ignoredFailures {
                modelContext.delete(failure)
            }
            AppLogger.upload.info("AppleSync: \(ignoredFailures.count) Retry-Eintrag/-Einträge für ignorierte Assets entfernt")
            saveState()
        }

        let dueFailures = activeFailures.filter { failure in
            guard onlyDue else { return true }
            guard let nextRetryAt = failure.nextRetryAt else { return true }
            return nextRetryAt <= now
        }
        guard !dueFailures.isEmpty else { return [] }

        let ids = dueFailures.map(\.localIdentifier)
        let failuresById = Dictionary(uniqueKeysWithValues: dueFailures.map { ($0.localIdentifier, $0) })
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var candidates: [ApplePhotoCandidate] = []
        var foundIds = Set<String>()

        assets.enumerateObjects { asset, _, _ in
            let localIdentifier = asset.localIdentifier
            guard let failure = failuresById[localIdentifier] else { return }
            foundIds.insert(localIdentifier)
            let resources = PHAssetResource.assetResources(for: asset)
            let filename = ApplePhotosSyncManager
                .preferredResourceStatic(in: resources, mediaType: asset.mediaType)?
                .originalFilename ?? failure.originalFilename
            candidates.append(
                ApplePhotoCandidate(
                    asset: asset,
                    localIdentifier: localIdentifier,
                    originalFilename: filename,
                    modificationDate: asset.modificationDate ?? failure.modificationDate,
                    creationDate: asset.creationDate ?? failure.creationDate,
                    isRetry: true,
                    lastError: failure.lastError,
                    hasMapping: false,
                    resourceFileSize: ApplePhotosSyncManager
                        .preferredResourceStatic(in: resources, mediaType: asset.mediaType)
                        .flatMap { ApplePhotosSyncManager.resourceFileSize($0) }
                )
            )
        }

        if deleteMissing {
            for failure in dueFailures where !foundIds.contains(failure.localIdentifier) {
                AppLogger.upload.info("AppleSync: dropping retry entry for missing Photos asset \(failure.originalFilename)")
                modelContext.delete(failure)
            }
            saveState()
        }
        return candidates
    }

    private func recordFailure(candidate: ApplePhotoCandidate, errorMessage: String) {
        let id = candidate.localIdentifier
        let descriptor = FetchDescriptor<ApplePhotosSyncFailure>(
            predicate: #Predicate { $0.localIdentifier == id }
        )
        let now = Date()
        let nextRetryAt = now.addingTimeInterval(perAssetRetryDelays.last ?? 120)
        if let existing = try? modelContext.fetch(descriptor).first {
            existing.originalFilename = candidate.originalFilename
            existing.creationDate = candidate.creationDate
            existing.modificationDate = candidate.modificationDate
            existing.lastError = errorMessage
            existing.attemptCount += 1
            existing.lastAttemptAt = now
            existing.nextRetryAt = nextRetryAt
        } else {
            modelContext.insert(
                ApplePhotosSyncFailure(
                    localIdentifier: candidate.localIdentifier,
                    originalFilename: candidate.originalFilename,
                    creationDate: candidate.creationDate,
                    modificationDate: candidate.modificationDate,
                    lastError: errorMessage,
                    attemptCount: 1,
                    lastAttemptAt: now,
                    nextRetryAt: nextRetryAt
                )
            )
        }
        saveState()
    }

    private func removeFailure(localIdentifier: String) {
        let id = localIdentifier
        let descriptor = FetchDescriptor<ApplePhotosSyncFailure>(
            predicate: #Predicate { $0.localIdentifier == id }
        )
        if let failure = try? modelContext.fetch(descriptor).first {
            modelContext.delete(failure)
            saveState()
        }
    }

    private func refreshPendingFailureCount(_ state: ApplePhotosSyncState) {
        state.pendingFailureCount = (try? modelContext.fetchCount(FetchDescriptor<ApplePhotosSyncFailure>())) ?? 0
    }

    private func uploadApplePhoto(url: URL, localIdentifier: String, livePhotoVideoId: String? = nil) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            uploadManager.enqueueApplePhoto(url: url, localIdentifier: localIdentifier, livePhotoVideoId: livePhotoVideoId) { result in
                continuation.resume(with: result)
            }
        }
    }

    private func export(asset: PHAsset, into directory: URL) async throws -> URL {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = preferredResource(in: resources, mediaType: asset.mediaType) else {
            throw ApplePhotosSyncError.exportFailed("No exportable asset resource found.")
        }

        let safeId = asset.localIdentifier.replacingOccurrences(of: "/", with: "_")
        let fileName = "\(safeId)-\(resource.originalFilename)"
        let outputURL = directory.appending(path: fileName)

        let requestOptions = PHAssetResourceRequestOptions()
        requestOptions.isNetworkAccessAllowed = true

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(
                for: resource,
                toFile: outputURL,
                options: requestOptions
            ) { error in
                if let error {
                    continuation.resume(throwing: ApplePhotosSyncError.exportFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }

        // Filesystem-Timestamps auf Originaldatum setzen —
        // verhindert dass der Upload-Fallback das heutige Exportdatum verwendet
        if let creationDate = asset.creationDate {
            try? FileManager.default.setAttributes(
                [
                    FileAttributeKey.creationDate: creationDate,
                    FileAttributeKey.modificationDate: asset.modificationDate ?? creationDate
                ],
                ofItemAtPath: outputURL.path
            )
        }

        return outputURL
    }

    /// Export a specific PHAssetResource (used for Live Photo paired video).
    private func exportResource(_ resource: PHAssetResource, asset: PHAsset, into directory: URL) async throws -> URL {
        let safeId = asset.localIdentifier.replacingOccurrences(of: "/", with: "_")
        let fileName = "\(safeId)-\(resource.originalFilename)"
        let outputURL = directory.appending(path: fileName)

        let requestOptions = PHAssetResourceRequestOptions()
        requestOptions.isNetworkAccessAllowed = true

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(
                for: resource,
                toFile: outputURL,
                options: requestOptions
            ) { error in
                if let error {
                    continuation.resume(throwing: ApplePhotosSyncError.exportFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }

        if let creationDate = asset.creationDate {
            try? FileManager.default.setAttributes(
                [.creationDate: creationDate, .modificationDate: asset.modificationDate ?? creationDate],
                ofItemAtPath: outputURL.path
            )
        }

        return outputURL
    }

    /// Returns the paired video resource for a Live Photo asset, if present.
    ///
    /// Die Auswahlregel liegt in `AppleResourcePicker` — dieselbe, die die
    /// Löschprüfung benutzt. Zwei eigene Reihenfolgen bedeuteten: hochgeladen wird
    /// die eine Fassung, geprüft die andere.
    private func livePhotoPairedVideoResource(for asset: PHAsset) -> PHAssetResource? {
        guard asset.mediaSubtypes.contains(.photoLive) else { return nil }
        return AppleResourcePicker.pairedVideo(PHAssetResource.assetResources(for: asset))
    }

    private func preferredResource(in resources: [PHAssetResource], mediaType: PHAssetMediaType = .unknown) -> PHAssetResource? {
        ApplePhotosSyncManager.preferredResourceStatic(in: resources, mediaType: mediaType)
    }

    private func fetchOrCreateState() -> ApplePhotosSyncState {
        if let existing = try? modelContext.fetch(FetchDescriptor<ApplePhotosSyncState>()).first {
            return existing
        }
        let state = ApplePhotosSyncState()
        modelContext.insert(state)
        saveState()
        return state
    }

    private func saveState() {
        try? modelContext.save()
    }

    private func notifyProgress(_ state: ApplePhotosSyncState) {
        NotificationCenter.default.post(
            name: .applePhotosSyncProgressChanged,
            object: nil,
            userInfo: [
                "isRunning": state.isRunning,
                "windowAssetCount": state.lastRunWindowAssetCount,
                "scannedCount": state.lastRunScannedCount,
                "skippedByMappingCount": state.lastRunSkippedByMappingCount,
                "alreadyPresentCount": state.lastRunAlreadyPresentCount,
                "enqueuedCount": state.lastRunEnqueuedCount,
                "retriedCount": state.lastRunRetriedCount,
                "failedCount": state.lastRunFailedCount,
                "pendingFailureCount": state.pendingFailureCount
            ]
        )
    }

    private func recoverStaleRunningStateIfNeeded() {
        let descriptor = FetchDescriptor<ApplePhotosSyncState>()
        guard let state = try? modelContext.fetch(descriptor).first, state.isRunning else { return }
        state.isRunning = false
        if state.lastError == nil || state.lastError?.isEmpty == true {
            state.lastError = "Previous Apple Photos sync was interrupted."
        }
        refreshPendingFailureCount(state)
        saveState()
        notifyProgress(state)
    }

    private func ensurePhotoAuthorization() async -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .authorized, .limited:
            return true
        case .notDetermined:
            let newStatus: PHAuthorizationStatus = await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { authStatus in
                    continuation.resume(returning: authStatus)
                }
            }
            return newStatus == .authorized || newStatus == .limited
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }
}
