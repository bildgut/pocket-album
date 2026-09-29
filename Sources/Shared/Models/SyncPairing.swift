import Foundation
import SwiftData

/// Persisted pairing: an Apple Photos album linked to an Immich album.
/// The sync engine uses this to know which albums belong together.
@Model
final class SyncPairing {
    @Attribute(.unique) var id: String

    // Apple side
    var appleAlbumLocalIdentifier: String
    var appleAlbumName: String

    // Immich side
    var immichAlbumId: String
    var immichAlbumName: String

    // Sync metadata
    var lastSyncedAt: Date?
    var lastSyncedUploaded: Int
    var lastSyncedMapped: Int
    var lastSyncedSkipped: Int

    init(
        id: String = UUID().uuidString,
        appleAlbumLocalIdentifier: String,
        appleAlbumName: String,
        immichAlbumId: String,
        immichAlbumName: String
    ) {
        self.id = id
        self.appleAlbumLocalIdentifier = appleAlbumLocalIdentifier
        self.appleAlbumName = appleAlbumName
        self.immichAlbumId = immichAlbumId
        self.immichAlbumName = immichAlbumName
        self.lastSyncedAt = nil
        self.lastSyncedUploaded = 0
        self.lastSyncedMapped = 0
        self.lastSyncedSkipped = 0
    }

    var lastSyncSummary: String {
        guard let date = lastSyncedAt else { return "Noch nie synchronisiert" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.unitsStyle = .full
        let rel = formatter.localizedString(for: date, relativeTo: .now)
        let total = lastSyncedUploaded + lastSyncedMapped + lastSyncedSkipped
        return "\(rel) \u{00B7} \(total) Assets"
    }
}
