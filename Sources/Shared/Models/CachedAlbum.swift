import Foundation
import SwiftData

@Model
final class CachedAlbum {
    #Index<CachedAlbum>([\.albumId])

    @Attribute(.unique) var albumId: String
    var albumName: String
    var albumDescription: String?
    var assetCount: Int
    var createdAt: String
    var updatedAt: String
    var startDate: String?
    var endDate: String?
    var thumbnailAssetId: String?
    var isShared: Bool = false
    var isMarkedForOffline: Bool = false
    var assetIds: [String] = []

    init(from album: Album) {
        self.albumId = album.id
        self.albumName = album.albumName
        self.albumDescription = album.description
        self.assetCount = album.assetCount
        self.createdAt = album.createdAt
        self.updatedAt = album.updatedAt
        self.startDate = album.startDate
        self.endDate = album.endDate
        self.thumbnailAssetId = album.albumThumbnailAssetId
        self.isShared = album.isShared
    }

    /// Update from a server album. Returns true if any field actually changed.
    @discardableResult
    func update(from album: Album) -> Bool {
        var changed = false
        if self.albumName != album.albumName { self.albumName = album.albumName; changed = true }
        if self.albumDescription != album.description { self.albumDescription = album.description; changed = true }
        if self.assetCount != album.assetCount { self.assetCount = album.assetCount; changed = true }
        if self.updatedAt != album.updatedAt { self.updatedAt = album.updatedAt; changed = true }
        if self.startDate != album.startDate { self.startDate = album.startDate; changed = true }
        if self.endDate != album.endDate { self.endDate = album.endDate; changed = true }
        if self.thumbnailAssetId != album.albumThumbnailAssetId { self.thumbnailAssetId = album.albumThumbnailAssetId; changed = true }
        return changed
    }

    func toAlbum() -> Album {
        Album(
            id: albumId,
            albumName: albumName,
            description: albumDescription,
            createdAt: createdAt,
            updatedAt: updatedAt,
            startDate: startDate,
            endDate: endDate,
            assetCount: assetCount,
            albumThumbnailAssetId: thumbnailAssetId,
            shared: isShared,
            hasSharedLink: nil,
            owner: nil
        )
    }
}
