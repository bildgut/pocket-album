import Foundation
import CoreGraphics

/// Baut die 3D-LUT (`CIColorCubeWithColorSpace`-Format) für den Farbmischer.
///
/// Reine CPU-Mathematik ohne CoreImage — deterministisch und ohne GPU/Metal-Kontext
/// unit-testbar. Die LUT wird von `RawDevelopEngine` nach der Ton-Kette angewendet
/// (Cube-Werte sind auf 0…1 geclampt, Extended-Range-Lichter also vorher abwickeln).
///
/// Bandmodell wie Lightrooms Farbmischer: 8 Bänder mit Raised-Cosine-Falloff zwischen
/// den Nachbarzentren. Neutralschutz: Bei (fast) unbunten Farben läuft die Wirkung über
/// `smoothstep` gegen 0, damit Grau nicht mitverschoben wird.
enum HSLColorCube {

    /// Zentren der 8 Bänder in Grad, Reihenfolge = `HSLBandID.allCases`.
    static let bandCenters: [Double] = HSLBandID.allCases.map(\.hueDegrees)

    // MARK: - LUT

    /// RGBA-Float-Würfel für `CIColorCubeWithColorSpace` (dimension³ × 4 Floats).
    static func makeCubeData(mixer: HSLMixerParams, dimension: Int = 64) -> Data {
        let dim = max(2, dimension)
        var cube = [Float](repeating: 0, count: dim * dim * dim * 4)
        let bands = HSLBandID.allCases.map { mixer[$0] }

        var offset = 0
        for b in 0 ..< dim {
            let bf = Double(b) / Double(dim - 1)
            for g in 0 ..< dim {
                let gf = Double(g) / Double(dim - 1)
                for r in 0 ..< dim {
                    let rf = Double(r) / Double(dim - 1)
                    let (or_, og, ob) = adjust(r: rf, g: gf, b: bf, bands: bands)
                    cube[offset]     = Float(or_)
                    cube[offset + 1] = Float(og)
                    cube[offset + 2] = Float(ob)
                    cube[offset + 3] = 1
                    offset += 4
                }
            }
        }
        return cube.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    // MARK: - Ein Farbwert

    /// Wendet den Mixer auf genau einen RGB-Wert (0…1) an — der Kern der LUT, einzeln
    /// aufrufbar für Tests.
    static func adjust(r: Double, g: Double, b: Double, bands: [HSLBand]) -> (Double, Double, Double) {
        var (h, s, l) = rgbToHSL(r: r, g: g, b: b)

        let weights = bandWeights(hueDegrees: h)
        // Neutralschutz: unbunte Pixel (Grau, fast-Grau) bleiben unangetastet.
        let chromaGate = smoothstep(edge0: 0.02, edge1: 0.15, x: s)

        var hueShift = 0.0
        var satGain = 0.0
        var lumShift = 0.0
        for (i, band) in bands.enumerated() {
            let w = weights[i] * chromaGate
            guard w != 0 else { continue }
            hueShift += w * (band.hue / 100) * 30
            satGain  += w * (band.sat / 100) * 0.6
            lumShift += w * (band.lum / 100) * 0.25
        }

        h = (h + hueShift).truncatingRemainder(dividingBy: 360)
        if h < 0 { h += 360 }
        s = min(1, max(0, s * (1 + satGain)))
        // Mittenbetont (l·(1−l)): Schwarz und Weiß bleiben liegen, kein Clipping-Sprung.
        l = min(1, max(0, l + lumShift * l * (1 - l) * 2))

        return hslToRGB(h: h, s: s, l: l)
    }

    /// Raised-Cosine-Gewichte aller 8 Bänder für einen Farbton (Grad). Die Bandbreite
    /// reicht jeweils bis zu den Nachbarzentren; die Gewichte sind normiert (Summe 1,
    /// sofern überhaupt ein Band greift).
    static func bandWeights(hueDegrees: Double) -> [Double] {
        var h = hueDegrees.truncatingRemainder(dividingBy: 360)
        if h < 0 { h += 360 }

        let centers = bandCenters
        var weights = [Double](repeating: 0, count: centers.count)
        for (i, center) in centers.enumerated() {
            // Vorzeichenbehafteter zirkulärer Abstand zum Bandzentrum (−180…+180)
            var signed = h - center
            if signed > 180 { signed -= 360 }
            if signed < -180 { signed += 360 }

            // Bandbreite in dieser Richtung = Abstand zum jeweiligen Nachbarzentrum
            let prev = centers[(i + centers.count - 1) % centers.count]
            let next = centers[(i + 1) % centers.count]
            var toPrev = center - prev
            if toPrev <= 0 { toPrev += 360 }
            var toNext = next - center
            if toNext <= 0 { toNext += 360 }
            let width = signed >= 0 ? toNext : toPrev

            let d = abs(signed)
            if d < width {
                weights[i] = 0.5 * (1 + cos(Double.pi * d / width))
            }
        }

        let sum = weights.reduce(0, +)
        guard sum > 0 else { return weights }
        return weights.map { $0 / sum }
    }

    // MARK: - Farbraum-Helfer

    static func smoothstep(edge0: Double, edge1: Double, x: Double) -> Double {
        let t = min(1, max(0, (x - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }

    /// RGB (0…1) → HSL, Farbton in Grad (0…360).
    static func rgbToHSL(r: Double, g: Double, b: Double) -> (h: Double, s: Double, l: Double) {
        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        let l = (maxC + minC) / 2
        guard maxC != minC else { return (0, 0, l) }

        let d = maxC - minC
        let s = l > 0.5 ? d / (2 - maxC - minC) : d / (maxC + minC)
        var h: Double
        if maxC == r {
            h = (g - b) / d + (g < b ? 6 : 0)
        } else if maxC == g {
            h = (b - r) / d + 2
        } else {
            h = (r - g) / d + 4
        }
        return (h * 60, s, l)
    }

    /// HSL (Farbton in Grad) → RGB (0…1).
    static func hslToRGB(h: Double, s: Double, l: Double) -> (Double, Double, Double) {
        guard s > 0 else { return (l, l, l) }
        let c = (1 - abs(2 * l - 1)) * s
        let hp = h / 60
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let (r1, g1, b1): (Double, Double, Double)
        switch hp {
        case ..<1: (r1, g1, b1) = (c, x, 0)
        case ..<2: (r1, g1, b1) = (x, c, 0)
        case ..<3: (r1, g1, b1) = (0, c, x)
        case ..<4: (r1, g1, b1) = (0, x, c)
        case ..<5: (r1, g1, b1) = (x, 0, c)
        default:   (r1, g1, b1) = (c, 0, x)
        }
        let m = l - c / 2
        return (r1 + m, g1 + m, b1 + m)
    }
}
