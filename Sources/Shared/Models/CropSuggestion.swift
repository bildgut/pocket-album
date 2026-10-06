import Foundation
import CoreGraphics

/// Ein Zuschnitt-Vorschlag des KI-Zuschnitt-Assistenten.
///
/// `rect` ist normiert (0…1) mit Ursprung **oben links** — dieselbe Konvention wie
/// `CropGeometry.cropFraction` bei Winkel 0, und dieselbe wie SwiftUI. Damit wandert
/// der Wert ohne Transformation in den Beschnitt-Editor und (per `pixelRect`) in die
/// Raster-Crops von `CGImage.cropping(to:)`.
struct CropSuggestion: Identifiable, Sendable, Equatable {
    let id: UUID
    var rect: CGRect
    var title: String
    var rationale: String
    var aspect: CropAspect
    /// Auflösung des Zuschnitts in Megapixeln, gerechnet auf das ORIGINAL (nicht die
    /// verschickte Vorschau) — die Zahl, die zeigt, wie viel vom 60-MP-Budget bleibt.
    var megapixels: Double
    /// Selbstbewertung des Modells (1…10): wie stark der Zuschnitt die
    /// Originalkomposition verbessert. Schwache Vorschläge werden gefiltert.
    var score: Double
}
