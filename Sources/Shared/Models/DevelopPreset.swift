import Foundation
import SwiftData

/// Ein benanntes, wiederverwendbares Set von ``RawDevelopParams``.
///
/// `sortIndex` bestimmt die Anzeigereihenfolge in der Preset-Liste (nutzergesteuert,
/// nicht alphabetisch) — dasselbe Muster wie `SmartAlbum.sortIndex`.
@Model
final class DevelopPreset {
    @Attribute(.unique) var id: UUID
    var name: String
    var paramsJSON: String
    var createdAt: Date
    var sortIndex: Int

    init(
        id: UUID = UUID(),
        name: String,
        paramsJSON: String,
        createdAt: Date = Date(),
        sortIndex: Int = 0
    ) {
        self.id = id
        self.name = name
        self.paramsJSON = paramsJSON
        self.createdAt = createdAt
        self.sortIndex = sortIndex
    }
}
