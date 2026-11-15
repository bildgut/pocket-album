import Foundation
import CoreGraphics

/// Rechenkern für bildbasierte Pipetten- und Zielwerkzeuge (Weißabgleich + HSL-Direktzieher).
///
/// Arbeitet rein auf `CGImage` und Zahlenwerten, damit Tests und geteilte Plattformen
/// ohne UI-Abhängigkeiten laufen.
enum BildPipette {

    /// Tastet einen quadratischen Bereich `(2*radius + 1)²` um den normierten Punkt (`0...1`,
    /// Ursprung oben links) aus `cgImage` ab und liefert gemittelte sRGB-Kanäle in `0...1`.
    static func sampleRGB(in cgImage: CGImage,
                          normalizedPoint: CGPoint,
                          radius: Int = 2) -> (r: Double, g: Double, b: Double)? {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0,
              normalizedPoint.x.isFinite, normalizedPoint.y.isFinite,
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
        }

        let nx = min(max(Double(normalizedPoint.x), 0), 1)
        let ny = min(max(Double(normalizedPoint.y), 0), 1)
        let cx = min(max(Int((nx * Double(width - 1)).rounded()), 0), width - 1)
        let cy = min(max(Int((ny * Double(height - 1)).rounded()), 0), height - 1)

        let rPx = max(0, radius)
        let x0 = max(0, cx - rPx)
        let y0 = max(0, cy - rPx)
        let x1 = min(width - 1, cx + rPx)
        let y1 = min(height - 1, cy + rPx)
        let patchW = x1 - x0 + 1
        let patchH = y1 - y0 + 1

        let cropRect = CGRect(x: x0, y: y0, width: patchW, height: patchH)
        guard let cropped = cgImage.cropping(to: cropRect) else { return nil }

        var pixels = [UInt8](repeating: 0, count: patchW * patchH * 4)
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let drew: Bool = pixels.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress,
                  let ctx = CGContext(
                      data: base,
                      width: patchW,
                      height: patchH,
                      bitsPerComponent: 8,
                      bytesPerRow: patchW * 4,
                      space: colorSpace,
                      bitmapInfo: bitmapInfo
                  ) else {
                return false
            }
            ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: patchW, height: patchH))
            return true
        }
        guard drew else { return nil }

        var sumR = 0.0
        var sumG = 0.0
        var sumB = 0.0
        var count = 0.0

        for idx in stride(from: 0, to: pixels.count, by: 4) {
            let a = Double(pixels[idx + 3])
            guard a > 0 else { continue }
            sumR += Double(pixels[idx]) / a
            sumG += Double(pixels[idx + 1]) / a
            sumB += Double(pixels[idx + 2]) / a
            count += 1
        }
        guard count > 0 else { return nil }

        return (
            r: min(max(sumR / count, 0), 1),
            g: min(max(sumG / count, 0), 1),
            b: min(max(sumB / count, 0), 1)
        )
    }

    /// Berechnet korrigierte Weißabgleich-Werte (`temperature` in Kelvin, `tint` in `-150...150`),
    /// die einen an der aktuellen Position als neutral gedachten RGB-Stich kompensieren.
    ///
    /// Liefert `nil`, wenn das Sample faktisch schwarz oder in allen Kanälen ausgebrannt ist
    /// (kein verlässliches Farbverhältnis messbar).
    static func whiteBalance(fromRGB r: Double,
                             g: Double,
                             b: Double,
                             currentTemperature: Double,
                             currentTint: Double) -> (temperature: Double, tint: Double)? {
        guard max(r, g, b) > 0.04, min(r, g, b) < 0.97 else {
            return nil
        }

        let linR = pow(max(r, 1e-4), 2.2)
        let linG = pow(max(g, 1e-4), 2.2)
        let linB = pow(max(b, 1e-4), 2.2)

        // Ist B > R (zu kalt/blau), wird `deltaMired < 0` -> höhere Kelvin (wärmere Kompensation).
        // Ist R > B (zu warm/gelb), wird `deltaMired > 0` -> niedrigere Kelvin (kühlere Kompensation).
        let safeTemp = min(max(currentTemperature, 2000), 12000)
        let currentMired = 1_000_000.0 / safeTemp
        let deltaMired = -120.0 * log(linB / linR)
        let minMired = 1_000_000.0 / 12000.0
        let maxMired = 1_000_000.0 / 2000.0
        let targetMired = min(max(currentMired + deltaMired, minMired), maxMired)
        let newTemperature = min(max((1_000_000.0 / targetMired).rounded(), 2000), 12000)

        // Ist G größer als das geometrische Mittel aus R und B (Grünstich), verschiebt +Tönung
        // Richtung Magenta; bei Magentastich entsprechend negativ Richtung Grün.
        let greenBaseline = sqrt(linR * linB)
        let deltaTint = 140.0 * log(linG / greenBaseline)
        let newTint = min(max((currentTint + deltaTint).rounded(), -150), 150)

        return (temperature: newTemperature, tint: newTint)
    }

    /// Ermittelt die acht HSL-Bandgewichte (`HSLBandID.allCases`) für einen abgetasteten RGB-Farbton.
    ///
    /// Sehr entsättigte Grauwerte liefern ein Null-Array, um beim Ziehen auf neutralen Flächen
    /// nicht unbeabsichtigt an einem zufälligen Restfarbton zu drehen.
    static func hslTargetWeights(fromRGB r: Double, g: Double, b: Double) -> [Double] {
        let hsl = HSLColorCube.rgbToHSL(
            r: min(max(r, 0), 1),
            g: min(max(g, 0), 1),
            b: min(max(b, 0), 1)
        )
        guard hsl.s >= 0.02 else {
            return Array(repeating: 0, count: HSLBandID.allCases.count)
        }
        return HSLColorCube.bandWeights(hueDegrees: hsl.h, narrowOrange: true)
    }
}
