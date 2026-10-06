import Foundation

// MARK: - AutoToneResult

/// Vorschlagswerte des Auto-Tons — Sliderwerte, keine opaken Filter: Der Nutzer sieht
/// nach dem Klick, WAS Auto getan hat, und kann jeden Regler weiterbewegen.
struct AutoToneResult: Equatable, Sendable {
    var exposure: Double = 0     // EV
    var contrast: Double = 1
    var highlights: Double = 0   // −100…+100
    var shadows: Double = 0
    var whites: Double = 0
    var blacks: Double = 0
}

// MARK: - AutoTone

/// Histogramm-basierte Auto-Ton-Heuristik (bewusst NICHT `CIImage.autoAdjustmentFilters`,
/// deren Ergebnis sich nicht auf Regler zurückrechnen lässt).
///
/// Erwartet die **rohen** Luminanz-Zählungen (256 Bins, unnormalisiert) aus
/// `ImageAdjustmentsService.computeHistogram` — gemessen an einer neutral entwickelten
/// Fassung, damit die Statistik das unbearbeitete Bild beschreibt.
enum AutoTone {

    static func suggest(luminanceCounts: [Double]) -> AutoToneResult {
        let total = luminanceCounts.reduce(0, +)
        guard luminanceCounts.count == 256, total > 0 else { return AutoToneResult() }

        func percentile(_ p: Double) -> Double {
            let target = p * total
            var cumulative = 0.0
            for (bin, count) in luminanceCounts.enumerated() {
                cumulative += count
                if cumulative >= target { return Double(bin) / 255 }
            }
            return 1
        }

        var result = AutoToneResult()

        // Belichtung: Median Richtung Mittelgrau (0.42 ≈ 18 % Grau in sRGB-Gamma).
        let median = max(0.004, percentile(0.5))
        result.exposure = clamp(0.7 * log2(0.42 / median), -1.5, 1.5)

        // Lichter-Rettung proportional zum geclippten Anteil (≥ Bin 250).
        let highClipFraction = luminanceCounts[250...].reduce(0, +) / total
        result.highlights = -min(80, highClipFraction * 800)

        // Schatten-Aufhellung proportional zum abgesoffenen Anteil (≤ Bin 10).
        let lowFraction = luminanceCounts[...10].reduce(0, +) / total
        result.shadows = min(60, lowFraction * 600)

        // Schwarz/Weiß: p0.1 auf 0.02 und p99.9 auf 0.98 legen — über die Umkehrung
        // des Engine-Mappings (`blacks < 0` ⇒ bp = |n|/100·0.2; `whites > 0` ⇒
        // Weiß strecken um 0.1·n/100).
        let p001 = percentile(0.001)
        if p001 > 0.02 {
            result.blacks = -min(100, (p001 - 0.02) / 0.2 * 100)
        }
        let p999 = percentile(0.999)
        if p999 < 0.98 {
            result.whites = min(50, (0.98 - p999) / 0.1 * 100)
        }

        // Kontrast aus dem Interquartilsabstand: flache Histogramme anheben,
        // schon kontrastreiche in Ruhe lassen.
        let iqr = percentile(0.75) - percentile(0.25)
        result.contrast = clamp(1 + 0.6 * (0.5 - iqr), 0.85, 1.25)

        // Auf Anzeige-Genauigkeit runden — die UI zeigt ganze Slider-Einheiten.
        result.exposure = (result.exposure * 100).rounded() / 100
        result.contrast = (result.contrast * 100).rounded() / 100
        result.highlights = result.highlights.rounded()
        result.shadows = result.shadows.rounded()
        result.whites = result.whites.rounded()
        result.blacks = result.blacks.rounded()
        return result
    }

    private static func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(upper, max(lower, value))
    }
}

// MARK: - Anwendung auf RawDevelopParams

extension RawDevelopParams {
    /// Überschreibt genau die Tonwert-Regler mit dem Auto-Vorschlag; Weißabgleich,
    /// Farbe, Detail, Effekte und Farbmischer bleiben unangetastet.
    mutating func applyAutoTone(_ result: AutoToneResult) {
        exposure = result.exposure
        contrast = result.contrast
        highlights = result.highlights
        shadows = result.shadows
        whites = result.whites
        blacks = result.blacks
    }
}
