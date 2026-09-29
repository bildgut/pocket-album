import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

/// Wendet einen ``FilmLook`` auf ein `CIImage` an — dieselbe Stufe für den RAW-Pfad
/// (hinter `RawDevelopEngine.applyToneStage`) und den JPEG-Pfad (hinter
/// `ImageAdjustmentsService.applyPipeline`). Reine Funktion ohne Zustand, bis auf den
/// Würfel-Cache.
///
/// Reihenfolge: Basisregler (Weißabgleich, Belichtung, Lichter/Schatten, Klarheit — über
/// `RawDevelopEngine.applyToneStage`), dann HSL-Mixer **vor** Kanalkurven, Kurve und Entsättigung, damit Farbfilter-Simulationen
/// in Schwarzweiß-Looks greifen (Gelbfilter: Blau abdunkeln, Orange aufhellen — auf
/// einem bereits grauen Bild hätte der Mixer nichts mehr zu mischen). Danach Kurve,
/// Kontrast/Sättigung, Vibrance, Split-Toning, Korn, und zuletzt die Mischung mit dem
/// Eingangsbild als Stärke-Regler.
enum FilmLookRenderer {

    /// - Parameters:
    ///   - staerke: 0…1; 0 gibt das Eingangsbild unverändert zurück, ohne einen Filter
    ///     zu bauen.
    ///   - scale: Rendermaßstab, wie bei `applyToneStage` — steuert nur die Korngröße.
    ///   - cubeDimension: Kantenlänge des HSL-Würfels. 16 für Miniaturen (64 KB, unter
    ///     1 ms), 64 für Vorschau und Export (4 MB). Siehe Spec, Abschnitt 3.
    static func apply(
        _ image: CIImage,
        look: FilmLook?,
        staerke: Double,
        scale: CGFloat,
        cubeDimension: Int
    ) -> CIImage {
        guard let look, staerke > 0, !look.isIdentity else { return image }
        let extent = image.extent
        var img = image

        // ── Basisstufe (Lightroom-Reihenfolge: Weißabgleich → Belichtung → Grundregler) ──
        // Vor dem Clamp, damit Lichter-Rettung noch an Extended-Range-Werten arbeiten kann.
        if look.waerme != 0 || look.toenung != 0 {
            let f = CIFilter.temperatureAndTint()
            f.inputImage = img
            f.neutral = CIVector(x: 6500 + look.waerme * 20, y: look.toenung)
            f.targetNeutral = CIVector(x: 6500, y: 0)
            img = f.outputImage ?? img
        }
        if look.belichtung != 0 {
            let f = CIFilter.exposureAdjust()
            f.inputImage = img
            f.ev = Float(look.belichtung)
            img = f.outputImage ?? img
        }
        if look.lichter != 0 || look.schatten != 0 || look.weiss != 0 || look.schwarz != 0
            || look.klarheit != 0 || look.struktur != 0 || look.dunst != 0 {
            var basis = RawDevelopParams()
            basis.highlights = look.lichter; basis.shadows = look.schatten
            basis.whites = look.weiss; basis.blacks = look.schwarz
            basis.clarity = look.klarheit; basis.texture = look.struktur; basis.dehaze = look.dunst
            img = RawDevelopEngine.applyToneStage(img, params: basis, scale: scale)
        }

        // Auf 0…1 begrenzen: Der Würfel clampt ohnehin, und die Kurve rechnet dann auf
        // demselben Bereich — egal ob das Bild aus dem CIRAWFilter (Extended Range) oder
        // aus einem JPEG kommt.
        let clamp = CIFilter.colorClamp()
        clamp.inputImage = img
        clamp.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        clamp.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
        img = clamp.outputImage ?? img

        if !look.hsl.isIdentity {
            let f = CIFilter.colorCubeWithColorSpace()
            f.inputImage = img
            f.cubeDimension = Float(cubeDimension)
            f.cubeData = cubeCache.data(for: look.hsl, dimension: cubeDimension)
            f.colorSpace = CGColorSpace(name: CGColorSpace.displayP3)
            img = f.outputImage ?? img
        }

        // Kurven je Kanal — vor der gemeinsamen Kurve, wie in Pixelmators Kette (r/g/b → rgb).
        // Die Tabelle gilt im sRGB-Raum; CIToneCurve darunter arbeitet im Working Space.
        if let kanal = look.kanalkurven, !kanal.isIdentity {
            let f = CIFilter.colorCurves()
            f.inputImage = img
            f.curvesData = kanal.tabelle(256).withUnsafeBufferPointer { Data(buffer: $0) }
            f.curvesDomain = CIVector(x: 0, y: 1)
            f.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
            img = f.outputImage ?? img
        }

        if !look.kurve.isIdentity {
            let f = CIFilter(name: "CIToneCurve")!
            f.setValue(img, forKey: kCIInputImageKey)
            for (i, p) in look.kurve.points.enumerated() {
                f.setValue(CIVector(x: p.x, y: p.y), forKey: "inputPoint\(i)")
            }
            img = f.outputImage ?? img
        }

        if look.kontrast != 1 || look.saettigung != 1 {
            let f = CIFilter.colorControls()
            f.inputImage = img
            f.brightness = 0
            f.contrast = Float(look.kontrast)
            f.saturation = Float(look.saettigung)
            img = f.outputImage ?? img
        }

        if look.vibrance != 0 {
            let f = CIFilter(name: "CIVibrance")!
            f.setValue(img, forKey: kCIInputImageKey)
            f.setValue(Float(look.vibrance), forKey: "inputAmount")
            img = f.outputImage ?? img
        }

        if let toning = look.splitToning, !toning.isIdentity {
            img = applySplitToning(img, toning: toning, extent: extent)
        }

        // Vignette wie in RawDevelopEngine.applyToneStage: Radius drei Viertel der halben
        // Diagonale, vor dem Korn — Korn soll auch in den abgedunkelten Ecken liegen.
        if look.vignette > 0, extent.width > 0, extent.height > 0 {
            let diagonal = (extent.width * extent.width + extent.height * extent.height).squareRoot()
            let f = CIFilter.vignetteEffect()
            f.inputImage = img
            f.center = CGPoint(x: extent.midX, y: extent.midY)
            f.radius = Float(0.75 * diagonal / 2)
            f.intensity = Float(look.vignette / 100)
            img = (f.outputImage ?? img).cropped(to: extent)
        }

        if look.korn > 0, max(extent.width, extent.height) > 0 {
            img = RawDevelopEngine.applyGrain(img, amount: look.korn / 100, scale: scale)
        }

        img = img.cropped(to: extent)

        if staerke < 1 {
            let mix = CIFilter.mix()
            mix.inputImage = img
            mix.backgroundImage = image
            mix.amount = Float(staerke)
            img = (mix.outputImage ?? img).cropped(to: extent)
        }
        return img
    }

    // MARK: - Split-Toning

    /// Zwei per Soft-Light getönte Kopien, über eine Luminanzmaske (und ihre Inverse)
    /// gegen das Bild geblendet. `balance` verschiebt die Maske per Gamma: negativ
    /// zählt mehr Tonwerte zu den Schatten, positiv mehr zu den Lichtern.
    private static func applySplitToning(
        _ img: CIImage, toning: SplitToning, extent: CGRect
    ) -> CIImage {
        // Luminanz (Rec. 709) in alle drei Kanäle.
        let luma = CIFilter.colorMatrix()
        luma.inputImage = img
        let w = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        luma.rVector = w; luma.gVector = w; luma.bVector = w
        luma.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        luma.biasVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        guard var mask = luma.outputImage else { return img }

        if toning.balance != 0 {
            let gamma = CIFilter.gammaAdjust()
            gamma.inputImage = mask
            gamma.power = Float(pow(2, -toning.balance / 100))
            mask = gamma.outputImage ?? mask
        }

        var out = img
        if toning.schattenStaerke > 0 {
            // Schattenmaske = (1 − L) · Stärke
            let s = CGFloat(toning.schattenStaerke / 100)
            out = blendTint(
                out, farbton: toning.schattenFarbton, extent: extent,
                mask: scaledMask(mask, scale: -s, bias: s)
            )
        }
        if toning.lichterStaerke > 0 {
            // Lichtermaske = L · Stärke
            let s = CGFloat(toning.lichterStaerke / 100)
            out = blendTint(
                out, farbton: toning.lichterFarbton, extent: extent,
                mask: scaledMask(mask, scale: s, bias: 0)
            )
        }
        return out
    }

    /// `out = scale · L + bias`, kanalgleich.
    private static func scaledMask(_ mask: CIImage, scale: CGFloat, bias: CGFloat) -> CIImage {
        let f = CIFilter.colorMatrix()
        f.inputImage = mask
        f.rVector = CIVector(x: scale, y: 0, z: 0, w: 0)
        f.gVector = CIVector(x: 0, y: scale, z: 0, w: 0)
        f.bVector = CIVector(x: 0, y: 0, z: scale, w: 0)
        f.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        f.biasVector = CIVector(x: bias, y: bias, z: bias, w: 0)
        return f.outputImage ?? mask
    }

    private static func blendTint(
        _ img: CIImage, farbton: Double, extent: CGRect, mask: CIImage
    ) -> CIImage {
        let rgb = SplitToning.rgb(farbton: farbton)
        let color = CIImage(color: CIColor(red: rgb.r, green: rgb.g, blue: rgb.b)).cropped(to: extent)

        let tint = CIFilter.softLightBlendMode()
        tint.inputImage = color
        tint.backgroundImage = img
        guard let tinted = tint.outputImage?.cropped(to: extent) else { return img }

        let blend = CIFilter.blendWithMask()
        blend.inputImage = tinted
        blend.backgroundImage = img
        blend.maskImage = mask
        return (blend.outputImage ?? img).cropped(to: extent)
    }

    // MARK: - Würfel-Cache

    /// Anders als der Ein-Eintrag-Cache in `RawDevelopEngine` (zugeschnitten auf „ein
    /// Nutzer bewegt einen Mixer-Regler") hält dieser den ganzen Katalog: 16 Looks bei
    /// Dimension 16 sind rund 1 MB. Läuft die Summe über die Grenze — etwa durch mehrere
    /// 64er-Würfel à 4 MB —, wird schlicht alles verworfen; eine LRU-Buchführung lohnt
    /// bei diesen Größen nicht.
    private final class CubeCache: @unchecked Sendable {
        private struct Key: Hashable {
            let mixer: HSLMixerParams
            let dimension: Int
        }

        private static let maxBytes = 24 * 1024 * 1024
        private let lock = NSLock()
        private var entries: [Key: Data] = [:]
        private var bytes = 0

        func data(for mixer: HSLMixerParams, dimension: Int) -> Data {
            let key = Key(mixer: mixer, dimension: dimension)
            lock.lock()
            defer { lock.unlock() }
            if let cached = entries[key] { return cached }
            let fresh = HSLColorCube.makeCubeData(mixer: mixer, dimension: dimension)
            if bytes + fresh.count > Self.maxBytes {
                entries.removeAll()
                bytes = 0
            }
            entries[key] = fresh
            bytes += fresh.count
            return fresh
        }
    }

    private static let cubeCache = CubeCache()
}
