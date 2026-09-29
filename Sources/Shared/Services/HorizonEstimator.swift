import Foundation
import ImageIO
import CoreGraphics

// MARK: - HorizonEstimator

/// Schätzt aus den dominanten Kantenrichtungen eines Bildes, um wie viel Grad es
/// gedreht werden muss, damit Waagerechte und Senkrechte wieder auf den Achsen liegen.
///
/// **Warum nicht `VNDetectHorizonRequest`:** Apples Horizonterkennung ist auf echte
/// Horizonte trainiert (Meer, Feld, Skyline). An einem Bahnsteigfoto, einer Messehalle
/// oder einem Innenraum liefert sie gar kein Ergebnis — am 06.09.2026 an einem
/// iPhone-Foto nachgemessen: `results` leer, auch nach künstlicher Kippung.
///
/// **Warum kein Sprachmodell:** Der gesuchte Wert ist eine Messung, keine Beschreibung.
/// Das Verfahren hier braucht keinen Schlüssel, keine Netzverbindung und kein Guthaben,
/// läuft in wenigen Millisekunden — und ist vor allem **deterministisch**, also
/// testbar. Bei einem Feature, dessen Fehlerklasse das Vorzeichen ist, zählt das mehr
/// als Bildverständnis.
enum HorizonEstimator {

    struct Ergebnis: Equatable {
        /// Korrekturwinkel in Grad, **positiv = im Uhrzeigersinn** — dieselbe
        /// Konvention wie der Regler und ``ImageEditingService/applyStraighten(imageData:angle:crop:)``.
        let winkel: Double
        /// Anteil des Kantengewichts, der nach der Korrektur auf den Achsen liegt (0…1).
        /// Ein Maß dafür, wie eindeutig das Bild überhaupt eine Ausrichtung hat.
        let guete: Double
    }

    /// Lange Kante des Analyserasters. 800 px reichen: Gesucht ist die Richtung langer
    /// Kanten, nicht Feinstruktur — und kleiner heißt schneller (gemessen: 3 ms).
    static let analyseKante = 800

    /// Suchbereich in Grad — bewusst eng.
    ///
    /// Am 06.09.2026 an einem echten Bahnsteigfoto gemessen (starke Perspektive, also
    /// viele nicht achsparallele Fluchtlinien): Bei ±25° fand die Suche für ein um 15°
    /// gekipptes Bild +14,8° statt −15,3° — ein Nebenmaximum aus den Fluchtlinien. Mit
    /// ±10° kommen solche Treffer nicht mehr in Frage.
    ///
    /// Der Preis ist ehrlich: Ein um 15° verkantetes Foto richtet die Automatik nicht
    /// aus. Das ist der seltenere Fall — beim Geradeziehen geht es um ein paar Grad
    /// Schieflage, und dort trifft sie zuverlässig (Original −0,3°, um −8° gekippt
    /// +8,0°). Wer mehr braucht, zieht den Regler selbst.
    static let suchbereich: Double = 10

    /// Mindestgüte, damit ein Vorschlag gemacht wird. Darunter hat das Bild keine
    /// tragende Ausrichtung — Wald, Wolken, Nahaufnahmen.
    static let mindestGuete: Double = 0.012

    /// - Returns: `nil`, wenn das Bild nicht lesbar ist, keine verwertbaren Kanten hat
    ///   oder die Güte unter ``mindestGuete`` liegt.
    static func schaetze(imageData: Data) -> Ergebnis? {
        guard let raster = graustufenRaster(imageData) else { return nil }
        return schaetze(raster: raster.px, breite: raster.w, hoehe: raster.h)
    }

    // MARK: - Rechnung

    /// Auf 0,1° aufgelöstes Histogramm über −90…<90.
    private static let stufen = 1800
    private static let proGrad = 10.0

    static func schaetze(raster: [Float], breite w: Int, hoehe h: Int) -> Ergebnis? {
        guard w > 2, h > 2, raster.count == w * h else { return nil }

        // Kantenrichtungen sammeln, gewichtet mit der Kantenstärke.
        var histogramm = [Double](repeating: 0, count: stufen)
        var gesamt = 0.0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                let gx = -raster[i-w-1] - 2*raster[i-1] - raster[i+w-1]
                        + raster[i-w+1] + 2*raster[i+1] + raster[i+w+1]
                let gy = -raster[i-w-1] - 2*raster[i-w] - raster[i-w+1]
                        + raster[i+w-1] + 2*raster[i+w] + raster[i+w+1]
                let staerke = (gx * gx + gy * gy).squareRoot()
                if staerke < 60 { continue }   // Rauschen und flache Verläufe aussortieren
                // Die Kante läuft senkrecht zum Gradienten.
                let richtung = Double(atan2(gy, gx)) * 180 / .pi + 90
                histogramm[stufe(fuer: richtung)] += Double(staerke)
                gesamt += Double(staerke)
            }
        }
        guard gesamt > 0 else { return nil }

        // Den Kandidaten suchen, der das meiste Gewicht auf die Achsen legt.
        //
        // **Von 0 nach außen**, und nur bei echt größerem Gewicht übernehmen: Damit
        // gewinnt bei Gleichstand der kleinste Eingriff. Das ist keine Kosmetik — die
        // Achsfenster sind ±1,5° breit, also liefern bei einem schon geraden Bild alle
        // Kandidaten in diesem Bereich praktisch dasselbe Gewicht. Wer stumpf von
        // −25° aufwärts sucht, bekommt dort ein zufälliges Ergebnis und schlägt für ein
        // gerades Foto 1,4° vor (im Test genau so passiert).
        var bestesGewicht = achsGewicht(histogramm, verdreht: 0)
        var bestesD = 0.0
        var schritt = 0.1
        while schritt <= suchbereich {
            for d in [schritt, -schritt] {
                let gewicht = achsGewicht(histogramm, verdreht: d)
                if gewicht > bestesGewicht * 1.000001 {
                    bestesGewicht = gewicht
                    bestesD = d
                }
            }
            schritt += 0.1
        }

        let guete = bestesGewicht / gesamt
        guard guete >= mindestGuete else { return nil }

        // `bestesD` ist die Lage der Kanten. Um sie auf die Achsen zu bringen, muss um
        // denselben Betrag **zurück** gedreht werden — daher das Minus. Die Richtung
        // hängt an der Konvention von `applyStraighten` (positiv = im Uhrzeigersinn)
        // und ist in `HorizonEstimatorTests` mit beiden Vorzeichen festgenagelt.
        let korrektur = -bestesD
        return Ergebnis(winkel: (korrektur * 10).rounded() / 10, guete: guete)
    }

    /// Gewicht in schmalen Fenstern um die vier Achsrichtungen einer um `verdreht`
    /// gekippten Szene.
    ///
    /// **Die Klappung ist der heikle Teil.** Kantenrichtungen leben auf −90…<90, weil
    /// eine Linie keine Richtung hat: 105° und −75° sind dieselbe Lage. Ein erster
    /// Entwurf verwarf das Fenster um 105° einfach, wenn es aus dem Raster fiel — damit
    /// zählte er für positive und negative Kippungen unterschiedlich viele Fenster und
    /// gab für +15° wie für −8° beide Male einen positiven Wert zurück.
    private static func achsGewicht(_ histogramm: [Double], verdreht d: Double) -> Double {
        var summe = 0.0
        for achse in [0.0, 90.0] {
            var offset = -1.5
            while offset <= 1.5 {
                summe += histogramm[stufe(fuer: achse + d + offset)]
                offset += 0.1
            }
        }
        return summe
    }

    /// Winkel → Histogrammstufe, mit Klappung auf −90…<90.
    private static func stufe(fuer winkel: Double) -> Int {
        var w = winkel.remainder(dividingBy: 180)   // −90…90
        if w >= 90 { w -= 180 }
        if w < -90 { w += 180 }
        var idx = Int(((w + 90) * proGrad).rounded())
        if idx >= stufen { idx -= stufen }
        if idx < 0 { idx += stufen }
        return idx
    }

    // MARK: - Bildaufbereitung

    /// Graustufenraster, verkleinert und **EXIF-orientiert**.
    ///
    /// `kCGImageSourceCreateThumbnailWithTransform` ist Pflicht: Ohne das käme ein
    /// hochkant fotografiertes iPhone-Bild quer heraus, und der geschätzte Winkel
    /// bezöge sich auf eine Lage, die niemand sieht.
    private static func graustufenRaster(_ data: Data) -> (px: [Float], w: Int, h: Int)? {
        guard !data.isEmpty,
              let quelle = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let optionen: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: analyseKante,
        ]
        guard let bild = CGImageSourceCreateThumbnailAtIndex(quelle, 0, optionen as CFDictionary),
              bild.width > 2, bild.height > 2 else { return nil }

        let w = bild.width, h = bild.height
        var grau = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &grau, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(bild, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (grau.map { Float($0) }, w, h)
    }
}
