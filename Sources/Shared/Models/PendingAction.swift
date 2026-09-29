import Foundation
import SwiftData

/// Persisted record of a write operation that couldn't reach the server.
/// Replayed in FIFO order when connectivity returns.
@Model
final class PendingAction {
    var id: String = UUID().uuidString
    var actionType: String      // "favorite", "unfavorite", "archive", "unarchive", "delete"
    var assetIds: [String]
    var createdAt: Date
    var status: String          // "pending", "syncing", "failed", "completed"
    var retryCount: Int = 0
    var lastError: String?

    init(actionType: String, assetIds: [String]) {
        self.id = UUID().uuidString
        self.actionType = actionType
        self.assetIds = assetIds
        self.createdAt = Date()
        self.status = "pending"
    }
}

extension PendingAction {
    /// Deutsches Anzeige-Label für den Aktionstyp.
    var displayLabel: String {
        switch actionType {
        case "favorite": return "Favorisieren"
        case "unfavorite": return "Favorit entfernen"
        case "archive": return "Archivieren"
        case "unarchive": return "Archivierung aufheben"
        case "delete": return "Löschen"
        default: return actionType
        }
    }
}
