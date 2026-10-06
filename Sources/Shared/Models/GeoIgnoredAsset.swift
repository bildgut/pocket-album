import Foundation
import SwiftData

enum GeoIgnoreReason: String, Sendable {
    /// Ein einzelner Vorschlag wurde abgelehnt.
    case rejected
    /// Das Foto gehörte zu einer Session, die als Ganzes verworfen wurde.
    case clusterDismissed
}

/// Fotos, für die der GPS-Abgleich dauerhaft keine Koordinaten mehr vorschlägt.
///
/// Ohne diese Liste zeigt jeder Durchlauf dieselben abgelehnten Vorschläge erneut —
/// die Auswahl in der Ansicht ist reiner View-State, und ein abgelehnter Vorschlag
/// hinterlässt sonst keine Spur. Vorbild und Form: `ApplePhotosIgnoredAsset`.
///
/// Bewusst in SwiftData statt in UserDefaults, anders als der Fortschritts-Cursor von
/// `ExifRepairModel`: Dessen Marke ist ein abgeleitetes `Int`, dessen Verlust einen
/// neuen Durchlauf kostet. Diese Liste ist Nutzer-*Absicht*, aus nichts rekonstruierbar,
/// wächst auf tausende Einträge — und jedes Einfügen in ein UserDefaults-Array
/// schriebe das gesamte Plist neu.
///
/// Der Schlüssel ist die **Asset-ID**, nie ein Cluster-Fingerabdruck: Asset-IDs sind
/// dauerhaft stabil, ein Cluster ändert seine Identität, sobald ein Foto hinzukommt
/// oder wegfällt. Folge, die die Oberfläche benennen muss: Verwirft man eine Session
/// und taucht später eine *neue* Waise darin auf, wird genau diese eine wieder
/// vorgeschlagen.
@Model
final class GeoIgnoredAsset {
    @Attribute(.unique) var assetId: String
    var ignoredAt: Date
    /// Rohwert von `GeoIgnoreReason` — SwiftData speichert keine Enums direkt.
    var reasonRaw: String

    var reason: GeoIgnoreReason {
        GeoIgnoreReason(rawValue: reasonRaw) ?? .rejected
    }

    init(assetId: String, ignoredAt: Date = Date(), reason: GeoIgnoreReason = .rejected) {
        self.assetId = assetId
        self.ignoredAt = ignoredAt
        self.reasonRaw = reason.rawValue
    }
}
