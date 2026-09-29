import Foundation

struct AlbumOwner: Codable, Hashable, Sendable {
    let id: String
    let name: String?
}

struct Album: Codable, Identifiable, Hashable, Sendable {
    let id: String
    let albumName: String
    let description: String?
    let createdAt: String
    let updatedAt: String
    let startDate: String?
    let endDate: String?
    let assetCount: Int
    let albumThumbnailAssetId: String?
    let shared: Bool?
    let hasSharedLink: Bool?
    let owner: AlbumOwner?

    /// Computed: true if the album is shared (with users or via link)
    var isShared: Bool {
        (shared ?? false) || (hasSharedLink ?? false)
    }

    enum CodingKeys: String, CodingKey {
        case id, albumName, description, createdAt, updatedAt, startDate, endDate, assetCount, albumThumbnailAssetId, shared, isShared, hasSharedLink, owner
    }

    init(id: String, albumName: String, description: String?, createdAt: String, updatedAt: String, startDate: String?, endDate: String?, assetCount: Int, albumThumbnailAssetId: String?, shared: Bool?, hasSharedLink: Bool?, owner: AlbumOwner?) {
        self.id = id
        self.albumName = albumName
        self.description = description
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.startDate = startDate
        self.endDate = endDate
        self.assetCount = assetCount
        self.albumThumbnailAssetId = albumThumbnailAssetId
        self.shared = shared
        self.hasSharedLink = hasSharedLink
        self.owner = owner
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        albumName = try container.decode(String.self, forKey: .albumName)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        createdAt = try container.decode(String.self, forKey: .createdAt)
        updatedAt = try container.decode(String.self, forKey: .updatedAt)
        startDate = try container.decodeIfPresent(String.self, forKey: .startDate)
        endDate = try container.decodeIfPresent(String.self, forKey: .endDate)
        assetCount = try container.decode(Int.self, forKey: .assetCount)
        albumThumbnailAssetId = try container.decodeIfPresent(String.self, forKey: .albumThumbnailAssetId)
        
        let sharedVal = try container.decodeIfPresent(Bool.self, forKey: .shared)
        let isSharedVal = try container.decodeIfPresent(Bool.self, forKey: .isShared)
        shared = isSharedVal ?? sharedVal
        
        hasSharedLink = try container.decodeIfPresent(Bool.self, forKey: .hasSharedLink)
        owner = try container.decodeIfPresent(AlbumOwner.self, forKey: .owner)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(albumName, forKey: .albumName)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(startDate, forKey: .startDate)
        try container.encodeIfPresent(endDate, forKey: .endDate)
        try container.encode(assetCount, forKey: .assetCount)
        try container.encodeIfPresent(albumThumbnailAssetId, forKey: .albumThumbnailAssetId)
        try container.encodeIfPresent(shared, forKey: .shared)
        try container.encodeIfPresent(hasSharedLink, forKey: .hasSharedLink)
        try container.encodeIfPresent(owner, forKey: .owner)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: Album, rhs: Album) -> Bool {
        lhs.id == rhs.id
    }
}

struct AlbumDetail: Codable, Identifiable, Sendable {
    let id: String
    let albumName: String
    let description: String?
    let assetCount: Int
    var assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case id, albumName, description, assetCount, assets
    }

    init(id: String, albumName: String, description: String?, assetCount: Int, assets: [Asset]) {
        self.id = id
        self.albumName = albumName
        self.description = description
        self.assetCount = assetCount
        self.assets = assets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        albumName = try container.decode(String.self, forKey: .albumName)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        assetCount = try container.decode(Int.self, forKey: .assetCount)
        assets = (try? container.decode([Asset].self, forKey: .assets)) ?? []
    }
}
