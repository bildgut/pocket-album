import Foundation
import Photos
import SwiftData
import OSLog

// MARK: - Result

struct FavSyncResult {
    var marked    = 0   // Als Favorit gesetzt
    var alreadyFav = 0  // War bereits Favorit
    var uploaded  = 0   // Neu auf Immich hochgeladen + als Favorit markiert
    var errors    = 0
    var total     = 0

    var summary: String {
        var parts: [String] = []
        if uploaded   > 0 { parts.append("\(uploaded) hochgeladen + ★") }
        if marked     > 0 { parts.append("\(marked) ★ gesetzt") }
        if alreadyFav > 0 { parts.append("\(alreadyFav) bereits ★") }
        if errors     > 0 { parts.append("\(errors) Fehler") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Progress

@Observable
@MainActor
final class FavSyncProgress {
    var isRunning = false
    var result    = FavSyncResult()
    var processed = 0

    var fraction: Double {
        guard result.total > 0 else { return 0 }
        return Double(processed) / Double(result.total)
    }
}

// MARK: - Manager

/// Überträgt isFavorite-Status von Apple Photos → Immich.
/// Assets die noch nicht auf Immich sind werden automatisch hochgeladen.
@MainActor
final class FavoritesSyncManager {
    let progress = FavSyncProgress()

    private let apiClient: ImmichAPIClient
    private let uploadManager: UploadManager
    private let modelContext: ModelContext
    private let logger = Logger(subsystem: "com.ralksta.immich-mac", category: "FavoritesSync")
    private var serverFilenameCache: [String: [Asset]] = [:]

    init(apiClient: ImmichAPIClient, uploadManager: UploadManager, modelContext: ModelContext) {
        self.apiClient     = apiClient
        self.uploadManager = uploadManager
        self.modelContext  = modelContext
    }

    // MARK: – Public

    @discardableResult
    func syncFavorites() -> Task<FavSyncResult, Never> {
        guard !progress.isRunning else { return Task { self.progress.result } }
        return Task { await self.run() }
    }

    // MARK: – Core

    private func run() async -> FavSyncResult {
        progress.isRunning = true
        progress.result    = FavSyncResult()
        progress.processed = 0
        serverFilenameCache = [:]

        // 1. Mapping-Index: localIdentifier → immichAssetId
        let mappings = (try? modelContext.fetch(FetchDescriptor<ApplePhotosAssetMapping>())) ?? []
        let mappingIndex = Dictionary(uniqueKeysWithValues: mappings.map { ($0.localIdentifier, $0.immichAssetId) })

        // PHAsset-Fetch auf Background-Queue (verhindert Main-Thread-Warnung)
        let assets = await fetchFavoriteAssets()
        progress.result.total = assets.count

        // Temp-Verzeichnis für eventuelle Uploads
        let runDir = (try? createTempDir()) ?? FileManager.default.temporaryDirectory
        defer { try? FileManager.default.removeItem(at: runDir) }

        var newlyMappedLocalIdentifiers = Set<String>()

        if !assets.isEmpty {
            try? await withThrowingTaskGroup(of: FavProcessResult.self) { group in
                var iterator = assets.makeIterator()
                for _ in 0..<3 {
                    if let asset = iterator.next() {
                        group.addTask { @MainActor in
                            if Task.isCancelled { return .error }
                            do {
                                let (immichId, wasUploaded, isNewMapping) = try await self.resolveOrUpload(
                                    asset: asset,
                                    mappingIndex: mappingIndex,
                                    runDir: runDir
                                )
                                let localId = asset.localIdentifier
                                let detail = try await self.apiClient.getAssetDetail(id: immichId)
                                if detail.isFavorite {
                                    return wasUploaded
                                        ? .uploadedAndMarked(localIdentifier: localId, isNewMapping: isNewMapping)
                                        : .alreadyFavorite(localIdentifier: localId, isNewMapping: isNewMapping)
                                } else {
                                    try await self.apiClient.toggleFavorite(assetId: immichId, isFavorite: true)
                                    self.logger.info("★ Favorit gesetzt: \(immichId)")
                                    return .marked(localIdentifier: localId, isNewMapping: isNewMapping)
                                }
                            } catch {
                                let filename = PHAssetResource.assetResources(for: asset).first?.originalFilename ?? "?"
                                self.logger.warning("Fehler für \(filename): \(error.localizedDescription)")
                                return .error
                            }
                        }
                    }
                }
                while let result = try await group.next() {
                    switch result {
                    case .alreadyFavorite(let localId, let isNewMapping):
                        self.progress.result.alreadyFav += 1
                        if isNewMapping { newlyMappedLocalIdentifiers.insert(localId) }
                    case .marked(let localId, let isNewMapping):
                        self.progress.result.marked += 1
                        if isNewMapping { newlyMappedLocalIdentifiers.insert(localId) }
                    case .uploadedAndMarked(let localId, let isNewMapping):
                        self.progress.result.uploaded += 1
                        if isNewMapping { newlyMappedLocalIdentifiers.insert(localId) }
                    case .error:
                        self.progress.result.errors += 1
                    }
                    self.progress.processed += 1
                    if let nextAsset = iterator.next() {
                        group.addTask { @MainActor in
                            if Task.isCancelled { return .error }
                            do {
                                let (immichId, wasUploaded, isNewMapping) = try await self.resolveOrUpload(
                                    asset: nextAsset,
                                    mappingIndex: mappingIndex,
                                    runDir: runDir
                                )
                                let localId = nextAsset.localIdentifier
                                let detail = try await self.apiClient.getAssetDetail(id: immichId)
                                if detail.isFavorite {
                                    return wasUploaded
                                        ? .uploadedAndMarked(localIdentifier: localId, isNewMapping: isNewMapping)
                                        : .alreadyFavorite(localIdentifier: localId, isNewMapping: isNewMapping)
                                } else {
                                    try await self.apiClient.toggleFavorite(assetId: immichId, isFavorite: true)
                                    self.logger.info("★ Favorit gesetzt: \(immichId)")
                                    return .marked(localIdentifier: localId, isNewMapping: isNewMapping)
                                }
                            } catch {
                                let filename = PHAssetResource.assetResources(for: nextAsset).first?.originalFilename ?? "?"
                                self.logger.warning("Fehler für \(filename): \(error.localizedDescription)")
                                return .error
                            }
                        }
                    }
                }
            }
        }

        // Trigger a background sync so newly-uploaded assets and updated favorite
        // flags show up in the photo grid without waiting for the next scheduled poll.
        if progress.result.uploaded > 0 || progress.result.marked > 0 {
            NotificationCenter.default.post(name: .localAssetMutation, object: nil)
        }

        // Der Favoriten-Sync selbst ist hier fertig; das Flag darf die Löschprüfung
        // nicht überdauern. Die prüft byte-weise und lädt dafür notfalls Originale aus
        // iCloud — bliebe `isRunning` so lange gesetzt, würde `syncFavorites()` jeden
        // weiteren Lauf stillschweigend verwerfen (dieselbe Reihenfolge wie im
        // Apple-Photos-Sync in `UploadManager`).
        progress.isRunning = false

        await ApplePhotoDeletionService(modelContext: modelContext, apiClient: apiClient)
            .considerDeletion(newlyMappedLocalIdentifiers: newlyMappedLocalIdentifiers)

        return progress.result
    }

    // MARK: – Resolve or Upload

    /// Gibt die Immich-Asset-ID zurück — entweder aus dem Mapping, via Server-Suche,
    /// oder nach einem frischen Upload (wenn noch nicht auf Immich).
    private enum FavProcessResult {
        case alreadyFavorite(localIdentifier: String, isNewMapping: Bool)
        case marked(localIdentifier: String, isNewMapping: Bool)
        case uploadedAndMarked(localIdentifier: String, isNewMapping: Bool)
        case error
    }

    /// `wasUploaded`: true nur, wenn dieser Lauf das Foto tatsächlich hochgeladen hat
    /// (für die Zusammenfassung "X hochgeladen + ★"). `isNewMapping`: true, wenn das
    /// SwiftData-Mapping (Apple-Foto → Immich-Asset) in diesem Lauf neu angelegt wurde
    /// (Server-Fund *oder* Upload) — false, wenn es bereits vor diesem Lauf bestand.
    /// Für die automatische Apple-Photos-Löschung zählt `isNewMapping`, nicht
    /// `wasUploaded`: Ein per Server-Suche neu verknüpftes Foto ist genauso ein frisch
    /// bestätigter Immich-Bestand wie ein tatsächlich hochgeladenes.
    private func resolveOrUpload(
        asset: PHAsset,
        mappingIndex: [String: String],
        runDir: URL
    ) async throws -> (immichId: String, wasUploaded: Bool, isNewMapping: Bool) {
        // Primär: lokale Mapping-DB (O(1))
        if let mapped = mappingIndex[asset.localIdentifier] {
            return (mapped, false, false)
        }

        // Fallback: Filename + Datum-Suche auf Server
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = preferredResource(for: asset, in: resources) else {
            throw FavSyncError.noResource
        }
        let filename = resource.originalFilename

        if let found = try await findOnServer(filename: filename, createdAt: asset.creationDate) {
            // Das Ergebnis festhalten — sonst läuft dieselbe Suche bei jedem Lauf
            // erneut, für jedes Foto, das schon auf dem Server liegt. Der
            // `serverFilenameCache` hilft nur innerhalb eines Laufs.
            // `AlbumSyncManager` merkt sich den Treffer an der gleichen Stelle
            // (Tier 2); hier fehlte es.
            modelContext.upsertApplePhotosMapping(
                localIdentifier: asset.localIdentifier,
                immichAssetId: found,
                modificationDate: asset.modificationDate
            )
            return (found, false, true)
        }

        // Noch nicht auf Immich → exportieren + hochladen
        let exportURL = try await export(asset: asset, resource: resource, into: runDir)
        defer { try? FileManager.default.removeItem(at: exportURL) }

        let immichId = try await uploadAndMap(
            url: exportURL,
            localIdentifier: asset.localIdentifier,
            modificationDate: asset.modificationDate
        )
        return (immichId, true, true)
    }

    // MARK: – Server Search

    private func findOnServer(filename: String, createdAt: Date?) async throws -> String? {
        let serverAssets: [Asset]
        if let cached = serverFilenameCache[filename] {
            serverAssets = cached
        } else {
            serverAssets = try await apiClient.searchByOriginalFilename(filename)
            serverFilenameCache[filename] = serverAssets
        }
        guard !serverAssets.isEmpty else { return nil }
        guard let createdAt else { return serverAssets.first?.id }

        let tolerance: TimeInterval = 60
        return serverAssets.first(where: {
            guard let d = $0.createdDate else { return false }
            return abs(d.timeIntervalSince(createdAt)) <= tolerance
        })?.id
    }

    // MARK: – Export

    private func export(asset: PHAsset, resource: PHAssetResource, into directory: URL) async throws -> URL {
        let safeId = asset.localIdentifier.replacingOccurrences(of: "/", with: "_")
        let outputURL = directory.appending(path: "\(safeId)-\(resource.originalFilename)")

        let reqOpts = PHAssetResourceRequestOptions()
        reqOpts.isNetworkAccessAllowed = true

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: outputURL, options: reqOpts) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }

        // Filesystem-Timestamps korrigieren (verhindert falsches Upload-Datum)
        if let creationDate = asset.creationDate {
            try? FileManager.default.setAttributes(
                [.creationDate: creationDate, .modificationDate: asset.modificationDate ?? creationDate],
                ofItemAtPath: outputURL.path
            )
        }
        return outputURL
    }

    // MARK: – Upload + Mapping

    private func uploadAndMap(url: URL, localIdentifier: String, modificationDate: Date?) async throws -> String {
        let immichId: String = try await withCheckedThrowingContinuation { cont in
            uploadManager.enqueueApplePhoto(url: url, localIdentifier: localIdentifier) { result in
                cont.resume(with: result)
            }
        }

        // Mapping in SwiftData persistieren — über die geteilte Fassung, damit alle
        // drei Aufrufstellen dieselbe benutzen.
        modelContext.upsertApplePhotosMapping(
            localIdentifier: localIdentifier,
            immichAssetId: immichId,
            modificationDate: modificationDate
        )

        // UploadManager posts .assetsDidChange which writes to GridIndexStore, but only
        // for the minimal Asset struct it knows about. Ensure the GridIndexStore entry
        // is present by the time this sync run finishes so a cache reload can find it.
        // (UploadManager already handles this via its own notification path; this is a
        //  belt-and-suspenders guard in case the mapping is reused without a real upload.)

        return immichId
    }

    // MARK: – Background Fetch

    /// Fetcht alle Favoriten-PHAssets auf einem Background-Thread.
    private nonisolated func fetchFavoriteAssets() async -> [PHAsset] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let opts = PHFetchOptions()
                opts.predicate = NSPredicate(format: "isFavorite == YES")
                var result: [PHAsset] = []
                PHAsset.fetchAssets(with: opts).enumerateObjects { a, _, _ in
                    result.append(a)
                }
                continuation.resume(returning: result)
            }
        }
    }

    // MARK: - Resource Selection

    private func preferredResource(for asset: PHAsset, in resources: [PHAssetResource]) -> PHAssetResource? {
        AppleResourcePicker.preferred(resources, mediaType: asset.mediaType)
    }

    // MARK: – Helpers

    private func createTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "fav-sync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

// MARK: - Error

private enum FavSyncError: Error {
    case noResource
}
