import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers

// MARK: - Errors

enum RawDevelopEngineError: LocalizedError {
    case unsupportedFormat
    case renderFailed
    case encodeFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return "Das RAW-Format wird nicht unterstützt."
        case .renderFailed:
            return "Das RAW-Bild konnte nicht gerendert werden."
        case .encodeFailed:
            return "Das entwickelte Bild konnte nicht gespeichert werden."
        }
    }
}

/// RAW-Entwicklung via `CIRAWFilter`: Stufe 1 (CIRAWFilter-eigene Properties, dateiabhängige
/// Defaults) + Stufe 2 (nachgelagerte `CIFilter`-Tonkette, feste Defaults — Rezepte aus
/// `ImageAdjustmentsService.applyPipeline` übernommen).
///
/// Eine Instanz hält genau EINEN `CIRAWFilter` (das Parsen des DNGs ist teuer); `renderPreview`
/// mutiert nur dessen Properties und rendert erneut. `renderExport` erzeugt bewusst einen
/// FRISCHEN `CIRAWFilter` (Draft aus, `scaleFactor` 1) auf einem `static`-Kontext, damit
/// Voll-Auflösung nicht von einer zuvor per Draft-Preview verkleinerten Instanz "vererbt" wird.
actor RawDevelopEngine {

    /// Geteilter `CIContext` (Muster von `ImageAdjustmentsService`): Hardware-Renderer, kein
    /// Software-Fallback.
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    private let filter: CIRAWFilter

    /// As-shot-Weißabgleich, gelesen direkt nach dem Parsen — Seed für die WB-Regler in der UI.
    nonisolated let asShotTemperature: Double
    nonisolated let asShotTint: Double

    /// Kamera-/Datei-Defaults der Stufe-1-Properties, direkt nach dem Parsen gesichert.
    ///
    /// Nötig, weil dieselbe `CIRAWFilter`-Instanz über viele Previews wiederverwendet
    /// wird: Ein einmal gesetzter Wert bliebe sonst am Filter kleben, auch wenn der
    /// Parameter wieder auf `nil` („Kamera-Standard") zurückspringt.
    private struct Stage1Defaults {
        let luminanceNR: Float
        let colorNR: Float
        let sharpness: Float
    }
    private let stage1Defaults: Stage1Defaults

    init(rawFileURL: URL) throws {
        guard let filter = CIRAWFilter(imageURL: rawFileURL) else {
            throw RawDevelopEngineError.unsupportedFormat
        }
        self.filter = filter
        self.asShotTemperature = Double(filter.neutralTemperature)
        self.asShotTint = Double(filter.neutralTint)
        self.stage1Defaults = Stage1Defaults(
            luminanceNR: filter.luminanceNoiseReductionAmount,
            colorNR: filter.colorNoiseReductionAmount,
            sharpness: filter.sharpnessAmount
        )
    }

    // MARK: - Preview

    /// Schnelles Vorschau-Rendering (Draft-Modus, verkleinert). `maxPixel` begrenzt die lange
    /// Kante; `filter.scaleFactor` wird daraus relativ zur nativen Größe berechnet.
    func renderPreview(params: RawDevelopParams, maxPixel: CGFloat) -> CGImage? {
        applyStage1Resetting(params: params)

        filter.isDraftModeEnabled = true
        let longestEdge = max(filter.nativeSize.width, filter.nativeSize.height)
        if longestEdge > 0 {
            filter.scaleFactor = Float(min(1, maxPixel / longestEdge))
        } else {
            filter.scaleFactor = 1
        }

        guard let rawOutput = filter.outputImage else { return nil }
        let renderScale = longestEdge > 0 ? min(1, maxPixel / longestEdge) : 1
        let toned = Self.applyToneStage(rawOutput, params: params, scale: renderScale)
        return Self.ciContext.createCGImage(toned, from: toned.extent)
    }

    // MARK: - Export

    /// Voll-Auflösungs-Export als HEIC inkl. Metadaten. Statisch, damit ein frischer
    /// `CIRAWFilter` (unabhängig von etwaigen Draft-Previews derselben Engine-Instanz) genutzt
    /// wird — Draft AUS, `scaleFactor` 1.
    ///
    /// - Parameter cropFraction: optionaler Zuschnitt, normiert 0…1 mit Ursprung OBEN
    ///   links (Rasterraum — der `CIRAWFilter`-Output ist bereits physisch orientiert,
    ///   Orientation wird ohnehin auf 1 gesetzt). Genutzt vom KI-Zuschnitt.
    static func renderExport(
        rawFileURL: URL, params: RawDevelopParams, cropFraction: CGRect? = nil
    ) throws -> Data {
        try autoreleasepool {
            guard let exportFilter = CIRAWFilter(imageURL: rawFileURL) else {
                throw RawDevelopEngineError.unsupportedFormat
            }
            exportFilter.isDraftModeEnabled = false
            exportFilter.scaleFactor = 1
            applyStage1(to: exportFilter, params: params)

            guard let rawOutput = exportFilter.outputImage else {
                throw RawDevelopEngineError.renderFailed
            }
            let toned = applyToneStage(rawOutput, params: params, scale: 1)

            guard let colorSpace = CGColorSpace(name: CGColorSpace.displayP3) else {
                throw RawDevelopEngineError.renderFailed
            }
            guard var rendered = ciContext.createCGImage(
                toned, from: toned.extent, format: .RGBA8, colorSpace: colorSpace
            ) else {
                throw RawDevelopEngineError.renderFailed
            }

            if let cropFraction {
                let px = GeminiCropService.pixelRect(
                    fraction: cropFraction,
                    imageSize: CGSize(width: rendered.width, height: rendered.height)
                )
                guard px.width > 1, px.height > 1, let cropped = rendered.cropping(to: px) else {
                    throw RawDevelopEngineError.renderFailed
                }
                rendered = cropped
            }

            let outputData = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(
                outputData, UTType.heic.identifier as CFString, 1, nil
            ) else {
                throw RawDevelopEngineError.encodeFailed
            }

            // Metadaten vom DNG übernehmen, aber die RAW-spezifischen Rohdaten-Dictionaries
            // entfernen (im HEIC sinnlos/nicht gültig) und Orientation zurücksetzen: der
            // CIRAWFilter-Output ist bereits orientiert (Pixel physisch gedreht), eine
            // übernommene EXIF-Orientation aus dem DNG würde eine zweite, doppelte Drehung
            // bei der Anzeige bewirken.
            var destProperties: [CFString: Any] = [:]
            if let source = CGImageSourceCreateWithURL(rawFileURL as CFURL, nil),
               let sourceProps = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                destProperties = sourceProps
            }
            destProperties.removeValue(forKey: kCGImagePropertyDNGDictionary)
            destProperties.removeValue(forKey: kCGImagePropertyRawDictionary)
            destProperties[kCGImagePropertyOrientation] = 1
            destProperties[kCGImageDestinationLossyCompressionQuality] = 0.9
            destProperties[kCGImageDestinationMergeMetadata] = true

            CGImageDestinationAddImage(dest, rendered, destProperties as CFDictionary)
            guard CGImageDestinationFinalize(dest) else {
                throw RawDevelopEngineError.encodeFailed
            }
            return outputData as Data
        }
    }

    // MARK: - Stufe 1: CIRAWFilter-Properties

    /// Instanz-Variante für die wiederverwendete Preview-Instanz: setzt JEDE Property —
    /// `nil`-Parameter explizit zurück auf den beim Öffnen gesicherten Datei-Default,
    /// statt (wie der Export-Pfad auf frischem Filter) sie einfach auszulassen.
    private func applyStage1Resetting(params: RawDevelopParams) {
        filter.neutralTemperature = Float(params.temperature ?? asShotTemperature)
        filter.neutralTint = Float(params.tint ?? asShotTint)
        filter.exposure = Float(params.exposure)

        if filter.isLuminanceNoiseReductionSupported {
            filter.luminanceNoiseReductionAmount = params.luminanceNR.map(Float.init) ?? stage1Defaults.luminanceNR
        }
        if filter.isColorNoiseReductionSupported {
            filter.colorNoiseReductionAmount = params.colorNR.map(Float.init) ?? stage1Defaults.colorNR
        }
        if filter.isSharpnessSupported {
            filter.sharpnessAmount = params.sharpness.map(Float.init) ?? stage1Defaults.sharpness
        }
        if filter.isLensCorrectionSupported {
            filter.isLensCorrectionEnabled = params.lensCorrection
        }
    }

    private static func applyStage1(to filter: CIRAWFilter, params: RawDevelopParams) {
        if let temperature = params.temperature {
            filter.neutralTemperature = Float(temperature)
        }
        if let tint = params.tint {
            filter.neutralTint = Float(tint)
        }
        filter.exposure = Float(params.exposure)

        if let luminanceNR = params.luminanceNR, filter.isLuminanceNoiseReductionSupported {
            filter.luminanceNoiseReductionAmount = Float(luminanceNR)
        }
        if let colorNR = params.colorNR, filter.isColorNoiseReductionSupported {
            filter.colorNoiseReductionAmount = Float(colorNR)
        }
        if let sharpness = params.sharpness, filter.isSharpnessSupported {
            filter.sharpnessAmount = Float(sharpness)
        }
        if filter.isLensCorrectionSupported {
            filter.isLensCorrectionEnabled = params.lensCorrection
        }
    }

    // MARK: - Stufe 2: nachgelagerte Ton-Kette

    /// Die fünf `CIToneCurve`-Kontrollpunkte aus den zweiseitigen Reglern (−100…+100).
    ///
    /// Negative Richtungen sind die v1-Rezepte (crush blacks / clip whites, ursprünglich
    /// aus `ImageAdjustmentsService`), damit migrierte v1-Werte exakt dieselbe Kurve
    /// ergeben. Positive Richtungen (Schwarz anheben, Weiß strecken, Lichter anheben,
    /// Schatten absenken) sind v2-Neuerungen; `dehaze` legt einen Schwarzpunkt-Offset
    /// darüber. Pure Funktion — direkt unit-testbar.
    static func toneCurvePoints(
        highlights: Double, shadows: Double, whites: Double, blacks: Double, dehaze: Double
    ) -> [CGPoint] {
        let h = highlights / 100, s = shadows / 100
        let w = whites / 100, b = blacks / 100, d = dehaze / 100

        // Negative Richtungen — bisherige v1-Rezepte, unverändert:
        let bp = CGFloat(max(0, -b) * 0.2)
        let wp = CGFloat(max(0, -w) * 0.2)
        var p0 = CGPoint(x: 0, y: 0)
        var p1 = CGPoint(x: 0.25 + bp - wp * 0.3, y: 0.25)
        let p2 = CGPoint(x: 0.5 + bp * 0.7 - wp * 0.7, y: 0.5)
        var p3 = CGPoint(x: 0.75 + bp * 0.3 - wp, y: 0.75)
        var p4 = CGPoint(x: 1.0, y: 1.0 - wp)

        // Positive Richtungen (v2):
        if b > 0 { p0.y = 0.08 * b }          // Schwarz anheben
        if w > 0 { p4.x = 1.0 - 0.1 * w }     // Weiß strecken (früher clippen lassen)
        if h > 0 { p3.y = min(0.98, p3.y + 0.18 * h) } // Lichter anheben
        if s < 0 { p1.y = max(0.02, p1.y - 0.15 * -s) } // Schatten absenken

        // Dunst entfernen: positiv schiebt den Schwarzpunkt hinein, negativ hebt ihn an.
        if d > 0 { p0.x = 0.06 * d } else if d < 0 { p0.y = max(p0.y, 0.06 * -d) }

        // Monotonie: x strikt steigend, sonst wird die Spline-Kurve undefiniert.
        var points = [p0, p1, p2, p3, p4]
        for i in 1 ..< points.count {
            points[i].x = max(points[i].x, points[i - 1].x + 0.01)
        }
        return points
    }

    private static let identityCurvePoints: [CGPoint] = [
        CGPoint(x: 0, y: 0), CGPoint(x: 0.25, y: 0.25), CGPoint(x: 0.5, y: 0.5),
        CGPoint(x: 0.75, y: 0.75), CGPoint(x: 1, y: 1),
    ]

    /// Prozess-weiter Cache für die Farbmischer-LUT: Die Berechnung (64³ Gitterpunkte)
    /// ist zu teuer für jeden Preview-Frame, der Mixer ändert sich aber nur, wenn dessen
    /// Regler bewegt werden. Ein Eintrag genügt — Preview und Export desselben Assets
    /// nutzen denselben Mixer.
    private final class HSLCubeCache: @unchecked Sendable {
        private let lock = NSLock()
        private var mixer: HSLMixerParams?
        private var data: Data?

        func cubeData(for mixer: HSLMixerParams, dimension: Int) -> Data {
            lock.lock()
            defer { lock.unlock() }
            if let data, self.mixer == mixer { return data }
            let fresh = HSLColorCube.makeCubeData(mixer: mixer, dimension: dimension)
            self.mixer = mixer
            self.data = fresh
            return fresh
        }
    }

    private static let hslCubeCache = HSLCubeCache()
    private static let hslCubeDimension = 64

    /// Nachgelagerte Filterkette hinter dem `CIRAWFilter`. `internal static`, damit
    /// Unit-Tests direkt gegen sie laufen können, ohne einen CIRAWFilter zu benötigen.
    ///
    /// `scale` ist der Render-Maßstab (Preview: `maxPixel/longeEdge`, Export: 1) und
    /// steuert ausschließlich die Körnung — deren Partikelgröße muss relativ zum Bild
    /// gleich bleiben, sonst sähe die Vorschau anders aus als der Export. Alle übrigen
    /// auflösungsabhängigen Radien (Klarheit, Struktur, Vignette) leiten sich aus
    /// `image.extent` ab und sind damit von selbst maßstabsfest.
    static func applyToneStage(_ image: CIImage, params: RawDevelopParams, scale: CGFloat) -> CIImage {
        var img = image

        // Dunst entfernen ist eine dokumentierte Näherung (nicht Adobes Modell):
        // Schwarzpunkt-Offset in der Tonkurve plus Kontrast- und Dynamik-Anteil.
        let dehazeN = params.dehaze / 100
        let effContrast = params.contrast + 0.15 * dehazeN
        let effVibrance = params.vibrance + 0.15 * dehazeN

        // ── Lichter-Rettung / Schatten-Aufhellung (lokal wirkend) ──
        let highlightRecovery = min(0, params.highlights / 100)
        let shadowLift = max(0, params.shadows / 100)
        if highlightRecovery != 0 || shadowLift != 0 {
            let f = CIFilter.highlightShadowAdjust()
            f.inputImage = img
            f.highlightAmount = Float(1.0 + highlightRecovery)
            f.shadowAmount = Float(shadowLift)
            img = f.outputImage ?? img
        }

        if effContrast != 1 || params.saturation != 1 {
            let f = CIFilter.colorControls()
            f.inputImage = img
            f.brightness = 0
            f.contrast = Float(effContrast)
            f.saturation = Float(params.saturation)
            img = f.outputImage ?? img
        }

        let curve = toneCurvePoints(
            highlights: params.highlights, shadows: params.shadows,
            whites: params.whites, blacks: params.blacks, dehaze: params.dehaze
        )
        if curve != identityCurvePoints {
            let f = CIFilter(name: "CIToneCurve")!
            f.setValue(img, forKey: kCIInputImageKey)
            for (i, p) in curve.enumerated() {
                f.setValue(CIVector(x: p.x, y: p.y), forKey: "inputPoint\(i)")
            }
            img = f.outputImage ?? img
        }

        if effVibrance != 0 {
            let f = CIFilter(name: "CIVibrance")!
            f.setValue(img, forKey: kCIInputImageKey)
            f.setValue(Float(effVibrance), forKey: "inputAmount")
            img = f.outputImage ?? img
        }

        // ── Farbmischer (nach der Ton-Kette: die LUT clampt auf 0…1, Extended-Range-
        // Lichter sollen vorher abgewickelt sein) ──
        if !params.hsl.isIdentity {
            let f = CIFilter.colorCubeWithColorSpace()
            f.inputImage = img
            f.cubeDimension = Float(hslCubeDimension)
            f.cubeData = hslCubeCache.cubeData(for: params.hsl, dimension: hslCubeDimension)
            f.colorSpace = CGColorSpace(name: CGColorSpace.displayP3)
            img = f.outputImage ?? img
        }

        // ── Film-Look: nach der Farbe, vor den Effekten. Vignette und Korn des Nutzers
        //    bleiben die letzte Schicht; der Look ist Farbe und Ton. ──
        if let lookID = params.lookID, let look = FilmLookCatalog.look(id: lookID) {
            // Erst die Basiskorrektur (Apples Neutral → Lightrooms Neutral, gegen das die
            // Looks gefittet sind), dann der Look — beide mit derselben Stärke. Ohne Look
            // bleibt die Entwicklung unangetastet, siehe `RawLookBasis`. Gebunden an einen
            // **aufgelösten** Look: Eine gestrichene ID ist „kein Look" und darf auch die
            // Korrektur nicht allein auslösen (Pipeline-Test „unbekannte Look-ID").
            img = FilmLookRenderer.apply(
                img, look: RawLookBasis.korrektur, staerke: params.lookStaerke,
                scale: scale, cubeDimension: hslCubeDimension
            )
            img = FilmLookRenderer.apply(
                img, look: look, staerke: params.lookStaerke,
                scale: scale, cubeDimension: hslCubeDimension
            )
        }

        // ── Effekte ──
        let extent = img.extent
        let longEdge = max(extent.width, extent.height)

        // Mindestradius 1 px: Bei sehr kleinen Bildern (Thumbnails, Tests) fielen die
        // Bruchteil-Radien sonst unter die Wirkschwelle der Filter.
        if params.texture != 0, longEdge > 0 {
            img = detailContrast(
                img, amount: params.texture / 100,
                sharpenRadius: max(1, 0.004 * longEdge), sharpenGain: 0.5,
                blurRadius: max(1, 0.002 * longEdge), blurMix: 0.35
            )
        }

        if params.clarity != 0, longEdge > 0 {
            img = detailContrast(
                img, amount: params.clarity / 100,
                sharpenRadius: max(1, 0.015 * longEdge), sharpenGain: 0.6,
                blurRadius: max(1, 0.008 * longEdge), blurMix: 0.35
            )
        }

        if params.vignette != 0, longEdge > 0 {
            let diagonal = (extent.width * extent.width + extent.height * extent.height).squareRoot()
            let f = CIFilter.vignetteEffect()
            f.inputImage = img
            f.center = CGPoint(x: extent.midX, y: extent.midY)
            f.radius = Float(0.75 * diagonal / 2)
            f.intensity = Float(params.vignette / 100)
            img = (f.outputImage ?? img).cropped(to: extent)
        }

        if params.grain > 0, longEdge > 0 {
            img = applyGrain(img, amount: params.grain / 100, scale: scale)
        }

        return img
    }

    /// Klarheit/Struktur: positiver Wert = Unsharp-Mask mit großem Radius (lokaler
    /// Kontrast), negativer Wert = Mix Richtung Gauß-Weichzeichnung. Radien kommen vom
    /// Aufrufer als Bild-Bruchteile — auflösungsunabhängig.
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

    /// Filmkorn: deterministisches `CIRandomGenerator`-Rauschen, entsättigt, um 0.5
    /// zentriert und per Soft-Light übergeblendet. Die Partikelgröße (~1.5 px in voller
    /// Auflösung) wird mit dem Render-Maßstab skaliert — Preview und Export zeigen
    /// dieselbe Körnung relativ zum Bild.
    private static let grainSizeFullResPixels: CGFloat = 1.5

    static func applyGrain(_ img: CIImage, amount: Double, scale: CGFloat) -> CIImage {
        guard let noise = CIFilter.randomGenerator().outputImage else { return img }
        let extent = img.extent

        let desat = CIFilter.colorControls()
        desat.inputImage = noise
        desat.saturation = 0
        desat.brightness = 0
        desat.contrast = 1
        guard let gray = desat.outputImage else { return img }

        // Um 0.5 zentrieren: out = a·x + 0.5·(1−a). Soft-Light mit 0.5 ist neutral,
        // die Amplitude a bestimmt die Kornstärke.
        let a = CGFloat(0.25 * amount)
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = gray
        matrix.rVector = CIVector(x: a, y: 0, z: 0, w: 0)
        matrix.gVector = CIVector(x: 0, y: a, z: 0, w: 0)
        matrix.bVector = CIVector(x: 0, y: 0, z: a, w: 0)
        matrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        matrix.biasVector = CIVector(x: 0.5 * (1 - a), y: 0.5 * (1 - a), z: 0.5 * (1 - a), w: 0)
        guard let centered = matrix.outputImage else { return img }

        let grainScale = max(0.05, scale * grainSizeFullResPixels)
        let scaled = centered
            .transformed(by: CGAffineTransform(scaleX: grainScale, y: grainScale))
            .cropped(to: extent)

        let blend = CIFilter.softLightBlendMode()
        blend.inputImage = scaled
        blend.backgroundImage = img
        return (blend.outputImage ?? img).cropped(to: extent)
    }
}
