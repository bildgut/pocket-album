import Foundation

/// Fills and refreshes ``AlbumMembershipStore`` from the server.
///
/// Membership is not part of any sync stream, so the only way to learn it is one
/// request per album. With a few hundred albums that is a minutes-long job — it runs
/// in the background, capped in concurrency, and records progress per album so an
/// interrupted run resumes instead of starting over.
actor AlbumMembershipIndexer {

    static let shared = AlbumMembershipIndexer()

    /// How many album fetches may be in flight at once. Kept low on purpose: a full
    /// fill is hundreds of requests and must not saturate the server or crowd out
    /// the regular sync traffic.
    private static let maxConcurrentFetches = 4

    private var isRunning = false

    /// Observable progress for the UI. `total == 0` means "no run in progress".
    @MainActor
    @Observable
    final class Progress {
        var total = 0
        var completed = 0
        var failed = 0
        var isRunning = false

        var fraction: Double {
            total > 0 ? Double(completed + failed) / Double(total) : 0
        }
    }

    @MainActor static let progress = Progress()

    /// Index the given albums, skipping those already up to date.
    ///
    /// Serialised: a second call while a run is in flight returns immediately rather
    /// than queueing, because the caller (the sync cycle) fires on a timer and would
    /// otherwise pile up runs behind a slow first fill.
    func refresh(albums: [Album], apiClient: ImmichAPIClient, store: AlbumMembershipStore = .shared) async {
        guard !isRunning else { return }

        let staleIds = Set(store.staleAlbumIds(against: albums))
        let pending = albums.filter { staleIds.contains($0.id) }
        guard !pending.isEmpty else { return }

        isRunning = true
        defer { isRunning = false }

        AppLogger.sync.info("AlbumIndex: refreshing \(pending.count) of \(albums.count) albums")
        await MainActor.run {
            Self.progress.total = pending.count
            Self.progress.completed = 0
            Self.progress.failed = 0
            Self.progress.isRunning = true
        }
        defer {
            Task { @MainActor in Self.progress.isRunning = false }
        }

        let started = Date()
        var completed = 0
        var failed = 0

        // Bounded task group with iterator top-up — same shape as AlbumSyncManager's
        // upload pump, so at most `maxConcurrentFetches` requests are ever in flight.
        await withTaskGroup(of: Bool.self) { group in
            var iterator = pending.makeIterator()

            func addTask(for album: Album) {
                group.addTask {
                    await Self.fill(album: album, apiClient: apiClient, store: store)
                }
            }

            for _ in 0..<Self.maxConcurrentFetches {
                guard let album = iterator.next() else { break }
                addTask(for: album)
            }

            while let ok = await group.next() {
                if ok { completed += 1 } else { failed += 1 }
                let done = completed
                let fail = failed
                await MainActor.run {
                    Self.progress.completed = done
                    Self.progress.failed = fail
                }

                if Task.isCancelled { break }
                if let album = iterator.next() {
                    addTask(for: album)
                }
            }
        }

        let elapsed = Date().timeIntervalSince(started)
        AppLogger.sync.info(
            "AlbumIndex: \(completed) albums indexed, \(failed) failed, \(String(format: "%.1f", elapsed))s"
        )
    }

    /// Fetch one album's asset IDs and store them. Returns false on failure — the album
    /// simply keeps its old state row (or none) and is retried on the next cycle.
    private static func fill(album: Album, apiClient: ImmichAPIClient, store: AlbumMembershipStore) async -> Bool {
        do {
            let assetIds = try await apiClient.getAlbumAssetIds(albumId: album.id)
            store.replaceMembership(
                albumId: album.id,
                assetIds: assetIds,
                updatedAt: album.updatedAt,
                assetCount: album.assetCount
            )
            return true
        } catch is CancellationError {
            return false
        } catch {
            AppLogger.sync.warning("AlbumIndex: failed to index album \(album.id): \(error)")
            return false
        }
    }
}
