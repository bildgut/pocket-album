import CoreImage
import CoreImage.CIFilterBuiltins

/// Struktur und Klarheit: lokaler Kontrast über Unsharp-Mask mit Radius als Bruchteil der
/// langen Bildkante. Beide Entwickler-Pfade (RAW und JPEG) rufen dieselbe Rechnung auf, damit
/// derselbe Reglerwert dasselbe Bild ergibt.
///
/// Die Radien leiten sich aus `image.extent` ab und sind damit von selbst maßstabsfest —
/// Vorschau und Export sehen gleich aus. Mindestradius 1 px: Bei sehr kleinen Bildern
/// (Miniaturen, Tests) fielen die Bruchteil-Radien sonst unter die Wirkschwelle der Filter.
enum LokalerKontrast {

    /// Feine Details. `amount` −1…+1.
    static func textur(_ img: CIImage, amount: Double) -> CIImage {
        let lang = langeKante(img)
        guard amount != 0, lang > 0 else { return img }
        return detailContrast(
            img, amount: amount,
            sharpenRadius: max(1, 0.004 * lang), sharpenGain: 0.5,
            blurRadius: max(1, 0.002 * lang), blurMix: 0.35
        )
    }

    /// Mitten-Punch. `amount` −1…+1.
    static func klarheit(_ img: CIImage, amount: Double) -> CIImage {
        let lang = langeKante(img)
        guard amount != 0, lang > 0 else { return img }
        return detailContrast(
            img, amount: amount,
            sharpenRadius: max(1, 0.015 * lang), sharpenGain: 0.6,
            blurRadius: max(1, 0.008 * lang), blurMix: 0.35
        )
    }

    private static func langeKante(_ img: CIImage) -> CGFloat {
        max(img.extent.width, img.extent.height)
    }

    /// Positiver Wert = Unsharp-Mask mit großem Radius (lokaler Kontrast), negativer Wert =
    /// Mix Richtung Gauß-Weichzeichnung.
    private static func detailContrast(
        _ img: CIImage, amount: Double,
        sharpenRadius: CGFloat, sharpenGain: Double,
        blurRadius: CGFloat, blurMix: Double
    ) -> CIImage {
        let extent = img.extent
        if amount > 0 {
            let f = CIFilter.unsharpMask()
            f.inputImage = img.clampedToExtent()
            f.radius = Float(sharpenRadius)
            f.intensity = Float(sharpenGain * amount)
            return (f.outputImage ?? img).cropped(to: extent)
        } else {
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = img.clampedToExtent()
            blur.radius = Float(blurRadius)
            guard let blurred = blur.outputImage?.cropped(to: extent) else { return img }
            let mix = CIFilter.mix()
            mix.inputImage = blurred
            mix.backgroundImage = img
            mix.amount = Float(blurMix * -amount)
            return (mix.outputImage ?? img).cropped(to: extent)
        }
    }
}
