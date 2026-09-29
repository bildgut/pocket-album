import Foundation
import SwiftData
import os

@Observable
@MainActor
final class AssetRepository {
    // MARK: - Published State
    var cachedAssets: [Asset] = []
    var favoriteAssets: [Asset] = []
    var videoAssets: [Asset] = []
    var panoramaAssets: [Asset] = []
    
    var totalCount = 0
    private(set) var hasMore = true
    private(set) var forceRefreshTrigger = UUID()
    /// Wechselt nur, wenn sich der **Bestand** geändert hat — nicht, wenn bloß eine
    /// weitere Seite des immer gleichen Bestands nachgeladen wurde.
    ///
    /// `forceRefreshTrigger` kann beides nicht unterscheiden: `loadNextLocalPage`
    /// setzt ihn beim Scrollen genauso neu wie ein Sync mit echten Änderungen. Die
    /// Rasteransicht stört das nicht, für `SmartAlbumDetailView` war es fatal — sie
    /// verwarf daran ihren Tiefenscan, und beim Scrollen kam der nie zum Abschluss.
    private(set) var inventoryVersion = UUID()
    
    private(set) var favoritesSubtitle: String = ""
    private(set) var librarySubtitle: String = ""

    // MARK: - Internal State
    private let apiClient: ImmichAPIClient
    private var modelContext: ModelContext?
    /// Injizierbar, damit `AssetRepositoryLocalPagingTests` einen isolierten Index
    /// übergeben können — dieselbe Begründung wie bei `GridIndexStore(path:defaults:)`
    /// und `ExifRepairModel`. Die App nutzt durchweg die Vorgabe.
    private let gridIndex: GridIndexStore
    
    private let localPageSize = 4_000
    let localPreloadThreshold = 300
    private let largeDeltaThreshold = 2_000
    
    private(set) var localOffset = 0
    private(set) var localVisibleTotal = 0
    private(set) var isLocalPagingEnabled = false
    private var isLoadingLocalPage = false

    /// Raw API fallback pagination state
    var currentPage = 1
    var apiAssets: [Asset] = []

    init(apiClient: ImmichAPIClient, gridIndex: GridIndexStore = .shared) {
        self.apiClient = apiClient
        self.gridIndex = gridIndex
    }
    
    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
    }
    
    var hasCachedData: Bool {
        !cachedAssets.isEmpty || fetchCachedAssetCount() > 0
    }

    func fetchCachedAssetCount() -> Int {
        guard let modelContext else { return 0 }
        let descriptor = FetchDescriptor<CachedAsset>()
        return (try? modelContext.fetchCount(descriptor)) ?? 0
    }

    // MARK: - Loading
    
    func loadAssetsFromCache() {
        let signpostID = OSSignpostID(log: AppLogger.dataPerf)
        os_signpost(.begin, log: AppLogger.dataPerf, name: "LoadAssetsFromCache", signpostID: signpostID)

        // Fast path: load first page from grid index and paginate on demand.
        localVisibleTotal = gridIndex.countVisible()
        if localVisibleTotal > 0 {
            let firstPage = gridIndex.loadVisiblePage(offset: 0, limit: localPageSize)
            localOffset = firstPage.count
            isLocalPagingEnabled = true
            isLoadingLocalPage = false
            hasMore = localOffset < localVisibleTotal
            self.cachedAssets = firstPage
            self.totalCount = localVisibleTotal
            
            // Seed panoramaAssets directly from SQLite
            let sqlitePanoramas = gridIndex.loadPanoramas()
            self.panoramaAssets = sqlitePanoramas
            
            self.recomputeDerivedArrays()
            os_signpost(.end, log: AppLogger.dataPerf, name: "LoadAssetsFromCache", signpostID: signpostID,
                        "%d/%d assets from grid index", firstPage.count, localVisibleTotal)
            return
        }

        // Slow path: SwiftData fallback
        guard let modelContext else {
            hasMore = false
            isLocalPagingEnabled = false
            os_signpost(.end, log: AppLogger.dataPerf, name: "LoadAssetsFromCache", signpostID: signpostID, "no context")
            return
        }
        let container = modelContext.container

        Task.detached(priority: .userInitiated) {
            let bgContext = ModelContext(container)
            bgContext.autosaveEnabled = false

            let firstBatchSize = 1_000
            let batchSize = 10_000
            var offset = 0
            var allAssets: [Asset] = []
            allAssets.reserveCapacity(100_000)
            var isFirstBatch = true
            var allCached: [CachedAsset] = []

            while true {
                var descriptor = FetchDescriptor<CachedAsset>(
                    predicate: #Predicate<CachedAsset> { $0.isTrashed == false && $0.isArchived == false && $0.isHidden == false },
                    sortBy: [SortDescriptor(\.fileCreatedAt, order: .reverse)]
                )
                descriptor.fetchLimit = isFirstBatch ? firstBatchSize : batchSize
                descriptor.fetchOffset = offset

                guard let batch = try? bgContext.fetch(descriptor), !batch.isEmpty else { break }

                let mapped = batch.map { $0.toAsset() }
                allAssets.append(contentsOf: mapped)
                allCached.append(contentsOf: batch)
                offset += batch.count

                let isDone = batch.count < (isFirstBatch ? firstBatchSize : batchSize)

                if isFirstBatch || isDone {
                    let snapshot = allAssets

                    await MainActor.run {
                        self.cachedAssets = snapshot
                        self.totalCount = snapshot.count
                        self.localOffset = snapshot.count
                        self.localVisibleTotal = snapshot.count
                        self.hasMore = false
                        self.isLocalPagingEnabled = false
                        self.recomputeDerivedArrays()
                    }
                    isFirstBatch = false
                }

                if isDone { break }
            }

            if !allCached.isEmpty {
                self.gridIndex.upsertFromCache(allCached)
            }

            os_signpost(.end, log: AppLogger.dataPerf, name: "LoadAssetsFromCache", signpostID: signpostID,
                        "%d assets from SwiftData", allAssets.count)
        }
    }

    func loadNextLocalPage() async {
        guard isLocalPagingEnabled, hasMore, !isLoadingLocalPage else { return }
        isLoadingLocalPage = true

        let offset = localOffset
        let pageSize = localPageSize

        let nextPage = await Task.detached(priority: .userInitiated) { [gridIndex] in
            gridIndex.loadVisiblePage(offset: offset, limit: pageSize)
        }.value

        defer {
            isLoadingLocalPage = false
            hasMore = isLocalPagingEnabled && localOffset < localVisibleTotal
        }

        guard !nextPage.isEmpty else {
            // Eine leere Seite heißt entweder „am Ende" oder „Lesefehler" —
            // `loadVisiblePage` gibt in beiden Fällen `[]` zurück und taugt allein
            // nicht als Endsignal.
            //
            // Nötig ist die Korrektur, weil `localVisibleTotal` planmäßig zu hoch
            // driftet: Beim Entfernen wird er nur um die Löschungen im **geladenen**
            // Teil verringert (`applyDeletions`), alles dahinter bleibt mitgezählt.
            // Ohne Nachzählen bliebe `hasMore` dauerhaft wahr, und die Ansicht
            // fragte bis in alle Ewigkeit nach einer Seite, die nicht kommt.
            //
            // Also neu erheben statt raten: Kommt eine Zahl, ist sie maßgeblich.
            // Kommt keine, war es ein Lesefehler — dann bleibt alles stehen und der
            // nächste Versuch zählt erneut.
            if let ist = gridIndex.countVisibleChecked() {
                localVisibleTotal = ist
                totalCount = ist
            }
            return
        }
        localOffset += nextPage.count
        cachedAssets.append(contentsOf: nextPage)
        // `favoriteAssets` und `videoAssets` werden hier **nicht** ergänzt: Sie
        // stehen bereits vollständig da. `recomputeDerivedArrays` holt sie über
        // `loadDerivedCollections` in einem Zug aus SQLite, ungefenstert — und
        // dieser Pfad läuft nur bei eingeschaltetem lokalem Paging, das wiederum
        // nur gesetzt wird, wenn der Index Zeilen hat, also genau dann, wenn
        // `recomputeDerivedArrays` den SQLite-Zweig genommen hat.
        //
        // Das Anhängen war deshalb immer doppelt: Ab Seite 2 stand jede
        // favorisierte Aufnahme zweimal in der Liste, jedes Video ebenso, und
        // `MainView` reicht diese Arrays unverändert als `GridDataSource` weiter.
        // Ein Rest aus einer früheren Fassung, in der die abgeleiteten Listen nur
        // aus den geladenen Seiten gebaut wurden.
        //
        // `panoramaAssets` wird aus demselben Grund schon immer nur gesetzt, nie
        // ergänzt.
        forceRefreshTrigger = UUID()
    }

    // MARK: - API Fallback
    func loadFromAPI() async throws {
        apiAssets = []
        currentPage = 1
        hasMore = true

        let page = try await apiClient.searchAssets(page: currentPage, size: 200)
        apiAssets = page.items ?? []
        cachedAssets = apiAssets
        isLocalPagingEnabled = false
        localOffset = apiAssets.count
        localVisibleTotal = page.total ?? apiAssets.count
        recomputeDerivedArrays()
        totalCount = localVisibleTotal
        hasMore = page.nextPage != nil && !(page.nextPage?.isEmpty ?? true)
    }

    func loadNextPageFromAPI() async throws {
        guard hasMore else { return }
        currentPage += 1

        let page = try await apiClient.searchAssets(page: currentPage, size: 200)
        let items = page.items ?? []
        apiAssets.append(contentsOf: items)
        cachedAssets = apiAssets
        totalCount = page.total ?? apiAssets.count
        if page.nextPage == nil || page.nextPage?.isEmpty == true {
            hasMore = false
        }
    }

    // MARK: - Derived State

    /// Shared formatter — DateFormatter is expensive to allocate; creating one per
    /// recomputeDerivedArrays() call (which fires 10+ times per sync) was wasteful.
    nonisolated private static let monthRangeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "MMM yyyy"
        return f
    }()

    /// In-flight task for background derived-state computation.
    /// Cancelled and replaced on each call so rapid back-to-back mutations
    /// only cause a single final recompute (debounce).
    private var derivedStateTask: Task<Void, Never>?

    func recomputeDerivedArrays() {
        // Cancel any pending recompute — only the last one matters.
        derivedStateTask?.cancel()
        // Capture what we need before going off-main.
        let snapshot = cachedAssets

        derivedStateTask = Task {
            // Run all SQLite queries off the main thread in a single readQueue lock.
            let result = await Task.detached(priority: .userInitiated) { [gridIndex] () -> (favs: [Asset], vids: [Asset], libSub: String, favSub: String) in
                if gridIndex.countVisible() > 0 {
                    // One readQueue.sync round-trip instead of five separate ones.
                    let derived = gridIndex.loadDerivedCollections()
                    let libSub = Self.buildSubtitle(from: derived.libStats)
                    let favSub = Self.buildSubtitle(from: derived.favStats)
                    return (derived.favorites, derived.videos, libSub, favSub)
                } else {
                    let favs = snapshot.filter { $0.isFavorite }
                    let vids = snapshot.filter { $0.isVideo }
                    return (favs, vids, "", "")
                }
            }.value

            guard !Task.isCancelled else { return }

            self.favoriteAssets    = result.favs
            self.videoAssets       = result.vids
            self.librarySubtitle   = result.libSub
            self.favoritesSubtitle = result.favSub
            self.forceRefreshTrigger = UUID()
            self.inventoryVersion = UUID()
        }
    }

    nonisolated private static func buildSubtitle(from stats: (images: Int, videos: Int, earliest: String?, latest: String?)) -> String {
        var parts: [String] = []
        if stats.images > 0 {
            let label = stats.images == 1 ? "Foto" : "Fotos"
            parts.append("\(stats.images.formatted()) \(label)")
        }
        if stats.videos > 0 {
            let label = stats.videos == 1 ? "Video" : "Videos"
            parts.append("\(stats.videos.formatted()) \(label)")
        }

        var subtitle = parts.joined(separator: ", ")

        if let earliestStr  = stats.earliest,
           let latestStr    = stats.latest,
           let earliestDate = Asset.createdDate(from: earliestStr),
           let latestDate   = Asset.createdDate(from: latestStr) {
            let start = monthRangeFormatter.string(from: earliestDate)
            let end   = monthRangeFormatter.string(from: latestDate)
            let range = start == end ? start : "\(start) – \(end)"
            if !subtitle.isEmpty { subtitle += " · " }
            subtitle += range
        }

        return subtitle
    }

    // MARK: - Mutations
    
    func insertUploadedAsset(_ asset: Asset) {
        if let modelContext {
            let cached = CachedAsset(from: asset)
            modelContext.insert(cached)
            try? modelContext.save()
        }

        // Keep the SQLite grid index in sync so the asset survives the next
        // loadAssetsFromCache() call (which reads from GridIndexStore, not SwiftData).
        // Without this the asset disappears the moment a background sync or
        // foreground transition triggers a cache reload.
        gridIndex.upsert([asset])

        guard !cachedAssets.contains(where: { $0.id == asset.id }) else { return }

        let insertIdx: Int
        if let idx = cachedAssets.firstIndex(where: { $0.fileCreatedAt <= asset.fileCreatedAt }) {
            insertIdx = idx
        } else {
            insertIdx = cachedAssets.endIndex
        }
        cachedAssets.insert(asset, at: insertIdx)

        if isLocalPagingEnabled {
            localVisibleTotal += 1
            localOffset += 1
            totalCount = localVisibleTotal
        } else {
            totalCount = cachedAssets.count
        }
        recomputeDerivedArrays()
    }

    func removeAssets(ids: [String]) {
        if ids.isEmpty {
            loadAssetsFromCache()
        } else {
            let idSet = Set(ids)
            let beforeCount = cachedAssets.count
            cachedAssets.removeAll { idSet.contains($0.id) }
            let removedLoadedCount = beforeCount - cachedAssets.count
            if isLocalPagingEnabled {
                localVisibleTotal = max(0, localVisibleTotal - removedLoadedCount)
                localOffset = max(cachedAssets.count, localOffset - removedLoadedCount)
                totalCount = localVisibleTotal
                hasMore = localOffset < localVisibleTotal
            } else {
                totalCount = cachedAssets.count
            }
            recomputeDerivedArrays()

            if let modelContext {
                // Single batch fetch instead of N individual fetches.
                // For large multi-select deletes this is orders of magnitude faster.
                let idSet2 = idSet  // local copy for Predicate capture
                let descriptor = FetchDescriptor<CachedAsset>(
                    predicate: #Predicate { idSet2.contains($0.assetId) }
                )
                if let matches = try? modelContext.fetch(descriptor) {
                    for cached in matches { cached.isTrashed = true }
                    try? modelContext.save()
                }

                let container = modelContext.container
                Task.detached(priority: .background) {
                    await LocalFileCacheManager.shared.evict(ids: ids, container: container)
                }
            }
        }
    }

    func restoreAssets(ids: [String]) {
        guard let modelContext else { return }
        // Single batch fetch instead of N individual fetches (same pattern as removeAssets)
        let idSet = Set(ids)
        let descriptor = FetchDescriptor<CachedAsset>(
            predicate: #Predicate { idSet.contains($0.assetId) }
        )
        if let matches = try? modelContext.fetch(descriptor) {
            for cached in matches { cached.isTrashed = false }
        }
        try? modelContext.save()
        // The grid index is the primary read path for the timeline — without
        // clearing the flag here, restored assets stay invisible until the next
        // full reconciliation heals them.
        gridIndex.unmarkTrashed(ids: ids)
        loadAssetsFromCache()
    }

    func applySyncChanges(ids: [String]) async {
        guard !ids.isEmpty else { return }

        let changedIDs = Array(Set(ids))
        let loadedSnapshot = cachedAssets
        let loadedWindowSize = loadedSnapshot.count
        let tailDate = loadedSnapshot.last?.fileCreatedAt
        let pageSizeForLargeDelta = localPageSize

        if changedIDs.count >= largeDeltaThreshold {
            let refreshed = await Task.detached(priority: .userInitiated) { [gridIndex] in
                let visibleTotal = gridIndex.countVisible()
                let pageSize = max(loadedWindowSize, pageSizeForLargeDelta)
                let window = gridIndex.loadVisiblePage(offset: 0, limit: pageSize)
                return (window, visibleTotal)
            }.value

            cachedAssets = refreshed.0
            totalCount = max(refreshed.1, cachedAssets.count)
            localVisibleTotal = totalCount
            localOffset = cachedAssets.count
            hasMore = isLocalPagingEnabled && localOffset < localVisibleTotal
            recomputeDerivedArrays()
            return // We let LibraryViewModel clear the MediaTypeCache
        }

        let delta = await Task.detached(priority: .userInitiated) { [gridIndex] in
            let visibleChanged = gridIndex.loadVisible(ids: changedIDs)
            let visibleMap = Dictionary(uniqueKeysWithValues: visibleChanged.map { ($0.id, $0) })
            let visibleTotal = gridIndex.countVisible()
            return (visibleMap, visibleTotal)
        }.value

        var nextAssets = loadedSnapshot
        let indexByID = Dictionary(uniqueKeysWithValues: nextAssets.enumerated().map { ($1.id, $0) })
        var requiresReorder = false
        // Entfernen und Anhängen werden gesammelt statt sofort ausgeführt: Ein
        // `remove(at:)` mitten in der Schleife verschiebt alle folgenden Indizes,
        // weshalb hier früher pro geänderter ID das komplette Dictionary neu
        // gebaut wurde. Bei 150k geladenen Assets und einem Delta knapp unter
        // `largeDeltaThreshold` sind das dreistellige Millionen Asset-Kopien auf
        // dem Main Thread — ein laufender Apple-Fotos-Voll-Sync hat die App damit
        // praktisch zum Stillstand gebracht, weil jeder Upload als Sync-Änderung
        // zurückkam. Die Offsets beziehen sich durchgehend auf `loadedSnapshot`.
        var removedOffsets = Set<Int>()
        var appended: [Asset] = []

        for id in changedIDs {
            if let updated = delta.0[id] {
                if let index = indexByID[id] {
                    if nextAssets[index].fileCreatedAt != updated.fileCreatedAt {
                        removedOffsets.insert(index)
                        requiresReorder = true
                    } else {
                        nextAssets[index] = updated
                        continue
                    }
                } else if let tailDate, updated.fileCreatedAt < tailDate {
                    continue
                } else {
                    requiresReorder = true
                }
                appended.append(updated)
            } else if let index = indexByID[id] {
                removedOffsets.insert(index)
                requiresReorder = true
            }
        }

        if !removedOffsets.isEmpty {
            var kept: [Asset] = []
            kept.reserveCapacity(nextAssets.count - removedOffsets.count)
            for (offset, asset) in nextAssets.enumerated() where !removedOffsets.contains(offset) {
                kept.append(asset)
            }
            nextAssets = kept
        }
        // Jedes Anhängen setzt `requiresReorder`, die Sortierung unten stellt die
        // ursprüngliche Reihenfolge also unabhängig vom Einfügezeitpunkt her.
        nextAssets.append(contentsOf: appended)

        if requiresReorder {
            nextAssets.sort { $0.fileCreatedAt > $1.fileCreatedAt }
        }

        if isLocalPagingEnabled {
            let difference = nextAssets.count - loadedWindowSize
            localOffset = max(nextAssets.count, localOffset + difference)
        }

        cachedAssets = nextAssets
        totalCount = max(delta.1, cachedAssets.count)
        localVisibleTotal = totalCount
        hasMore = isLocalPagingEnabled && localOffset < localVisibleTotal
        recomputeDerivedArrays()
    }
}
