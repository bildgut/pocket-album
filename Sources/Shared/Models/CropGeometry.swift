import Foundation
import CoreGraphics

// MARK: - CropGeometry

/// Reine Geometrie des Beschnitt-Editors — keine Views, keine Zustände.
///
/// Der Beschnitt wird als `CGRect` in 0…1 **relativ zum einbeschriebenen Rechteck des
/// aktuellen Winkels** geführt. Ein Wert, drei Räume: Bildschirmpunkte (y oben),
/// Fraktion, Quellpixel in Core-Image-Koordinaten (y unten).
///
/// Weil die Fraktion relativ ist, bleibt sie beim Drehen gültig und schrumpft mit dem
/// einbeschriebenen Rechteck mit — das Verhalten von Fotos.app.
enum CropGeometry {

    /// Anteil des Bildes, der nach einer Drehung um `angleDegrees` als achsenparalleles
    /// Rechteck mit unverändertem Seitenverhältnis übrig bleibt.
    ///
    /// Diese Formel stand bisher zweimal im Projekt — einmal in der Vorschau, einmal im
    /// Encoder. Zwei Fassungen derselben Rechnung können auseinanderlaufen; die Anzeige
    /// hätte dann etwas anderes gezeigt als das Ergebnis.
    static func inscribedScale(size: CGSize, angleDegrees: Double) -> CGFloat {
        guard abs(angleDegrees) > 0.001, size.width > 0, size.height > 0 else { return 1 }
        let radians = abs(angleDegrees * .pi / 180)
        let cosA = abs(cos(radians))
        let sinA = abs(sin(radians))
        let s1 = size.width  / (size.width * cosA + size.height * sinA)
        let s2 = size.height / (size.width * sinA + size.height * cosA)
        return max(min(s1, s2), 0.01)   // Klemme gegen Division durch ~0 nahe 45°
    }

    static func inscribedSize(size: CGSize, angleDegrees: Double) -> CGSize {
        let scale = inscribedScale(size: size, angleDegrees: angleDegrees)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    /// `scaledToFit`-Rechteck des Bildes im Container, y oben.
    static func fitRect(imageSize: CGSize, container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              container.width > 0, container.height > 0 else { return .zero }

        let imageAspect = imageSize.width / imageSize.height
        let containerAspect = container.width / container.height
        let width  = imageAspect >= containerAspect ? container.width : container.height * imageAspect
        let height = imageAspect >= containerAspect ? container.width / imageAspect : container.height

        return CGRect(
            x: (container.width  - width)  / 2,
            y: (container.height - height) / 2,
            width: width,
            height: height
        )
    }

    /// Fraktion → Bildschirmrechteck innerhalb des sichtbaren Beschnittfensters.
    static func screenRect(fraction: CGRect, in window: CGRect) -> CGRect {
        CGRect(
            x: window.minX + fraction.minX * window.width,
            y: window.minY + fraction.minY * window.height,
            width:  fraction.width  * window.width,
            height: fraction.height * window.height
        )
    }

    /// Bildschirmrechteck → Fraktion.
    static func fraction(of rect: CGRect, in window: CGRect) -> CGRect {
        guard window.width > 0, window.height > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        return CGRect(
            x: (rect.minX - window.minX) / window.width,
            y: (rect.minY - window.minY) / window.height,
            width:  rect.width  / window.width,
            height: rect.height / window.height
        )
    }

    /// Fraktion → Quellpixel in Core-Image-Koordinaten.
    ///
    /// **Y-Flip:** SwiftUI zählt y von oben, Core Image von unten. Ohne die Umkehrung
    /// würde ein Beschnitt „oberes Drittel" im Ergebnis das untere Drittel liefern.
    static func ciRect(fraction: CGRect, inscribed: CGRect) -> CGRect {
        CGRect(
            x: inscribed.minX + fraction.minX * inscribed.width,
            y: inscribed.minY + (1 - fraction.maxY) * inscribed.height,
            width:  fraction.width  * inscribed.width,
            height: fraction.height * inscribed.height
        )
    }

    /// Klemmt eine Fraktion auf 0…1, erzwingt eine Mindestgröße in Quellpixeln und
    /// — falls gefordert — ein Seitenverhältnis.
    ///
    /// **Das Seitenverhältnis lebt in Pixeln, nicht in Fraktionen.** Das einbeschriebene
    /// Rechteck ist bei einem Winkel ≠ 0 kein Quadrat; wer die Fraktion direkt auf 1:1
    /// klemmt, bekommt ein schiefes Bild. Für ein Ergebnis im Verhältnis `r` muss gelten
    /// `frac.width · inscribedW / (frac.height · inscribedH) == r`.
    static func constrain(
        _ fraction: CGRect,
        aspect: CropAspect,
        inscribedPixels: CGSize,
        minSourcePixels: CGFloat = 64
    ) -> CGRect {
        guard inscribedPixels.width > 0, inscribedPixels.height > 0 else { return fraction }

        var result = fraction

        // Mindestgröße, ausgedrückt als Anteil
        let minW = min(minSourcePixels / inscribedPixels.width, 1)
        let minH = min(minSourcePixels / inscribedPixels.height, 1)
        result.size.width  = max(result.width,  minW)
        result.size.height = max(result.height, minH)

        if let ratio = aspect.ratio {
            // Umrechnung Pixel-Verhältnis → Fraktions-Verhältnis
            let fractionRatio = ratio * inscribedPixels.height / inscribedPixels.width
            // Die kleinere Ausdehnung führt, damit der Rahmen nie über den Rand wächst.
            let heightFromWidth = result.width / fractionRatio
            if heightFromWidth <= 1 {
                result.size.height = heightFromWidth
            } else {
                result.size.height = 1
                result.size.width  = fractionRatio
            }
        }

        result.size.width  = min(result.width,  1)
        result.size.height = min(result.height, 1)
        result.origin.x = min(max(result.minX, 0), 1 - result.width)
        result.origin.y = min(max(result.minY, 0), 1 - result.height)
        return result
    }

    static let full = CGRect(x: 0, y: 0, width: 1, height: 1)
}
