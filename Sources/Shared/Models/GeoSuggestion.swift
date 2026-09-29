import Foundation

// Wertetypen des GPS-Abgleichs. Bewusst ohne SwiftData, SwiftUI und SQLite:
// der Matcher (`GeoMatcher`) arbeitet allein auf diesen Typen und ist damit
// ohne Datenbank und ohne Netz testbar.

// MARK: - Eingabe

/// Eine Zeile des Geo-Scans — das Minimum, das der Abgleich braucht.
///
/// Bewusst kein `Asset`: über 155.000 Zeilen kostet dessen Aufbau samt
/// verschachteltem `ExifInfo` zig Megabyte für vier Werte.
struct GeoScanRow: Sendable, Equatable, Identifiable {
    let id: String
    let timestamp: Date
    let latitude: Double?
    let longitude: Double?

    /// Vollständige Koordinate. Nur damit gilt eine Zeile als **Anker**.
    ///
    /// Halbe Koordinaten werden nie zu `0` ergänzt — genau daran schreibt die
    /// Web-Vorlage Fotos auf „Null Island" (0,0).
    var coordinate: (latitude: Double, longitude: Double)? {
        guard let latitude, let longitude else { return nil }
        return (latitude, longitude)
    }

    /// Gar keine Koordinate. Nur damit gilt eine Zeile als **Waise**.
    var isOrphan: Bool { latitude == nil && longitude == nil }

    /// Genau eine Hälfte gesetzt — weder Anker noch Waise.
    ///
    /// Solche Zeilen bleiben außen vor: als Anker wären sie unbrauchbar, und als
    /// Waise würde das Übernehmen eine echte, halb vorhandene Koordinate
    /// überschreiben. Sie werden gezählt, nicht verschluckt.
    var hasPartialCoordinate: Bool { (latitude == nil) != (longitude == nil) }
}

/// Was der Grid-Index für einen Scan liefert.
///
/// Der Zähler gehört zum Ergebnis, damit die Oberfläche eine Lücke benennen kann,
/// statt sie stillschweigend zu unterschlagen.
struct GeoIndexSnapshot: Sendable {
    let rows: [GeoScanRow]
    /// Zeilen, deren `fileCreatedAt` sich nicht als Datum lesen ließ.
    let unparsableTimestampCount: Int
}

/// Die einstellbaren Schrauben des Abgleichs.
struct GeoParameters: Sendable, Equatable {
    /// Wie weit ein Anker zeitlich entfernt sein darf (Regler 1…20).
    var pairThresholdMinutes: Int = 5
    /// Ab welcher Lücke eine neue Session beginnt (Regler 5…120).
    var clusterGapMinutes: Int = 30
    /// Feinere Lücke, an der übergroße Cluster nachgeteilt werden.
    var microGapMinutes: Int = 2
    /// Ab wie vielen Assets ein Cluster nachgeteilt wird.
    var subSplitThreshold: Int = 50
    /// Kleinster Cluster, der noch angeboten wird.
    var minClusterSize: Int = 3
    /// Wie viel Prozent eines Clusters GPS haben müssen (Regler 20…95).
    var minGpsPercentage: Double = 60

    static let pairThresholdRange = 1...20
    static let clusterGapRange = 5...120
    static let minGpsPercentageRange = 20.0...95.0
}

// MARK: - Bewertung

/// Woher die vorgeschlagene Koordinate stammt.
enum GeoSource: Sendable, Equatable {
    /// Zwischen zwei Ankern zeitgewichtet interpoliert. `ratio` 0…1 ab dem früheren.
    case interpolated(beforeId: String, afterId: String, ratio: Double)
    /// Von einem einzelnen Anker kopiert. `deltaSeconds` vorzeichenbehaftet (Waise − Anker).
    case nearestAnchor(id: String, deltaSeconds: Int)
    /// Median der Ankerkoordinaten einer Session.
    case clusterMedian(clusterId: String, anchorCount: Int)

    /// Die Anker, auf denen der Vorschlag beruht — für die Vorschau.
    var anchorIds: [String] {
        switch self {
        case .interpolated(let before, let after, _): return [before, after]
        case .nearestAnchor(let id, _): return [id]
        case .clusterMedian: return []
        }
    }
}

enum GeoLabel: Sendable, Equatable {
    case sicher
    case wahrscheinlich
    case unsicher
    /// Die Anker liegen weit auseinander — die Aufnahmen entstanden unterwegs.
    case bewegteSession

    var displayName: String {
        switch self {
        case .sicher: return "Sicher"
        case .wahrscheinlich: return "Wahrscheinlich"
        case .unsicher: return "Unsicher"
        case .bewegteSession: return "Bewegte Session"
        }
    }
}

/// Warum ein Vorschlag nicht belastbar ist.
struct GeoImplausibility: Sendable, Equatable {
    enum Reason: Sendable, Equatable {
        /// Die Anker implizieren eine unmögliche Geschwindigkeit.
        case impossibleSpeed
        /// Große Distanz in sehr kurzer Zeit — unabhängig von der Rechnung.
        case teleport
        /// Die Anker eines Clusters streuen zu weit für einen Median.
        case clusterSpread
        /// Der Zeitstempel ist mit vielen anderen Aufnahmen identisch und damit
        /// vermutlich ein Rückfallwert, kein echtes Aufnahmedatum.
        case sharedTimestamp
    }

    let reason: Reason
    var distanceKm: Double = 0
    var gapSeconds: Int = 0
    var impliedKmh: Double = 0
    /// Wie viele Aufnahmen sich denselben Zeitstempel teilen.
    var sharedTimestampCount: Int = 0

    /// Kurzbegründung für die Oberfläche, z. B. „412 km in 6 Min".
    var summary: String {
        let km = distanceKm < 10
            ? String(format: "%.1f km", distanceKm)
            : "\(Int(distanceKm.rounded())) km"
        let minutes = max(1, Int((Double(gapSeconds) / 60).rounded()))
        switch reason {
        case .impossibleSpeed, .teleport:
            return "\(km) in \(minutes) Min"
        case .clusterSpread:
            return "\(km) Streuung"
        case .sharedTimestamp:
            return "Zeit von \(sharedTimestampCount) Fotos geteilt"
        }
    }
}

enum GeoPlausibility: Sendable, Equatable {
    case ok
    /// Wird angeboten, gewarnt und ist standardmäßig **nicht** ausgewählt.
    case flagged(GeoImplausibility)
    /// Wird gar nicht erst angeboten — aber gezählt und auf Wunsch einsehbar.
    case suppressed(GeoImplausibility)

    var isSuppressed: Bool {
        if case .suppressed = self { return true }
        return false
    }

    var isFlagged: Bool {
        if case .flagged = self { return true }
        return false
    }

    /// Auffällig, gleich wie stark — markiert **oder** verworfen.
    ///
    /// Für Aussagen über den Befund selbst, nicht über seine Folge: Eine Session,
    /// deren Streuung zum Verwerfen reicht, ist erst recht eine bewegte Session.
    var isSpatiallyNotable: Bool { isFlagged || isSuppressed }

    var implausibility: GeoImplausibility? {
        switch self {
        case .ok: return nil
        case .flagged(let value), .suppressed(let value): return value
        }
    }
}

/// Ab welcher Konfidenz Vorschläge überhaupt angezeigt und ausgewählt werden.
///
/// Feste Stufen statt freier Eingabe: Der Wert steuert einen Schreibvorgang, der
/// auf Servern ohne Null-Unterstützung unumkehrbar ist. Sechs Stufen decken den
/// Bedarf, und jede von ihnen ist eine bewusste Wahl aus einer Liste — kein
/// Zahlenfeld, in dem ein Tippfehler aus 85 eine 8 macht.
enum GeoConfidenceThreshold: Int, CaseIterable, Identifiable, Sendable {
    case all = 0
    case p70 = 70
    case p80 = 80
    case p85 = 85
    case p90 = 90
    case p95 = 95

    var id: Int { rawValue }

    /// Ob überhaupt gefiltert wird. `.all` lässt die Liste unangetastet.
    var isActive: Bool { self != .all }

    var displayName: String { self == .all ? "Alle" : "ab \(rawValue) %" }
}

// MARK: - Ergebnis

/// Ein Koordinatenvorschlag für genau eine Waise.
struct GeoSuggestion: Sendable, Equatable, Identifiable {
    /// Gleich der Waisen-ID — je Waise gibt es höchstens einen Vorschlag.
    var id: String { orphanId }

    let orphanId: String
    let orphanTimestamp: Date
    let latitude: Double
    let longitude: Double
    let source: GeoSource
    /// 0…100.
    let confidence: Int
    let label: GeoLabel
    let plausibility: GeoPlausibility
}

/// Eine Waise, für die der zeitbasierte Abgleich nichts anzubieten hat.
///
/// Bis hierher war diese Menge nur eine Differenz — `orphanCount` minus dem, was
/// in den Listen stand. Sie zu benennen ist die Voraussetzung dafür, dass ein
/// anderer Weg (Bilderkennung) genau dort ansetzen kann, wo dieser aufgibt.
struct GeoUnmatchedOrphan: Sendable, Equatable, Identifiable {
    let id: String
    let timestamp: Date

    /// Abstand zum nächsten Anker der Bibliothek — auch weit außerhalb des
    /// Zeitfensters. `nil`, wenn es überhaupt keinen Anker gibt.
    ///
    /// Sagt dem Nutzer, wie weit das Foto von jeder Ortsinformation entfernt ist
    /// („nächstes Foto mit GPS: 6 Std entfernt"), und dient als Gegenprobe für
    /// einen erkannten Ort.
    let nearestAnchorGapSeconds: Int?

    /// Wo dieser nächste Anker liegt. Ohne die Koordinate wäre der Zeitabstand
    /// allein nur Anzeige — erst zusammen ergibt sich die Gegenprobe „ein Foto von
    /// vor drei Stunden liegt 2000 km entfernt".
    let nearestAnchorLatitude: Double?
    let nearestAnchorLongitude: Double?

    /// Es gab einen Vorschlag, er wurde nur als unplausibel verworfen.
    ///
    /// Solche Waisen bleiben Kandidaten: Ein verworfener Zeitsprung ist gerade der
    /// Fall, in dem ein Blick aufs Bild weiterhilft.
    let hadSuppressedSuggestion: Bool
}

/// Eine zeitlich zusammenhängende Aufnahme-Session.
struct GeoCluster: Sendable, Equatable, Identifiable {
    /// Stabiler Fingerabdruck über die enthaltenen Assets.
    let id: String

    let assetIds: [String]
    let anchorIds: [String]
    let orphanIds: [String]

    let start: Date
    let end: Date

    let medianLatitude: Double
    let medianLongitude: Double

    /// 0…100.
    let gpsPercentage: Int
    /// Größter Abstand zwischen zwei Ankern.
    let spatialSpreadMeters: Int
    let timeSpreadMinutes: Double

    /// 0…100.
    let confidence: Int
    let label: GeoLabel
    let plausibility: GeoPlausibility

    var missingCount: Int { orphanIds.count }
}

/// Das vollständige Ergebnis eines Scans — beide Modi aus einem Durchlauf.
struct GeoScanResult: Sendable {
    let pairs: [GeoSuggestion]
    /// Verworfene Paar-Vorschläge. Aufbewahrt, damit „nichts gefunden" und
    /// „gefunden und verworfen" unterscheidbar bleiben.
    let suppressedPairs: [GeoSuggestion]

    let clusters: [GeoCluster]
    let suppressedClusters: [GeoCluster]

    /// Waisen ohne übernehmbaren Paar-Vorschlag.
    ///
    /// Zusammen mit `pairs` eine vollständige, überschneidungsfreie Zerlegung der
    /// Waisen — `GeoUnmatchedOrphanTests` sichert das ab.
    let unmatchedOrphans: [GeoUnmatchedOrphan]

    let anchorCount: Int
    let orphanCount: Int
    /// Zeilen mit genau einer Koordinatenhälfte — weder Anker noch Waise.
    let partialCoordinateCount: Int

    static let empty = GeoScanResult(
        pairs: [], suppressedPairs: [],
        clusters: [], suppressedClusters: [],
        unmatchedOrphans: [],
        anchorCount: 0, orphanCount: 0, partialCoordinateCount: 0
    )
}
