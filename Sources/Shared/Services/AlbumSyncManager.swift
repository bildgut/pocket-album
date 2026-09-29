import Foundation
import Photos
import SwiftData

// MARK: - Progress Observable

/// Observable progress state for an album sync run.
@Observable
@MainActor
final class AlbumSyncProgress {
    var isRunning = false
    var total = 0
    var processed = 0
    var uploadedCount = 0
    var mappedCount = 0
    var skippedCount = 0
    var errorMessage: String?
    var isCancelled = false

    var progressFraction: Double {
        guard total > 0 else { return 0 }
        return Double(processed) / Double(total)
    }

    var summaryLine: String {
        guard !isRunning && total > 0 else { return "" }
        var parts: [String] = []
        if uploadedCount > 0 { parts.append("\(uploadedCount) hochgeladen") }
        if mappedCount > 0 { parts.append("\(mappedCount) verknüpft") }
        if skippedCount > 0 { parts.append("\(skippedCount) übersprungen") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Manager

/// Syncs a specific Apple Photos album into Immich.
/// Three-tier resolution per asset:
///   1. Already mapped locally → only add to album (no export)
///   2. Filename + date light-match on server → store mapping, add to album
///   3. Unknown → export, upload, store mapping, add to album
@MainActor
final class AlbumSyncManager {
    let progress = AlbumSyncProgress()

    private let modelContext: ModelContext
    private let uploadManager: UploadManager
    private let apiClient: ImmichAPIClient
    private var syncTask: Task<Void, Never>?
    private var serverFilenameCache: [String: [Asset]] = [:]

    init(modelContext: ModelContext, uploadManager: UploadManager, apiClient: ImmichAPIClient) {
        self.modelContext = modelContext
        self.uploadManager = uploadManager
        self.apiClient = apiClient
    }

    // MARK: - Public API

    @discardableResult
    func syncAlbum(
        collection: PHAssetCollection,
        toImmichAlbumId immichAlbumId: String,
        forceRecheck: Bool = false
    ) -> Task<Void, Never> {
        guard !progress.isRunning else { return Task {} }
        let task = Task { await self.run(collection: collection, immichAlbumId: immichAlbumId, forceRecheck: forceRecheck) }
        syncTask = task
        return task
    }

    func cancel() {
        syncTask?.cancel()
        progress.isCancelled = true
        progress.isRunning = false
    }

    // MARK: - Core Run

    private func run(collection: PHAssetCollection, immichAlbumId: String, forceRecheck: Bool) async {
        progress.isRunning = true
        progress.isCancelled = false
        progress.errorMessage = nil
        serverFilenameCache = [:]

        // PHAsset-Fetch + Resource-Access auf Background-Queue (verhindert Main-Thread-Warnung)
        let bundles = await fetchAssetBundles(in: collection)

        progress.total = bundles.count
        progress.processed = 0
        progress.uploadedCount = 0
        progress.mappedCount = 0
        progress.skippedCount = 0

        guard !bundles.isEmpty else {
            progress.isRunning = false
            return
        }

        // Load existing mappings once.
        // When forceRecheck = true (Erneut syncen), Tier 1 wird übersprungen:
        // dann prüft Tier 2 den Server direkt, so dass gelöschte Assets korrekt re-uploaded werden.
        let mappingByIdentifier: [String: ApplePhotosAssetMapping]
        if forceRecheck {
            mappingByIdentifier = [:]
        } else {
            let existingMappings = (try? modelContext.fetch(FetchDescriptor<ApplePhotosAssetMapping>())) ?? []
            mappingByIdentifier = Dictionary(uniqueKeysWithValues: existingMappings.map { ($0.localIdentifier, $0) })
        }

        do {
            // Create temp directory for this sync run
            let runDir = FileManager.default.temporaryDirectory
                .appending(path: "album-sync-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: runDir) }

            var collectedImmichIds: [String] = []
            var newlyMappedLocalIdentifiers = Set<String>()

            if !bundles.isEmpty {
                try? await withThrowingTaskGroup(of: AlbumProcessResult.self) { group in
                    var iterator = bundles.makeIterator()
                    for _ in 0..<3 {
                        if let (asset, resource) = iterator.next() {
                            group.addTask { @MainActor in
                                if Task.isCancelled || self.progress.isCancelled { return .failed }
                                return await self.processAsset(
                                    asset: asset,
                                    resource: resource,
                                    mappingByIdentifier: mappingByIdentifier,
                                    runDir: runDir
                                )
                            }
                        }
                    }
                    while let result = try await group.next() {
                        switch result {
                        case .mapped(let id, let localId, let isNewMapping):
                            collectedImmichIds.append(id)
                            if isNewMapping { newlyMappedLocalIdentifiers.insert(localId) }
                            self.progress.mappedCount += 1
                        case .uploaded(let id, let localId):
                            collectedImmichIds.append(id)
                            newlyMappedLocalIdentifiers.insert(localId)
                            self.progress.uploadedCount += 1
                        case .failed:
                            self.progress.skippedCount += 1
                        }
                        self.progress.processed += 1
                        if let (nextAsset, nextResource) = iterator.next() {
                            group.addTask { @MainActor in
                                if Task.isCancelled || self.progress.isCancelled { return .failed }
                                return await self.processAsset(
                                    asset: nextAsset,
                                    resource: nextResource,
                                    mappingByIdentifier: mappingByIdentifier,
                                    runDir: runDir
                                )
                            }
                        }
                    }
                }
            }

            // Add collected asset IDs to the Immich album in small batches so that a
            // transient network error only loses one chunk, not the entire sync run.
            if !collectedImmichIds.isEmpty && !Task.isCancelled && !progress.isCancelled {
                let batchSize = 50
                var addedTotal = 0
                for batchStart in stride(from: 0, to: collectedImmichIds.count, by: batchSize) {
                    if Task.isCancelled || progress.isCancelled { break }
                    let batch = Array(collectedImmichIds[batchStart..<min(batchStart + batchSize, collectedImmichIds.count)])
                    do {
                        try await apiClient.addAssetsToAlbum(albumId: immichAlbumId, assetIds: batch)
                        addedTotal += batch.count
                    } catch {
                        AppLogger.upload.warning("AlbumSync: addAssetsToAlbum batch failed (start=\(batchStart)): \(error)")
                    }
                }
                AppLogger.upload.info("AlbumSync: added \(addedTotal)/\(collectedImmichIds.count) assets to Immich album \(immichAlbumId)")
            }

            // Notify sidebar (albums) AND the photo grid (new assets visible in library)
            NotificationCenter.default.post(name: .albumsDidChange, object: nil)
            NotificationCenter.default.post(name: .localAssetMutation, object: nil)

            // Wie im Favoriten-Sync: Der Album-Sync ist hier durch, und die
            // Löschprüfung dahinter hasht vollständige Originale (notfalls erst aus
            // iCloud geladen). Bliebe `isRunning` so lange gesetzt, verwürfe der
            // Reentry-Guard in `syncAlbums()` jeden weiteren Lauf stillschweigend.
            progress.isRunning = false

            if !Task.isCancelled && !progress.isCancelled {
                await ApplePhotoDeletionService(modelContext: modelContext, apiClient: apiClient)
                    .considerDeletion(newlyMappedLocalIdentifiers: newlyMappedLocalIdentifiers)
            }

        } catch {
            progress.errorMessage = error.localizedDescription
        }

        progress.isRunning = false
    }

    // MARK: - Tier 1 Validation

    /// Ob `id` noch auf dem Server liegt.
    ///
    /// Nutzt den Namens-Cache, den Tier 2 ohnehin aufbaut.
    ///
    /// - Returns: `nil`, wenn die Frage **nicht beantwortet** werden konnte. Das ist
    ///   etwas anderes als „nein", und der Unterschied ist hier teuer: Aus einem
    ///   `?? []` wurde vorher beides dasselbe. Der leere Ersatzwert landete zudem im
    ///   Cache — also als Aussage „diesen Dateinamen kennt der Server nicht". Tier 2
    ///   fragte deshalb gar nicht erst nach, Tier 3 exportierte und lud hoch: Das
    ///   Original wird bei Bedarf aus iCloud geholt, für eine Datei, die längst auf
    ///   dem Server liegt. Und der Eintrag stand den ganzen Lauf über, betraf also
    ///   jede weitere Aufnahme desselben Namens.
    ///
    ///   Dieselbe Unterscheidung treffen `GridIndexStore.countVisibleChecked` und
    ///   `idsMissingExifCheck` bereits.
    ///
    /// Bewusst `internal` statt `private`, damit `AlbumSyncMatchingTests` sie direkt
    /// aufrufen kann — wie bei `findOnServer` daneben.
    func serverAssetExists(id: String, filename: String, createdAt: Date?) async -> Bool? {
        if let cached = serverFilenameCache[filename] {
            return cached.contains(where: { $0.id == id })
        }
        guard let fetched = try? await apiClient.searchByOriginalFilename(filename) else {
            AppLogger.upload.warning(
                "AlbumSync: Bestandsprüfung für \(filename) fehlgeschlagen — Zuordnung bleibt bestehen"
            )
            return nil
        }
        // Nur ein tatsächlich beantworteter Abruf gehört in den Cache.
        serverFilenameCache[filename] = fetched
        return fetched.contains(where: { $0.id == id })
    }

    // MARK: - Tier 2: Server Light-Check

    func findOnServer(filename: String, createdAt: Date?) async throws -> String? {
        let serverAssets: [Asset]
        if let cached = serverFilenameCache[filename] {
            serverAssets = cached
        } else {
            let fetched = try await apiClient.searchByOriginalFilename(filename)
            serverFilenameCache[filename] = fetched
            serverAssets = fetched
        }

        guard !serverAssets.isEmpty else { return nil }
        guard let createdAt else { return serverAssets.first?.id }

        let tolerance: TimeInterval = 5
        if let exact = serverAssets.first(where: {
            guard let serverCreated = parseISODate($0.fileCreatedAt) else { return false }
            return abs(serverCreated.timeIntervalSince(createdAt)) <= tolerance
        }) {
            return exact.id
        }
        return nil
    }

    // MARK: - Tier 3: Export + Upload

    private func export(asset: PHAsset, resource: PHAssetResource, into directory: URL) async throws -> URL {
        let safeId = asset.localIdentifier.replacingOccurrences(of: "/", with: "_")
        let outputURL = directory.appending(path: "\(safeId)-\(resource.originalFilename)")

        let requestOptions = PHAssetResourceRequestOptions()
        requestOptions.isNetworkAccessAllowed = true

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(
                for: resource,
                toFile: outputURL,
                options: requestOptions
            ) { error in
                if let error {
                    continuation.resume(throwing: error)
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

    private func uploadAndMap(url: URL, localIdentifier: String, modificationDate: Date?) async throws -> String {
        let immichId: String = try await withCheckedThrowingContinuation { continuation in
            uploadManager.enqueueApplePhoto(url: url, localIdentifier: localIdentifier) { result in
                continuation.resume(with: result)
            }
        }
        upsertMapping(localIdentifier: localIdentifier, immichAssetId: immichId, modificationDate: modificationDate)
        return immichId
    }

    // MARK: - Mapping Persistence

    private func upsertMapping(localIdentifier: String, immichAssetId: String, modificationDate: Date?) {
        modelContext.upsertApplePhotosMapping(
            localIdentifier: localIdentifier,
            immichAssetId: immichAssetId,
            modificationDate: modificationDate
        )
    }

    // MARK: - Background Fetch

    /// Fetcht alle PHAssets + bevorzugte Ressource auf einem Background-Thread.
    /// Verhindert das "Fetching on demand on the main queue" Warning.
    private nonisolated func fetchAssetBundles(in collection: PHAssetCollection) async -> [(PHAsset, PHAssetResource)] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var result: [(PHAsset, PHAssetResource)] = []
                let opts = PHFetchOptions()
                opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
                PHAsset.fetchAssets(in: collection, options: opts).enumerateObjects { asset, _, _ in
                    guard asset.mediaType == .image || asset.mediaType == .video else { return }
                    let resources = PHAssetResource.assetResources(for: asset)
                    if let r = AlbumSyncManager.preferredResourceStatic(for: asset, in: resources) {
                        result.append((asset, r))
                    }
                }
                continuation.resume(returning: result)
            }
        }
    }

    // MARK: - Helpers

    private func preferredResource(for asset: PHAsset, in resources: [PHAssetResource]) -> PHAssetResource? {
        AppleResourcePicker.preferred(resources, mediaType: asset.mediaType)
    }

    private nonisolated static func preferredResourceStatic(for asset: PHAsset, in resources: [PHAssetResource]) -> PHAssetResource? {
        AppleResourcePicker.preferred(resources, mediaType: asset.mediaType)
    }

    private func parseISODate(_ value: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: value) { return date }
        let withoutFractional = ISO8601DateFormatter()
        withoutFractional.formatOptions = [.withInternetDateTime]
        return withoutFractional.date(from: value)
    }

    private enum AlbumProcessResult {
        /// `isNewMapping`: false für Tier 1 (Mapping existierte schon vor diesem Lauf),
        /// true für Tier 2 (gerade erst per Server-Suche verknüpft).
        case mapped(immichId: String, localIdentifier: String, isNewMapping: Bool)
        case uploaded(immichId: String, localIdentifier: String)
        case failed
    }

    private func processAsset(
        asset: PHAsset,
        resource: PHAssetResource,
        mappingByIdentifier: [String: ApplePhotosAssetMapping],
        runDir: URL
    ) async -> AlbumProcessResult {
        let localId = asset.localIdentifier
        
        // Tier 1: Already mapped locally
        if let mapping = mappingByIdentifier[localId] {
            let knownId = mapping.immichAssetId
            switch await serverAssetExists(
                id: knownId, filename: resource.originalFilename, createdAt: asset.creationDate
            ) {
            case .some(true):
                return .mapped(immichId: knownId, localIdentifier: localId, isNewMapping: false)
            case .none:
                // Nicht feststellbar: Die Zuordnung galt bis eben, und ein
                // Neuaufbau auf bloßen Verdacht kostet Export und Upload. Der
                // nächste Lauf mit Netz klärt es.
                return .mapped(immichId: knownId, localIdentifier: localId, isNewMapping: false)
            case .some(false):
                AppLogger.upload.info("AlbumSync: stale mapping for \(localId), re-resolving")
            }
        }

        let filename  = resource.originalFilename
        let createdAt = asset.creationDate

        // Tier 2: Light-match on server
        do {
            if let existingId = try await findOnServer(filename: filename, createdAt: createdAt) {
                upsertMapping(localIdentifier: localId, immichAssetId: existingId, modificationDate: asset.modificationDate)
                return .mapped(immichId: existingId, localIdentifier: localId, isNewMapping: true)
            }
        } catch {
            AppLogger.upload.warning("AlbumSync: Tier 2 check failed for \(filename): \(error)")
        }

        // Tier 3: Export + Upload
        let exportedURL: URL
        do {
            exportedURL = try await export(asset: asset, resource: resource, into: runDir)
        } catch {
            AppLogger.upload.warning("AlbumSync: export failed for \(filename): \(error)")
            return .failed
        }

        defer { try? FileManager.default.removeItem(at: exportedURL) }

        do {
            let immichId = try await uploadAndMap(url: exportedURL, localIdentifier: localId, modificationDate: asset.modificationDate)
            return .uploaded(immichId: immichId, localIdentifier: localId)
        } catch {
            AppLogger.upload.warning("AlbumSync: upload failed for \(filename): \(error)")
            return .failed
        }
    }
}
