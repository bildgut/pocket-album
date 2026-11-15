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
    static func makeCubeData(mixer: HSLMixerParams, dimension: Int = 64, okLab: Bool = false) -> Data {
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
                    let (or_, og, ob) = okLab
                        ? adjustOkLab(r: rf, g: gf, b: bf, bands: bands)
                        : adjust(r: rf, g: gf, b: bf, bands: bands)
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

    /// Wahrnehmungsgetreue Farbmischer-Variante in OkLCh (`farbModell >= 2`): Farbtondrehung
    /// bewahrt die empfundene Helligkeit, schützt Hauttöne durch engere Orange/Gelb-Bänder
    /// und projiziert Überschreitungen ins Display-P3-Gamut statt hart zu clampen.
    static func adjustOkLab(r: Double, g: Double, b: Double, bands: [HSLBand]) -> (Double, Double, Double) {
        let (h, _, _) = rgbToHSL(r: r, g: g, b: b)
        let lab = OkLab.fromEncodedP3(r: r, g: g, b: b)
        let chroma = hypot(lab.a, lab.b)
        guard chroma > 1e-5 else { return (r, g, b) }

        let chromaGate = smoothstep(edge0: 0.008, edge1: 0.045, x: chroma)
        let weights = bandWeights(hueDegrees: h, narrowOrange: true)

        var hueShiftRad = 0.0
        var satGain = 0.0
        var lumShift = 0.0
        for (i, band) in bands.enumerated() {
            let w = weights[i] * chromaGate
            guard w != 0 else { continue }
            hueShiftRad += w * (band.hue / 100.0) * (22.0 * .pi / 180.0)
            satGain += w * (band.sat / 100.0) * 0.50
            lumShift += w * (band.lum / 100.0) * 0.16
        }

        guard hueShiftRad != 0 || satGain != 0 || lumShift != 0 else { return (r, g, b) }

        let theta = atan2(lab.b, lab.a) + hueShiftRad
        let cNeu = max(0.0, chroma * (1.0 + satGain))
        let lNeu = min(1.0, max(0.0, lab.L + lumShift * lab.L * (1.0 - lab.L) * 2.2))
        let aNeu = cNeu * cos(theta)
        let bNeu = cNeu * sin(theta)

        let rgb = OkLab.toEncodedP3(L: lNeu, a: aNeu, b: bNeu)
        if OkLab.istImGamut(rgb) {
            return (min(1, max(0, rgb.r)), min(1, max(0, rgb.g)), min(1, max(0, rgb.b)))
        }

        var lo = 0.0, hi = 1.0
        for _ in 0 ..< 10 {
            let mid = (lo + hi) / 2
            let probe = OkLab.toEncodedP3(L: lNeu, a: aNeu * mid, b: bNeu * mid)
            if OkLab.istImGamut(probe) { lo = mid } else { hi = mid }
        }
        let clamped = OkLab.toEncodedP3(L: lNeu, a: aNeu * lo, b: bNeu * lo)
        return (min(1, max(0, clamped.r)), min(1, max(0, clamped.g)), min(1, max(0, clamped.b)))
    }

    /// Raised-Cosine-Gewichte aller 8 Bänder für einen Farbton (Grad). Die Bandbreite
    /// reicht jeweils bis zu den Nachbarzentren; die Gewichte sind normiert (Summe 1,
    /// sofern überhaupt ein Band greift). Mit `narrowOrange` wird der Übergang um Orange/Gelb
    /// enger gefasst, damit Gelb-Verschiebungen Hauttöne nicht mitziehen.
    static func bandWeights(hueDegrees: Double, narrowOrange: Bool = false) -> [Double] {
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
            let effectiveWidth = (narrowOrange && (i == 1 || i == 2)) ? width * 0.8 : width

            let d = abs(signed)
            if d < effectiveWidth {
                weights[i] = 0.5 * (1 + cos(Double.pi * d / effectiveWidth))
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
