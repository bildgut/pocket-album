import Foundation
import CoreGraphics

/// Alles, was eine Bearbeitung im Bearbeiten-Modus festlegt: Anpassen (bei RAW über
/// ``RawDevelopParams``, sonst ``ImageAdjustmentParams``, jeweils samt Look) und
/// Zuschnitt.
///
/// Gespeichert wird sie am **Original** auf dem Immich-Server (``BearbeitungsEintrag``),
/// damit „Bearbeiten“ später — auch von einem anderen Mac oder aus Pocket Album —
/// vom Original aus weitermacht statt auf der verlustbehafteten Fassung. Genau eines
/// von `raw`/`anpassen` ist bei einer echten Bearbeitung gesetzt; welches, entscheidet
/// der Dateityp des Originals, nicht der Nutzer.
struct Bearbeitung: Codable, Equatable, Sendable {
    var raw: RawDevelopParams?
    var anpassen: ImageAdjustmentParams?
    var zuschnitt: Zuschnitt?

    init(raw: RawDevelopParams? = nil, anpassen: ImageAdjustmentParams? = nil, zuschnitt: Zuschnitt? = nil) {
        self.raw = raw
        self.anpassen = anpassen
        self.zuschnitt = zuschnitt
    }

    /// Nichts davon verändert das Bild — „Fertig“ nimmt dann eine vorhandene Fassung
    /// zurück, statt eine neue zu erzeugen.
    var istLeer: Bool {
        (raw?.isIdentity ?? true)
            && (anpassen?.isIdentity ?? true)
            && (zuschnitt?.istNeutral ?? true)
    }
}

/// Ausrichten und Beschnitt, wie `PhotoStraightenViewModel` sie hält: Winkel in Grad,
/// Rechteck in 0…1 relativ zum einbeschriebenen Rechteck des Winkels.
///
/// Flache Felder statt `CGRect`, damit das JSON ohne Kenntnis von CoreGraphics lesbar
/// bleibt (`CGRect` kodiert als verschachteltes Array).
struct Zuschnitt: Codable, Equatable, Sendable {
    var winkel: Double
    var x: Double
    var y: Double
    var breite: Double
    var hoehe: Double
    /// `CropAspect.rawValue`, `nil` = frei.
    var seitenverhaeltnis: String?

    init(winkel: Double, rechteck: CGRect, seitenverhaeltnis: CropAspect?) {
        self.winkel = winkel
        x = rechteck.origin.x
        y = rechteck.origin.y
        breite = rechteck.width
        hoehe = rechteck.height
        self.seitenverhaeltnis = seitenverhaeltnis?.rawValue
    }

    var rechteck: CGRect { CGRect(x: x, y: y, width: breite, height: hoehe) }
    var aspekt: CropAspect? { seitenverhaeltnis.flatMap(CropAspect.init(rawValue:)) }

    var istNeutral: Bool { winkel == 0 && rechteck == CropGeometry.full }
}

/// Der Server-Eintrag am Original unter ``schluessel``.
struct BearbeitungsEintrag: Codable, Equatable, Sendable {
    static let schluessel = "immich-mac.bearbeitung"

    var v: Int = 1
    var einstellungen: Bearbeitung
    /// Die gestapelte Fassung aus dieser Bearbeitung — höchstens eine je Original.
    var fassungId: String?
    var geaendertAm: Date

    init(einstellungen: Bearbeitung, fassungId: String?, geaendertAm: Date) {
        self.einstellungen = einstellungen
        self.fassungId = fassungId
        self.geaendertAm = geaendertAm
    }
}

/// Rückverweis an der Fassung unter ``schluessel``: Weil die Fassung Titelbild des
/// Stapels ist, steht der Nutzer beim Weiterbearbeiten fast immer auf ihr.
struct FassungsVerweis: Codable, Equatable, Sendable {
    static let schluessel = "immich-mac.fassung"

    var v: Int = 1
    var originalId: String

    init(originalId: String) {
        self.originalId = originalId
    }
}

/// Ein Kodierer für beide Apps: ISO-8601-Datum (lesbar in jedem anderen Client) und
/// feste Schlüsselreihenfolge (vergleichbare Körper im Test und im Log).
enum BearbeitungJSON {
    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
