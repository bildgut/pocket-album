import Foundation
import SwiftData

/// Legt die Rasterkacheln aller offline gehaltenen Fotos in Nukes Disk-Cache.
///
/// Der ``OfflineDownloadManager`` lädt Originale und Vorschauen, aber keine
/// Thumbnails — und `PhoneGridTile` zeichnet nur das Server-Thumbnail. Offline
/// blieben deshalb alle Kacheln leer, die man online nie gesehen hatte, obwohl die
/// Datei auf dem Gerät lag (Gerätebefund 26.10.2026, Fotos-Reiter im Flugmodus).
/// Dieselbe URL wie in der Kachel, also derselbe Cache-Schlüssel; schon gecachte
/// liest Nuke von der Platte, statt sie neu zu laden.
@MainActor
final class PhoneOfflineThumbnailWaermer {
    private var prefetcher: PhoneCoverPrefetcher?

    func waerme(connection: ConnectionManager, container: ModelContainer) {
        prefetcher?.stop()
        guard connection.state.isConnected,
              let client = connection.apiClient,
              let pipeline = connection.imagePipeline else {
            prefetcher = nil
            return
        }
        let pins = OfflinePinStore.allPins(in: ModelContext(container))
        let urls = Self.urls(assetIds: pins.map(\.assetIds)) {
            client.thumbnailURL(assetId: $0, size: .thumbnail)
        }
        guard !urls.isEmpty else { return }
        let neu = PhoneCoverPrefetcher(pipeline: pipeline)
        prefetcher = neu
        neu.warm(urls)
        AppLogger.cache.info("Offline-Thumbnails vorgewärmt: \(urls.count, privacy: .public)")
    }

    /// Ein Foto kann in mehreren Vermerken stehen (Favorit und „Letzte Tage“) —
    /// je URL einmal, in der Reihenfolge der Vermerke.
    nonisolated static func urls(assetIds: [[String]], url: (String) -> URL) -> [URL] {
        var gesehen = Set<String>()
        return assetIds.joined().filter { gesehen.insert($0).inserted }.map(url)
    }
}
