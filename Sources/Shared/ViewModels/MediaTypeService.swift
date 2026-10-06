import Foundation
import SwiftData
import os

@Observable
@MainActor
final class MediaTypeService {
    // Cache for media type result sets (server- or local-derived).
    private(set) var mediaTypeCache: [MediaType: [Asset]] = [:]
    private var mediaTypeLoading: Set<MediaType> = []
    
    private let apiClient: ImmichAPIClient
    private var modelContext: ModelContext?
    
    init(apiClient: ImmichAPIClient) {
        self.apiClient = apiClient
    }
    
    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
    }
    
    func clearCache() {
        mediaTypeCache.removeAll()
    }
    
    /// Update panorama in cache directly when repository finishes its local scan
    func setPanoramas(_ panoramas: [Asset]) {
        mediaTypeCache[.panoramas] = panoramas
    }

    /// Retrieve the assets. If not loaded, returns filtered cache or empty array.
    func assets(for mediaType: MediaType, cachedAssets: [Asset]) -> [Asset] {
        if let cached = mediaTypeCache[mediaType] {
            return cached
        }
        if mediaType.requiresServerSearch {
            return []
        }
        return cachedAssets.filter { mediaType.matches($0) }
    }

    func isMediaTypeLoading(_ mediaType: MediaType) -> Bool {
        mediaTypeLoading.contains(mediaType)
    }

    /// Load media type assets that are not reliably derivable from the lightweight grid index.
    func loadMediaTypeIfNeeded(_ mediaType: MediaType, assetRepository: AssetRepository) async {
        guard !mediaTypeLoading.contains(mediaType) else { return }
        if mediaTypeCache[mediaType] != nil { return } // Skip if already loaded

        mediaTypeLoading.insert(mediaType)
        defer { mediaTypeLoading.remove(mediaType) }

        let assets: [Asset]
        if mediaType.requiresServerSearch {
            if mediaType == .rawFiles {
                assets = rawAssetsFromSwiftData(cachedAssets: assetRepository.cachedAssets)
            } else {
                do {
                    assets = try await serverMediaTypeAssets(mediaType)
                } catch {
                    // Ohne Server dieselbe Regel lokal — das Fenster oder SwiftData
                    // kennen nicht alles, aber eine leere Liste wäre die schlechtere Anzeige.
                    AppLogger.library.warning("\(String(describing: mediaType)): Serverfilter fehlgeschlagen, lokale Regel — \(error)")
                    assets = assetRepository.isLocalPagingEnabled
                        ? await localMediaTypeAssetsFromSwiftData(mediaType, fallbackAssets: assetRepository.cachedAssets)
                        : assetRepository.cachedAssets.filter { mediaType.matches($0) }
                }
            }
        } else if assetRepository.isLocalPagingEnabled {
            assets = await localMediaTypeAssetsFromSwiftData(mediaType, fallbackAssets: assetRepository.cachedAssets)
        } else {
            assets = assetRepository.cachedAssets.filter { mediaType.matches($0) }
        }
        
        AppLogger.library.info("\(String(describing: mediaType)): \(assets.count) results")
        mediaTypeCache[mediaType] = assets
    }

    /// Reihenfolge der Medienart-Listen: neueste zuerst, bei gleichem Aufnahmedatum
    /// nach Kennung.
    ///
    /// Der zweite Vergleich ist nicht kosmetisch. Die Listen entstehen aus einem
    /// Dictionary, dessen Reihenfolge unbestimmt ist — und gleiche Zeitstempel sind in
    /// dieser Bibliothek der Normalfall: `GeoMatcher.timestampCrowding` dokumentiert
    /// eine einzelne Sekunde mit 186 Aufnahmen, weil der Server bei fehlendem
    /// Aufnahmedatum einen Rückfallwert setzt. Ohne ihn stand „Videos", „Selfies" oder
    /// „RAW" nach jedem Laden anders da.
    ///
    /// Dieselbe Vorsorge treffen `GeoMatcher.scan`, `DuplicateMatcher.buildGroups`
    /// („damit zweimal Scannen zweimal dieselbe Reihenfolge ergibt") und
    /// `HighlightScorer.topHighlights`.
    nonisolated static func newestFirst(_ a: Asset, _ b: Asset) -> Bool {
        a.fileCreatedAt == b.fileCreatedAt
            ? a.id < b.id
            : a.fileCreatedAt > b.fileCreatedAt
    }

    // MARK: - Server (Selfies, Porträts)

    private var catalogCache: [String: [String]] = [:]
    private var cachedUserId: String?

    /// Selfies und Porträts vom Server: die Objektivregel als **ein** Filter
    /// (``MediaTypeServerQuery``), bei Porträts dazu die ``MediaType/clipLimit``
    /// relevantesten CLIP-Treffer.
    ///
    /// Ersetzt eine Kaskade aus bis zu 10 000 CLIP-Treffern, einer Metadatensuche, die
    /// mit `lensModel: "front"` exakt verglich und nie etwas fand, der lokalen Regel und
    /// bis zu 1 000 Einzelabrufen als Rückfall. Der Filter trifft dieselbe Regel wie
    /// ``MediaType/matches(_:)`` über die ganze Bibliothek (11.09.2026: 4 016 Selfies,
    /// 1 935 Porträts, ID-genau gleich dem Index; CLIP fügt 122 hinzu).
    ///
    /// Die CLIP-Treffer kommen ohne Eigentümer — Partner-Assets könnten darunter sein.
    /// Die alte Fassung nahm sie ebenso mit.
    func serverMediaTypeAssets(_ mediaType: MediaType) async throws -> [Asset] {
        var merged: [String: Asset] = [:]

        let lenses = try await catalog("camera-lens-model")
        let models = try await catalog("camera-model")
        if let filter = MediaTypeServerQuery.filter(for: mediaType, lenses: lenses, models: models) {
            let userId: String
            if let cachedUserId {
                userId = cachedUserId
            } else {
                userId = try await apiClient.getMyUserId()
                cachedUserId = userId
            }
            for asset in try await apiClient.searchAllOwnAssets(filter: filter, ownerId: userId) {
                merged[asset.id] = asset
            }
        }

        if let query = mediaType.clipQuery {
            let clip = try await apiClient.smartSearch(
                query: query, filter: .visibleLibrary(type: .image), size: MediaType.clipLimit
            )
            for asset in clip where merged[asset.id] == nil {
                merged[asset.id] = asset
            }
        }

        return merged.values.sorted(by: Self.newestFirst)
    }

    private func catalog(_ type: String) async throws -> [String] {
        if let cached = catalogCache[type] { return cached }
        let values = try await apiClient.searchSuggestions(type: type)
        catalogCache[type] = values
        return values
    }

    private func localMediaTypeAssetsFromSwiftData(_ mediaType: MediaType, fallbackAssets: [Asset]) async -> [Asset] {
        guard let modelContext else { return fallbackAssets.filter { mediaType.matches($0) } }
        let container = modelContext.container

        return await Task.detached(priority: .userInitiated) {
            let bgContext = ModelContext(container)
            bgContext.autosaveEnabled = false
            let descriptor = FetchDescriptor<CachedAsset>(
                predicate: #Predicate<CachedAsset> { $0.isTrashed == false && $0.isArchived == false && $0.isHidden == false },
                sortBy: [SortDescriptor(\.fileCreatedAt, order: .reverse)]
            )
            let rows = (try? bgContext.fetch(descriptor)) ?? []
            return rows
                .map { $0.toAsset() }
                .filter { mediaType.matches($0) }
        }.value
    }

    private func rawAssetsFromSwiftData(cachedAssets: [Asset]) -> [Asset] {
        guard let modelContext else { return cachedAssets.filter { MediaType.rawFiles.matches($0) } }
        let descriptor = FetchDescriptor<CachedAsset>(
            predicate: #Predicate<CachedAsset> { $0.isTrashed == false && $0.isArchived == false && $0.isHidden == false },
            sortBy: [SortDescriptor(\.fileCreatedAt, order: .reverse)]
        )
        let rows = (try? modelContext.fetch(descriptor)) ?? []
        return rows
            // Vor dem Umwandeln filtern, nicht danach: `toAsset()` über alle Zeilen zu
            // ziehen wäre bei 155 000 teuer. Die Entscheidung selbst trifft dieselbe
            // Fassung wie `MediaType.rawFiles.matches` — hier stand eine eigene Liste,
            // der `raw` fehlte, und der Originalpfad wurde gar nicht angesehen.
            .filter { MediaType.isRawFile(fileName: $0.originalFileName, path: $0.originalPath) }
            .map { $0.toAsset() }
    }
}
