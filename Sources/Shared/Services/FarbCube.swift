import Foundation
import CoreImage

/// Version der Farbrechnung, die ein Regler-Satz erwartet. Gespeicherte Bearbeitungen werden
/// beim Weiterbearbeiten aus dem Original neu gerendert — ändert sich die Rechnung eines
/// Reglers still, sähe jedes gespeicherte Foto danach anders aus.
///
/// - 0: Lebendigkeit über `CIVibrance` (Stand bis November 2026). Fehlt der Schlüssel im
///   JSON, gilt 0 — **solange die Lebendigkeit überhaupt etwas tut**.
/// - 1: Lebendigkeit über `FarbCube` (OkLab, Hautschutz).
/// - 2: OkLab-Lebendigkeit + OkLab-Sättigung + filmische Tonkurve + OkLab-Farbmischer.
enum FarbModell {
    static let aktuell = 2
}

/// Lebendigkeit mit Hautschutz als 3D-Würfel für `CIColorCubeWithColorSpace`.
///
/// Die Idee stammt aus dem Farbmodul des Open-Source-Editors LightCraft (MIT/Apache): Chroma
/// wird in OkLCh skaliert, und zwar umso stärker, je blasser die Farbe ist
/// (`(1 − c/0.22)²`); bei positiver Lebendigkeit dämpft eine Glockenkurve um den Hautton die
/// Wirkung. Das ist pro Pixel rechenbar und braucht keine Nachbarn — also passt es in einen
/// Würfel, ohne eigenen Kernel.
///
/// Reine CPU-Mathematik (`makeCubeData`/`adjust` ohne CoreImage-Kontext), damit Tests ohne
/// GPU laufen. Gitterpunkte sind Display-P3-kodiert, wie beim `HSLColorCube`.
enum FarbCube {

    // MARK: - Konstanten (Startwerte von LightCraft, an einem Portrait und zwei Landschaften nachgezogen:
    // Verstärkung 1,2 → 0,8 und Dämpfung 0,6 → 0,85, Hautton 25° → 22° HSV)

    /// Chroma, ab der Lebendigkeit nichts mehr bewirkt.
    static let chromaSchwelle = 0.22
    /// Verstärkung bei Lebendigkeit 1 auf einer völlig blassen Farbe: `1 + 0.8`.
    static let verstaerkung = 0.8
    /// Breite (Radiant) der Hautton-Glocke.
    static let hautBreite = 0.35
    /// Wie stark die Glocke im Zentrum die positive Lebendigkeit dämpft.
    static let hautDaempfung = 0.85
    /// HSV-Farbton (Grad) der Haut.
    static let hautFarbtonHSV = 22.0

    /// OkLCh-Farbton (Radiant) der Haut: der HSV-Farbton als P3-kodierte Farbe in OkLab.
    static let hautFarbton: Double = {
        let hp = hautFarbtonHSV / 60
        let x = 1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1)
        let lab = OkLab.fromEncodedP3(r: 1, g: x, b: 0)
        return atan2(lab.b, lab.a)
    }()

    // MARK: - Würfel

    /// RGBA-Float-Würfel (dimension³ × 4 Floats, Rot läuft am schnellsten).
    static func makeCubeData(vibrance: Double, saturation: Double = 1.0, dimension: Int = 64) -> Data {
        let dim = max(2, dimension)
        var cube = [Float](repeating: 0, count: dim * dim * dim * 4)
        let last = Double(dim - 1)
        var offset = 0
        for b in 0 ..< dim {
            for g in 0 ..< dim {
                for r in 0 ..< dim {
                    let out = adjust(r: Double(r) / last, g: Double(g) / last, b: Double(b) / last,
                                     vibrance: vibrance, saturation: saturation)
                    cube[offset] = Float(out.0)
                    cube[offset + 1] = Float(out.1)
                    cube[offset + 2] = Float(out.2)
                    cube[offset + 3] = 1
                    offset += 4
                }
            }
        }
        return cube.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    // MARK: - Ein Farbwert

    /// Wendet Lebendigkeit (−1…+1) und Sättigung (0…2, neutral 1) auf genau einen P3-kodierten
    /// Wert an — der Kern des Würfels, einzeln aufrufbar für Tests.
    static func adjust(
        r: Double, g: Double, b: Double, vibrance: Double, saturation: Double = 1.0
    ) -> (Double, Double, Double) {
        guard vibrance != 0 || saturation != 1.0 else { return (r, g, b) }
        let lab = OkLab.fromEncodedP3(r: r, g: g, b: b)
        let chroma = hypot(lab.a, lab.b)
        // Unbunte Farben bleiben unbunt: ohne Farbton gibt es nichts zu verstärken.
        guard chroma > 1e-5 else { return (r, g, b) }

        let faktor = chromaFaktor(vibrance: vibrance, chroma: chroma, farbton: atan2(lab.b, lab.a))
            * satFaktor(saturation: saturation, chroma: chroma)
        guard abs(faktor - 1.0) > 1e-9 else { return (r, g, b) }
        let neu = (a: lab.a * faktor, b: lab.b * faktor)

        let rgb = OkLab.toEncodedP3(L: lab.L, a: neu.a, b: neu.b)
        if OkLab.istImGamut(rgb) { return clamp(rgb) }

        // Mehr Chroma als P3 darstellen kann: bei gleichem Farbton und gleicher Helligkeit
        // so weit zurücknehmen, bis es passt. Kanalweises Abschneiden würde den Farbton drehen.
        var lo = 0.0, hi = 1.0
        for _ in 0 ..< 12 {
            let mid = (lo + hi) / 2
            let probe = OkLab.toEncodedP3(L: lab.L, a: lab.a + (neu.a - lab.a) * mid, b: lab.b + (neu.b - lab.b) * mid)
            if OkLab.istImGamut(probe) { lo = mid } else { hi = mid }
        }
        return clamp(OkLab.toEncodedP3(L: lab.L, a: lab.a + (neu.a - lab.a) * lo, b: lab.b + (neu.b - lab.b) * lo))
    }

    /// Faktor für den Sättigungsregler mit sanftem Rolloff auf bereits stark gesättigten Farben.
    static func satFaktor(saturation: Double, chroma: Double) -> Double {
        if saturation == 1.0 { return 1.0 }
        if saturation > 1.0 {
            let delta = saturation - 1.0
            let rolloff = 1.0 - 0.35 * min(1.0, chroma / 0.28)
            return 1.0 + delta * rolloff
        }
        return max(0.0, saturation)
    }

    /// Faktor, mit dem die Chroma multipliziert wird (≥ 0).
    static func chromaFaktor(vibrance: Double, chroma: Double, farbton: Double) -> Double {
        let blass = 1 - min(1, max(0, chroma / chromaSchwelle))
        var haut = 1.0
        if vibrance > 0 {
            let d = wrapWinkel(farbton - hautFarbton) / hautBreite
            haut = 1 - hautDaempfung * exp(-d * d)
        }
        return max(0, 1 + vibrance * blass * blass * haut * verstaerkung)
    }

    private static func wrapWinkel(_ a: Double) -> Double {
        var w = (a + .pi).truncatingRemainder(dividingBy: 2 * .pi)
        if w < 0 { w += 2 * .pi }
        return w - .pi
    }

    private static func clamp(_ c: (r: Double, g: Double, b: Double)) -> (Double, Double, Double) {
        (min(1, max(0, c.r)), min(1, max(0, c.g)), min(1, max(0, c.b)))
    }

    // MARK: - Anwenden

    /// Kantenlänge des Würfels: Vorschau (Maßstab < 1) 32, sonst 64. Der Aufbau kostet bei 64
    /// rund 262 000 Punkte je Reglerstellung; die Funktion ist glatt, 32 reicht zum Ziehen.
    static func dimension(forScale scale: CGFloat) -> Int {
        scale < 1 ? 32 : 64
    }

    /// Hängt den Würfel an `image`. Mit `vibrance == 0 && saturation == 1` kommt das Bild unverändert zurück.
    static func apply(to image: CIImage, vibrance: Double, saturation: Double = 1.0, dimension: Int) -> CIImage {
        guard vibrance != 0 || saturation != 1.0 else { return image }
        let f = CIFilter.colorCubeWithColorSpace()
        f.inputImage = image
        f.cubeDimension = Float(dimension)
        f.cubeData = cache.cubeData(vibrance: vibrance, saturation: saturation, dimension: dimension)
        f.colorSpace = CGColorSpace(name: CGColorSpace.displayP3)
        return f.outputImage ?? image
    }

    // MARK: - Cache

    /// Der Aufbau ist zu teuer für jeden Vorschau-Frame, der Regler aber meist unverändert.
    /// Vier Einträge, damit Vorschau (32) und Export (64) oder zwei Miniaturen nicht
    /// gegenseitig verdrängen.
    private final class Cache: @unchecked Sendable {
        private struct Key: Equatable { let vibrance: Double; let saturation: Double; let dimension: Int }
        private let lock = NSLock()
        private var eintraege: [(key: Key, data: Data)] = []

        func cubeData(vibrance: Double, saturation: Double, dimension: Int) -> Data {
            let key = Key(vibrance: vibrance, saturation: saturation, dimension: dimension)
            lock.lock()
            defer { lock.unlock() }
            if let treffer = eintraege.first(where: { $0.key == key }) { return treffer.data }
            let frisch = FarbCube.makeCubeData(vibrance: vibrance, saturation: saturation, dimension: dimension)
            eintraege.append((key, frisch))
            if eintraege.count > 4 { eintraege.removeFirst() }
            return frisch
        }
    }

    private static let cache = Cache()
}
