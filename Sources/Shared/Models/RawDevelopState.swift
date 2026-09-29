import Foundation
import SwiftData

/// Der zuletzt gespeicherte Entwicklungsstand eines RAW-Assets.
///
/// Ein Eintrag pro RAW-Original (`assetId`), nicht pro Sitzung — wer ein Bild ein
/// zweites Mal öffnet, soll dort weitermachen, wo er aufgehört hat. `paramsJSON` statt
/// eingebetteter Felder, damit ``RawDevelopParams`` sich weiterentwickeln kann, ohne
/// dass jede Änderung eine neue Schema-Stufe braucht (vgl. `SmartAlbum.rulesData`).
@Model
final class RawDevelopState {
    @Attribute(.unique) var assetId: String
    var paramsJSON: String
    /// Die hochgeladene HEIC-Ableitung — `nil`, bis zum ersten Export.
    var developedAssetId: String?
    var updatedAt: Date

    init(
        assetId: String,
        paramsJSON: String,
        developedAssetId: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.assetId = assetId
        self.paramsJSON = paramsJSON
        self.developedAssetId = developedAssetId
        self.updatedAt = updatedAt
    }
}
