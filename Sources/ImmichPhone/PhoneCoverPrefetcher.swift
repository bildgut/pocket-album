import Foundation
import Nuke

/// Wärmt die Titelbilder aller Alben in den Nuke-Disk-Cache — nicht nur die
/// sichtbaren. Das ist der Unterschied zwischen „Liste da, Kacheln grau" und
/// „sieht fertig aus", und die Voraussetzung dafür, dass die Übersicht auch
/// offline vollständig aussieht.
///
/// Kein `PrefetchController` aus `Sources/Shared` (`PrefetchController.swift`):
/// Der erwartet `[Asset]`, um daraus selbst Thumbnail-URLs zu bauen — auf dem
/// Telefon gibt es ohne Asset-Index in dieser Aufgabe keine `[Asset]`, nur die
/// fertigen `albumThumbnailAssetId`s aus `AlbumManager.albums` /
/// `.sharedAlbums`. Deshalb hier der einfachere, URL-basierte Vorwärmer:
/// `PhoneRootView` baut die URLs selbst (`apiClient.thumbnailURL(assetId:size:)`)
/// und übergibt nur noch fertige `URL`s.
@MainActor
final class PhoneCoverPrefetcher {
    private let prefetcher: ImagePrefetcher

    /// `destination: .diskCache` statt des Standards `.memoryCache`: Ziel ist,
    /// dass die Bilder auch nach einem App-Neustart (Speicher-Cache leer) noch
    /// da sind, nicht nur für die laufende Sitzung. `priority = .low`, damit
    /// dieser Hintergrund-Vorwärmer das Nachladen sichtbarer Kacheln (deren
    /// `LazyImage`-Anfragen mit der Standardpriorität `.normal` laufen) nicht
    /// verdrängt — dieselbe Überlegung wie beim Mac-Vorbild
    /// `PrefetchController.prefetchAll` (`.veryLow` dort für denselben Zweck).
    init(pipeline: ImagePipeline) {
        prefetcher = ImagePrefetcher(pipeline: pipeline, destination: .diskCache)
        prefetcher.priority = .low
    }

    func warm(_ urls: [URL]) {
        prefetcher.startPrefetching(with: urls)
    }

    func stop() {
        prefetcher.stopPrefetching()
    }
}
