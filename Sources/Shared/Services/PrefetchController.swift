import Foundation
import Nuke
import SwiftUI

/// Controls prefetching of thumbnail images ahead of the scroll position.
/// Uses Nuke's ImagePrefetcher for efficient request deduplication and cancellation.
@Observable
@MainActor
final class PrefetchController {
    private var prefetcher: ImagePrefetcher?
    private let pipeline: ImagePipeline
    private let apiClient: ImmichAPIClient
    private var visibleAssetIds = Set<String>()

    /// How many assets to prefetch ahead/behind the current viewport
    private let lookAheadCount = 80

    init(pipeline: ImagePipeline, apiClient: ImmichAPIClient) {
        self.pipeline = pipeline
        self.apiClient = apiClient
        // Nur auf die Platte, nicht in den Speicher-Cache: Seit Raster-Thumbnails
        // beim Laden fertig dekodiert werden (`ThumbnailVorDekodierer`), packte das
        // Vorladen aller Panoramen (~714) bei jedem Start und jedem Sync mit
        // Änderungen jedes einzelne aus — 1,5 s CPU, gemessen am 21.09.2026 (danach
        // 0–49 ms). Von der Platte dekodiert die Pipeline erst, was eine Kachel
        // anzeigt, und dann ebenfalls im Hintergrund.
        self.prefetcher = ImagePrefetcher(pipeline: pipeline, destination: .diskCache, maxConcurrentRequestCount: 8)
    }

    /// Called when a thumbnail cell appears in the viewport.
    /// Triggers look-ahead prefetching for nearby assets.
    func onAppear(assetId: String, index: Int, allAssets: [Asset]) {
        visibleAssetIds.insert(assetId)
        prefetchAround(index: index, allAssets: allAssets)
    }

    /// Called when a thumbnail cell disappears from the viewport
    func onDisappear(assetId: String) {
        visibleAssetIds.remove(assetId)
    }

    /// Prefetch thumbnails in a window around the given index
    private func prefetchAround(index: Int, allAssets: [Asset]) {
        let count = allAssets.count
        guard count > 0 else { return }

        let prefetchStart = max(0, index - lookAheadCount / 4)      // Small look-behind
        let prefetchEnd = min(count, index + lookAheadCount)        // Large look-ahead
        let slice = allAssets[prefetchStart..<prefetchEnd]
        let requests = slice.map {
            var req = ImageRequest(url: apiClient.thumbnailURL(assetId: $0.id))
            req.priority = .low  // Visible cells use default .normal and win
            return req
        }
        prefetcher?.startPrefetching(with: requests)
    }

    /// Cancel prefetching for assets that are no longer near the viewport
    func cancelPrefetch(assetIds: [String]) {
        let urls = assetIds.map { apiClient.thumbnailURL(assetId: $0) }
        prefetcher?.stopPrefetching(with: urls)
    }

    /// Stop all prefetching
    func stopAll() {
        prefetcher?.stopPrefetching()
    }

    // MARK: - Bulk Prefetch

    /// Kick off a one-shot prefetch of ALL thumbnails for a given asset list.
    /// Intended for small/bounded collections like panoramas or favorites.
    /// Requests are submitted at `.veryLow` priority so foreground scrolling always wins.
    func prefetchAll(_ assets: [Asset]) {
        guard !assets.isEmpty else { return }
        let requests = assets.map {
            var req = ImageRequest(url: apiClient.thumbnailURL(assetId: $0.id))
            req.priority = .veryLow
            return req
        }
        prefetcher?.startPrefetching(with: requests)
    }
}

// MARK: - Environment Key

private struct PrefetchControllerKey: EnvironmentKey {
    static let defaultValue: PrefetchController? = nil
}

extension EnvironmentValues {
    var prefetchController: PrefetchController? {
        get { self[PrefetchControllerKey.self] }
        set { self[PrefetchControllerKey.self] = newValue }
    }
}
