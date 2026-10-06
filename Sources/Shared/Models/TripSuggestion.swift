import Foundation

// Wertetypen der Albumvorschläge. Bewusst ohne SwiftData, SwiftUI und SQLite:
// `TripSegmenter` arbeitet allein auf diesen Typen und ist damit ohne Datenbank
// und ohne Netz testbar — dieselbe Trennung wie bei `GeoSuggestion`/`GeoMatcher`.

// MARK: - Eingabe

/// Eine Zeile des Etappen-Scans — das Minimum, das die Erkennung braucht.
///
/// Bewusst kein `Asset`: über 155 000 Zeilen kostet dessen Aufbau samt
/// verschachteltem `ExifInfo` zig Megabyte für sechs Werte.
struct TripScanRow: Sendable, Equatable, Identifiable {
    let id: String
    let timestamp: Date
    let latitude: Double?
    let longitude: Double?
    /// Serverseitig aus GeoNames abgeleitet — in Großstädten oft ein Stadtteil.
    /// Deshalb nur Etikett, nie Trennkriterium.
    let city: String?
    let country: String?

    /// Vollständige Koordinate. Nur damit gilt eine Zeile als **Anker**.
    var coordinate: (latitude: Double, longitude: Double)? {
        guard let latitude, let longitude else { return nil }
        return (latitude, longitude)
    }

    /// Gar keine Koordinate. Solche Zeilen können eine Etappe nur *erben*.
    var isOrphan: Bool { latitude == nil && longitude == nil }

    /// Genau eine Hälfte gesetzt — weder Anker noch Waise.
    ///
    /// Als Anker wäre die Zeile unbrauchbar, als Waise würde sie so getan, als
    /// hätte sie gar keine Position. Sie wird gezählt, nicht verschluckt.
    var hasPartialCoordinate: Bool { (latitude == nil) != (longitude == nil) }
}

/// Was der Grid-Index für einen Etappen-Scan liefert.
///
/// Die beiden Zähler gehören zum Ergebnis, damit die Oberfläche jede Lücke
/// benennen kann, statt sie stillschweigend zu unterschlagen.
struct TripIndexSnapshot: Sendable {
    let rows: [TripScanRow]
    /// Zeilen, deren `fileCreatedAt` sich nicht als Datum lesen ließ.
    let unparsableTimestampCount: Int
    /// Zeilen ohne `exifCheckedAt`: Ort und Koordinate sind dort nicht „leer",
    /// sondern **unbekannt**. Sie als Foto ohne Ort zu behandeln hieße, sie
    /// zeitlich irgendeiner Etappe zuzuschlagen — auf einer Vermutung statt auf
    /// einer Messung. Sie bleiben deshalb außen vor und werden gezählt.
    let exifUncheckedCount: Int
}

/// Die einstellbaren Schrauben der Etappenerkennung.
struct TripParameters: Sendable, Equatable {
    /// Wie weit ein Foto vom Bezugspunkt der Etappe entfernt sein darf, bevor es
    /// als Ausbruch zählt (Regler 5…150). Bestimmt die Granularität: 25 km fasst
    /// eine Großstadt zusammen, 100 km eine Region.
    var radiusKm: Double = 25

    /// Längere Pause trennt auch am selben Ort — sonst verschmölze der zweite
    /// Tokio-Aufenthalt derselben Reise mit dem ersten.
    var maxGapDays: Double = 2

    /// So viele Anker müssen **in Folge** außerhalb des Radius liegen, bevor
    /// getrennt wird. Ein einzelnes falsch verortetes Foto zerschneidet eine
    /// Etappe damit nicht.
    var breakoutRunLength: Int = 3

    /// Innerhalb welcher Spanne eine Rückkehr zum selben Punkt als Beleg für einen
    /// hängengebliebenen GPS-Fix zählt.
    ///
    /// Die Schranke ist der Kern der Erkennung, nicht ihr Beiwerk: Ohne sie wäre der
    /// eigene Wohnort der erste Treffer — den verlässt man und kehrt zurück,
    /// tausendfach. Binnen drei Stunden über eine weite Abwesenheit hinweg
    /// zurückzukehren ist etwas anderes als eine Heimkehr nach einer Woche.
    var staleWindowHours: Double = 3

    /// So viele solcher Rückkehren machen einen Punkt zum Standwert.
    ///
    /// Zwei, nicht eine: Ein einzelner Ausflug hin und zurück ist alltäglich. Erst
    /// das wiederholte Hin und Her im selben Zeitfenster ist der Reißverschluss, den
    /// ein Gerät ohne Empfang erzeugt.
    var staleReturnCount: Int = 2

    /// Kleinste Etappe, die noch als Vorschlag angeboten wird. Kleinere werden
    /// ausgeblendet, nicht verworfen.
    var minPhotos: Int = 20

    /// Mindestentfernung zum automatisch ermittelten Heimatort.
    ///
    /// `nil` schaltet den Filter ab — so läuft der Albummodus, in dem ohnehin
    /// nur Fotos einer Reise vorliegen.
    ///
    /// Untergrenze 60 km: `HighlightScorer.autoDetectHome` rastert auf 0,5°
    /// (≈ 55 km), feiner ist der Heimatort gar nicht bekannt.
    var minHomeDistanceKm: Double? = 100

    /// Parametersatz für das Aufteilen eines bestehenden Albums: keine
    /// Heimatprüfung, und auch kurze Abstecher sind hier erwünschte Etappen.
    static let albumSplit = TripParameters(minPhotos: 5, minHomeDistanceKm: nil)
}

// MARK: - Ergebnis

/// Warum eine erkannte Etappe nicht in der Hauptliste steht.
///
/// Ausgeblendet heißt sichtbar-aber-nicht-vorausgewählt, nicht weggeworfen: die
/// Fotos bleiben zugeordnet, und wer will, hakt die Etappe trotzdem an.
enum TripHiddenReason: String, Sendable, Equatable {
    /// Vom Nutzer verworfen (persistente Ignorierliste).
    case ignored
    /// Liegt innerhalb `minHomeDistanceKm` um den Heimatort — Alltag, keine Reise.
    case nearHome
    /// Weniger Fotos als `minPhotos`.
    case belowMinPhotos
    /// Jedes Foto der Etappe liegt bereits in einem einzigen Album — es gibt nichts
    /// mehr zu tun.
    ///
    /// Anders als die übrigen Gründe entsteht dieser **nicht** im Segmenter: Er
    /// hängt an der Albummitgliedschaft, und die kennt erst das Modell. Er wird
    /// nachträglich gesetzt, sobald die Überschneidungen berechnet sind.
    case alreadyCovered
}

/// Eine erkannte Etappe.
struct TripSegment: Sendable, Equatable, Identifiable {
    /// Stabiler Fingerabdruck über die enthaltenen Assets — überlebt einen
    /// Neustart, anders als `hashValue`.
    let id: String
    /// Häufigster `city`-Wert der Anker, sonst Land, sonst die Koordinate.
    let label: String
    let country: String?
    let start: Date
    let end: Date
    /// Alle Assets in Zeitreihenfolge, Anker und zeitlich geerbte gemischt.
    let assetIds: [String]
    /// Wie viele davon eine eigene Koordinate hatten.
    let anchorCount: Int
    /// Wie viele ohne Ort zeitlich einsortiert wurden.
    let inheritedCount: Int
    /// Median der Ankerkoordinaten — Median, nicht Mittelwert, damit ein einzelner
    /// Ausreißer die Etappe nicht verschiebt.
    let latitude: Double
    let longitude: Double
    /// Diagonale des umschließenden Rechtecks der Anker.
    let spreadKm: Double
    /// `nil`, wenn kein Heimatort ermittelt werden konnte.
    let distanceFromHomeKm: Double?
    /// Warum die Etappe nicht in der Hauptliste steht.
    ///
    /// Als einziges Feld veränderbar: `alreadyCovered` lässt sich erst feststellen,
    /// wenn die Albummitgliedschaft bekannt ist — also nach dem Scan, im Modell.
    var hiddenReason: TripHiddenReason?

    var assetCount: Int { assetIds.count }
}

/// Das vollständige Ergebnis eines Scans.
///
/// `segments`, `hiddenSegments` und `unassignedIds` ergeben zusammen wieder die
/// Eingabe (bis auf halbe Koordinaten). Nichts verschwindet stillschweigend —
/// die Oberfläche kann jede Lücke benennen.
struct TripScanResult: Sendable {
    let segments: [TripSegment]
    let hiddenSegments: [TripSegment]
    /// Fotos, die keiner Etappe eindeutig zuzuordnen waren.
    let unassignedIds: [String]
    let homeLatitude: Double?
    let homeLongitude: Double?
    /// Die häufigste Landesangabe rund um den Heimatort — der Rohwert des Servers,
    /// nicht der Kurzname.
    ///
    /// Bestimmt, welche Etappen als „Ausland" gelten und deshalb das Land im
    /// Albumnamen tragen. Bewusst abgeleitet statt eingestellt: Ein hartkodiertes
    /// „Deutschland" wäre nach einem Umzug still falsch.
    let homeCountry: String?
    /// Anker, deren Sprung zum Vorgänger physikalisch unmöglich war. Sie zählen
    /// nicht als Anker, dürfen aber zeitlich erben.
    let implausibleAnchorCount: Int
    /// Aufnahmen mit einem hängengebliebenen GPS-Fix. Sie bleiben in ihrer Etappe,
    /// dürfen aber keine Etappengrenze setzen.
    let staleFixCount: Int
    /// Zeilen mit genau einer Koordinatenhälfte.
    let partialCoordinateCount: Int

    var home: (latitude: Double, longitude: Double)? {
        guard let homeLatitude, let homeLongitude else { return nil }
        return (homeLatitude, homeLongitude)
    }

    static let empty = TripScanResult(
        segments: [], hiddenSegments: [], unassignedIds: [],
        homeLatitude: nil, homeLongitude: nil, homeCountry: nil,
        implausibleAnchorCount: 0, staleFixCount: 0, partialCoordinateCount: 0
    )
}
