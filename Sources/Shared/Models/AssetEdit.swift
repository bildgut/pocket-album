import Foundation
import SwiftData

/// SwiftData persisted asset edit — der Vermerk „dieses Asset trägt eine Bearbeitung".
///
/// Eine Zeile je Server-Bearbeitung (`id` = Edit-ID, aus dem Sync-Stream
/// `AssetEditsV1`, siehe `applySyncEditResults`) plus der Überbrückungsvermerk des
/// eigenen Drehens (`id` = `local-<assetId>`, `ImageDetailActions`). Gelesen beim
/// Start: `LibraryViewModel` füllt daraus `EditedAssetsStore`. Die Wertfelder sind ein
/// Überbleibsel eines früheren, nie passenden Formats und bleiben leer (außer
/// `rotation` beim eigenen Drehen); das Modell steht so im Schema.
@Model
final class CachedAssetEdit {
    @Attribute(.unique) var id: String
    var assetId: String
    var brightness: Double?
    var contrast: Double?
    var saturation: Double?
    var rotation: Double?
    var syncedAt: Date

    init(id: String, assetId: String, brightness: Double?, contrast: Double?,
         saturation: Double?, rotation: Double?, syncedAt: Date = .now) {
        self.id = id
        self.assetId = assetId
        self.brightness = brightness
        self.contrast = contrast
        self.saturation = saturation
        self.rotation = rotation
        self.syncedAt = syncedAt
    }
}
