import Foundation
import SwiftData

/// Lokaler Ordner zum Gruppieren von Smart Alben in der Sidebar.
/// Wird ausschliesslich lokal gespeichert (kein Server-Sync).
@Model
final class SmartAlbumFolder {

    @Attribute(.unique) var id: UUID
    var name: String
    var sortIndex: Int   // Reihenfolge der Ordner untereinander
    var createdAt: Date

    init(id: UUID = UUID(), name: String, sortIndex: Int = 0) {
        self.id = id
        self.name = name
        self.sortIndex = sortIndex
        self.createdAt = Date()
    }
}
