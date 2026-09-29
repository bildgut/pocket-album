import Foundation

/// Die Einträge der Seitenleiste. `alleDokumente` ist keine eigene Einordnung,
/// sondern die Sammelansicht über alle Unterarten.
enum InfoBildRubrik: String, CaseIterable, Identifiable, Sendable {
    case belege
    case notizen
    case informationen
    case rezepte
    case ausweise
    case alleDokumente
    case screenshots

    var id: String { rawValue }

    var titel: String {
        switch self {
        case .belege: "Belege"
        case .notizen: "Notizen"
        case .informationen: "Informationen"
        case .rezepte: "Rezepte und Speisekarten"
        case .ausweise: "Ausweise"
        case .alleDokumente: "Alle Dokumente"
        case .screenshots: "Screenshots"
        }
    }

    var symbol: String {
        switch self {
        case .belege: "receipt"
        case .notizen: "note.text"
        case .informationen: "list.bullet.rectangle.portrait"
        case .rezepte: "fork.knife"
        case .ausweise: "person.text.rectangle"
        case .alleDokumente: "doc.text"
        case .screenshots: "iphone.gen3"
        }
    }

    /// Dieselbe Zuordnung wie ``fuer(ergebnis:unterart:)``, nur andersherum:
    /// Mit welchem Ergebnis- und Unterart-Rohwert sich die Rubrik in der
    /// Datenbank abfragen lässt. `unterart == nil` heißt „egal welche".
    ///
    /// Gibt es, damit ``InfoBildStore`` mit `fetchCount`/Prädikat arbeiten kann,
    /// statt die ganze Tabelle zu laden und in Swift zu filtern. Dass beide Wege
    /// dasselbe sagen, hält ein Test fest.
    var abfrage: (ergebnis: String, unterart: String?) {
        switch self {
        case .belege: (InfoBildArt.dokument.rawValue, InfoBildUnterart.beleg.rawValue)
        case .notizen: (InfoBildArt.dokument.rawValue, InfoBildUnterart.notiz.rawValue)
        case .informationen: (InfoBildArt.dokument.rawValue, InfoBildUnterart.information.rawValue)
        case .rezepte: (InfoBildArt.dokument.rawValue, InfoBildUnterart.rezept.rawValue)
        case .ausweise: (InfoBildArt.dokument.rawValue, InfoBildUnterart.ausweis.rawValue)
        case .alleDokumente: (InfoBildArt.dokument.rawValue, nil)
        case .screenshots: (InfoBildArt.screenshot.rawValue, nil)
        }
    }

    /// In welchen Rubriken ein Befund auftaucht — rein, ohne Datenbank.
    ///
    /// Tolerant gegenüber Rohwerten, die es nicht (mehr) gibt: Ein unbekanntes
    /// Ergebnis erscheint nirgends, statt die Ansicht zu sprengen. Ein `dokument`
    /// ohne brauchbare Unterart zählt als `sonstiges` — Stufe B kann abgelehnt
    /// worden oder fehlgeschlagen sein, das Bild ist trotzdem ein Dokument.
    static func fuer(ergebnis: String, unterart: String?) -> [InfoBildRubrik] {
        switch InfoBildArt(rawValue: ergebnis) {
        case .screenshot:
            return [.screenshots]
        case .dokument:
            switch unterart.flatMap(InfoBildUnterart.init(rawValue:)) {
            case .beleg: return [.belege, .alleDokumente]
            case .notiz: return [.notizen, .alleDokumente]
            case .information: return [.informationen, .alleDokumente]
            case .rezept: return [.rezepte, .alleDokumente]
            case .ausweis: return [.ausweise, .alleDokumente]
            case .sonstiges, nil: return [.alleDokumente]
            }
        case .foto, nil:
            return []
        }
    }
}
