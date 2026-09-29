import Foundation

/// Wendet die EXIF-Orientierung auf Bildmaße an.
///
/// **Warum es das braucht.** Ein hochkant fotografiertes iPhone-Bild liegt im Sensor
/// quer: `exifImageWidth = 8064`, `exifImageHeight = 6048`, dazu `orientation = 6`
/// („beim Anzeigen um 90° drehen"). Immich erzeugt sein Thumbnail bereits gedreht, der
/// Sync-Stream liefert aber die rohen Sensormaße. Das Raster rechnete sein
/// Seitenverhältnis daraus und legte ein Querformat-Kästchen an, in das ein
/// Hochformat-Bild gefüllt wurde — `resizeAspectFill` schnitt oben und unten ab.
///
/// Nachgemessen am 06.09.2026 an 60 Assets, jeweils gegen die tatsächlichen
/// Thumbnail-Maße vom Server:
///
/// ```
/// Maße im Grid-Index (roh)                20/60  (33 %)
/// Thumbhash-Orientierungsbit              68/120 (57 %, praktisch Münzwurf)
/// Immichs Top-Level width/height          55/60  (92 %)
/// EXIF-Maße mit dieser Korrektur          59/60  (98 %)
/// ```
///
/// Bemerkenswert: Immichs eigene Top-Level-Maße sind **nicht** durchgängig korrigiert —
/// bei `orientation = 6` meldete der Server mehrfach die rohen Sensormaße. Deshalb ist
/// diese Rechnung hier die verlässlichere Quelle, nicht bloß ein Ersatz.
enum ExifOrientation {

    /// Die EXIF-Werte 5–8 beschreiben eine Vierteldrehung; nur bei ihnen tauschen
    /// Breite und Höhe. 1–4 sind Identität, Spiegelungen und die 180°-Drehung — alle
    /// ohne Seitentausch.
    static func swapsSides(_ orientation: Int?) -> Bool {
        guard let orientation else { return false }
        return (5...8).contains(orientation)
    }

    /// Die angezeigten Maße zu rohen Sensormaßen.
    static func displaySize(width: Int, height: Int, orientation: Int?) -> (width: Int, height: Int) {
        swapsSides(orientation) ? (height, width) : (width, height)
    }

    /// Liest den Wert aus einer JSON-Antwort. Immich liefert ihn mal als Zahl, mal als
    /// Zeichenkette (`"6"`), und bei Dateien ohne EXIF-Block gar nicht — dann gilt
    /// „keine Drehung", nicht „unbekannt": Ein fehlender Eintrag ist die Aussage, dass
    /// das Bild so angezeigt wird, wie es gespeichert ist.
    static func parse(_ raw: Any?) -> Int? {
        if let zahl = raw as? Int { return zahl }
        if let text = raw as? String { return Int(text.trimmingCharacters(in: .whitespaces)) }
        if let zahl = raw as? Double { return Int(zahl) }
        return nil
    }
}
