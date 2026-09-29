import Foundation
import SwiftData

/// Fotos aus Etappen, die als Albumvorschlag verworfen wurden.
///
/// Ohne diese Liste zeigt jeder Scan dieselben abgelehnten Vorschläge erneut — die
/// Auswahl in der Ansicht ist reiner View-State und hinterlässt keine Spur.
/// Vorbild und Form: `GeoIgnoredAsset`.
///
/// Der Schlüssel ist die **Asset-ID**, nicht der Fingerabdruck der Etappe. Der
/// Fingerabdruck wäre der naheliegende Schlüssel und ist der falsche: Er ändert
/// sich, sobald ein Foto hinzukommt oder wegfällt — und er ändert sich bei *jeder*
/// Reglerbewegung, weil ein anderer Radius andere Etappen ergibt. Eine verworfene
/// Etappe käme damit nach dem nächsten Sync zurück und wäre nach dem Verschieben
/// des Radius ohnehin wieder da.
///
/// Folge, die die Oberfläche benennen muss: Verwirft man eine Etappe und taucht
/// später ein *neues* Foto darin auf, wird sie erneut vorgeschlagen — dann aber zu
/// Recht, denn an diesem Ort ist etwas Neues passiert. Siehe die Begründung an
/// `TripSegmenter.segment(rows:parameters:ignoredAssetIds:)`.
@Model
final class TripIgnoredAsset {
    @Attribute(.unique) var assetId: String
    var ignoredAt: Date

    init(assetId: String, ignoredAt: Date = Date()) {
        self.assetId = assetId
        self.ignoredAt = ignoredAt
    }
}
