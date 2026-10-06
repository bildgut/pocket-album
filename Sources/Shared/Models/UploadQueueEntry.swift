import Foundation
import SwiftData

/// Persists a pending or failed upload so it survives app restarts.
/// Only file-based uploads (drag-drop, album sync) are persisted;
/// Apple Photos temp-exports are ephemeral and are NOT stored here.
@Model
final class UploadQueueEntry {
    /// Mirrors `UploadItem.id`
    @Attribute(.unique) var entryId: String
    var fileURLString: String
    var fileName: String
    var albumId: String?
    var sessionId: String
    var sessionLabel: String
    var retryCount: Int
    var createdAt: Date

    init(
        entryId: UUID,
        fileURL: URL,
        fileName: String,
        albumId: String?,
        sessionId: UUID,
        sessionLabel: String,
        retryCount: Int = 0
    ) {
        self.entryId = entryId.uuidString
        self.fileURLString = fileURL.absoluteString
        self.fileName = fileName
        self.albumId = albumId
        self.sessionId = sessionId.uuidString
        self.sessionLabel = sessionLabel
        self.retryCount = retryCount
        self.createdAt = Date()
    }

    var fileURL: URL { URL(string: fileURLString) ?? URL(fileURLWithPath: fileURLString) }
}
