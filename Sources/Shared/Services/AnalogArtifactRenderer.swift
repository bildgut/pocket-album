import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import CoreText
import Foundation

// MARK: - AnalogArtifactRenderer

/// Wendet physikalische Dunkelkammer-Effekte (Halation, Light Leak, Filmrahmen, Datumsstempel)
/// auf CIImages und CGImages an. Funktioniert plattformübergreifend (macOS & iOS).
public enum AnalogArtifactRenderer {

    /// Wendet die CoreImage-basierten Bildeffekte (Halation & Light Leak) auf ein Bild an.
    public static func apply(
        to image: CIImage,
        params: AnalogArtifactParams,
        scale: CGFloat
    ) -> CIImage {
        guard !params.isIdentity else { return image }
        var img = image

        if params.halation > 0 {
            img = applyHalation(to: img, strength: params.halation, scale: scale)
        }

        if params.lightLeak > 0 {
            img = applyLightLeak(to: img, strength: params.lightLeak)
        }

        return img
    }

    // MARK: - Halation (CineStill-Lichthöfe)

    /// Simuliert das diffuse rote Überstrahlen an harten Kontrast- und Lichtkanten,
    /// wie es bei analogem Film ohne Lichthofschutzschicht (Remjet) auftritt.
    public static func applyHalation(
        to image: CIImage,
        strength: Double,
        scale: CGFloat
    ) -> CIImage {
        guard strength > 0 else { return image }
        let extent = image.extent

        // 1. Lichter isolieren (Schwellenwert für helle Reflexe und Kanten)
        let clamp = CIFilter.colorClamp()
        clamp.inputImage = image
        clamp.minComponents = CIVector(x: 0.65, y: 0.65, z: 0.65, w: 0.0)
        clamp.maxComponents = CIVector(x: 1.0, y: 1.0, z: 1.0, w: 1.0)
        guard let highlights = clamp.outputImage else { return image }

        // 2. In warmes CineStill-Orange/Rot einfärben
        let matrix = CIFilter.colorMatrix()
        matrix.inputImage = highlights
        matrix.rVector = CIVector(x: 1.0, y: 0.0, z: 0.0, w: 0.0)
        matrix.gVector = CIVector(x: 0.18, y: 0.0, z: 0.0, w: 0.0)
        matrix.bVector = CIVector(x: 0.04, y: 0.0, z: 0.0, w: 0.0)
        matrix.aVector = CIVector(x: 0.0, y: 0.0, z: 0.0, w: 1.0)
        guard let redGlow = matrix.outputImage else { return image }

        // 3. Weichzeichnen des roten Streulichts
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = redGlow
        let radius = max(2.0, 14.0 * (strength / 50.0) * Double(scale))
        blur.radius = Float(radius)
        guard let blurred = blur.outputImage?.cropped(to: extent) else { return image }

        // 4. Stärke gewichten und per Screen/Addition auf das Original mischen
        let alphaScale = CGFloat(min(1.0, strength / 100.0 * 1.2))
        let alphaFilter = CIFilter.colorMatrix()
        alphaFilter.inputImage = blurred
        alphaFilter.rVector = CIVector(x: 1, y: 0, z: 0, w: 0)
        alphaFilter.gVector = CIVector(x: 0, y: 1, z: 0, w: 0)
        alphaFilter.bVector = CIVector(x: 0, y: 0, z: 1, w: 0)
        alphaFilter.aVector = CIVector(x: 0, y: 0, z: 0, w: alphaScale)
        guard let weightedGlow = alphaFilter.outputImage else { return image }

        let blend = CIFilter.screenBlendMode()
        blend.inputImage = weightedGlow
        blend.backgroundImage = image
        return blend.outputImage?.cropped(to: extent) ?? image
    }

    // MARK: - Light Leak (Lichteinfall)

    /// Erzeugt einen warmen, organischen Lichteinfall an einer Bildecke.
    public static func applyLightLeak(
        to image: CIImage,
        strength: Double
    ) -> CIImage {
        guard strength > 0 else { return image }
        let extent = image.extent

        let intensity = CGFloat(min(1.0, strength / 100.0))
        let center = CGPoint(x: extent.minX + extent.width * 0.1, y: extent.maxY - extent.height * 0.05)
        let radius = Float(max(extent.width, extent.height) * 0.65)

        let gradient = CIFilter.radialGradient()
        gradient.center = center
        gradient.radius0 = 0.0
        gradient.radius1 = radius
        gradient.color0 = CIColor(red: 1.0, green: 0.42, blue: 0.08, alpha: intensity * 0.75)
        gradient.color1 = CIColor(red: 0.9, green: 0.15, blue: 0.02, alpha: 0.0)

        guard let leak = gradient.outputImage?.cropped(to: extent) else { return image }

        let blend = CIFilter.screenBlendMode()
        blend.inputImage = leak
        blend.backgroundImage = image
        return blend.outputImage?.cropped(to: extent) ?? image
    }

    // MARK: - Film Frame & Date Stamp Compositing (CoreGraphics)

    /// Rendert ein Bild mit dem gewählten analogen Filmrahmen und optionalem Datumsstempel
    public static func compositeFrame(
        image: CGImage,
        style: FilmFrameStyle,
        dateStampText: String? = nil,
        dateStyle: DateStampStyle = .amber90s
    ) -> CGImage? {
        guard style != .none || dateStampText != nil else { return image }

        let inputSize = CGSize(width: image.width, height: image.height)
        let canvasSize = style.canvasSize(for: inputSize)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: Int(canvasSize.width),
            height: Int(canvasSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        // 1. Hintergrund zeichnen je nach Rahmen
        drawFrameBackground(into: ctx, size: canvasSize, style: style)

        // 2. Foto im Rahmen platzieren
        let imageRect = imagePlacementRect(for: inputSize, in: canvasSize, style: style)
        ctx.draw(image, in: imageRect)

        // 3. Rahmendetails (Perforationslöcher, Randnotizen)
        drawFrameDecorations(into: ctx, canvasSize: canvasSize, imageRect: imageRect, style: style)

        // 4. 90er-Jahre Datumsstempel einbrennen
        if let text = dateStampText, !text.isEmpty {
            drawDateStamp(into: ctx, text: text, in: imageRect, style: dateStyle)
        }

        return ctx.makeImage()
    }

    // MARK: - Private CoreGraphics Helpers

    private static func imagePlacementRect(
        for contentSize: CGSize,
        in canvasSize: CGSize,
        style: FilmFrameStyle
    ) -> CGRect {
        switch style {
        case .none:
            return CGRect(origin: .zero, size: contentSize)
        case .sprocket35mm:
            let originX = (canvasSize.width - contentSize.width) / 2
            let originY = (canvasSize.height - contentSize.height) / 2
            return CGRect(x: originX, y: originY, width: contentSize.width, height: contentSize.height)
        case .polaroid:
            let originX = (canvasSize.width - contentSize.width) / 2
            let bottomMargin = canvasSize.height - (contentSize.height + (canvasSize.height * 0.06))
            return CGRect(x: originX, y: bottomMargin, width: contentSize.width, height: contentSize.height)
        case .mediumFormat6x6:
            let originX = (canvasSize.width - contentSize.width) / 2
            let originY = (canvasSize.height - contentSize.height) / 2
            return CGRect(x: originX, y: originY, width: contentSize.width, height: contentSize.height)
        }
    }

    private static func drawFrameBackground(into ctx: CGContext, size: CGSize, style: FilmFrameStyle) {
        ctx.saveGState()
        switch style {
        case .none:
            break
        case .sprocket35mm, .mediumFormat6x6:
            // Sattes Kameraschwarz
            ctx.setFillColor(CGColor(gray: 0.05, alpha: 1.0))
            ctx.fill(CGRect(origin: .zero, size: size))
        case .polaroid:
            // Sanftes Warmweiß / Eierschalen-Karton
            ctx.setFillColor(CGColor(red: 0.96, green: 0.95, blue: 0.93, alpha: 1.0))
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        ctx.restoreGState()
    }

    private static func drawFrameDecorations(
        into ctx: CGContext,
        canvasSize: CGSize,
        imageRect: CGRect,
        style: FilmFrameStyle
    ) {
        ctx.saveGState()
        switch style {
        case .none:
            break

        case .sprocket35mm:
            // Perforationslöcher oben und unten zeichnen
            let holeWidth = canvasSize.width * 0.018
            let holeHeight = canvasSize.height * 0.075
            let holeCorner = holeWidth * 0.35
            let spacing = holeWidth * 2.2
            let holeCount = Int(canvasSize.width / spacing)

            ctx.setFillColor(CGColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1.0))

            // Oben
            let topY = canvasSize.height - holeHeight - (canvasSize.height * 0.035)
            for i in 0...holeCount {
                let x = CGFloat(i) * spacing + (spacing * 0.5)
                let r = CGRect(x: x, y: topY, width: holeWidth, height: holeHeight)
                let path = CGPath(roundedRect: r, cornerWidth: holeCorner, cornerHeight: holeCorner, transform: nil)
                ctx.addPath(path)
                ctx.fillPath()
            }

            // Unten
            let bottomY = canvasSize.height * 0.035
            for i in 0...holeCount {
                let x = CGFloat(i) * spacing + (spacing * 0.5)
                let r = CGRect(x: x, y: bottomY, width: holeWidth, height: holeHeight)
                let path = CGPath(roundedRect: r, cornerWidth: holeCorner, cornerHeight: holeCorner, transform: nil)
                ctx.addPath(path)
                ctx.fillPath()
            }

        case .polaroid:
            // Leichter innerer Schlagschatten um das Foto für Tiefenwirkung
            ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 4, color: CGColor(gray: 0, alpha: 0.25))
            ctx.setStrokeColor(CGColor(gray: 0.88, alpha: 1.0))
            ctx.setLineWidth(1)
            ctx.stroke(imageRect)

        case .mediumFormat6x6:
            // Typische V-förmige Hasselblad-Filmbühnen-Kerben an der rechten Seite
            let notchDepth = canvasSize.width * 0.015
            let notchH = canvasSize.height * 0.03
            let notchY1 = canvasSize.height * 0.4
            let notchY2 = canvasSize.height * 0.6

            ctx.setFillColor(CGColor(gray: 0.15, alpha: 1.0))
            let path = CGMutablePath()
            path.move(to: CGPoint(x: imageRect.maxX, y: notchY1 - notchH / 2))
            path.addLine(to: CGPoint(x: imageRect.maxX + notchDepth, y: notchY1))
            path.addLine(to: CGPoint(x: imageRect.maxX, y: notchY1 + notchH / 2))
            path.closeSubpath()

            path.move(to: CGPoint(x: imageRect.maxX, y: notchY2 - notchH / 2))
            path.addLine(to: CGPoint(x: imageRect.maxX + notchDepth, y: notchY2))
            path.addLine(to: CGPoint(x: imageRect.maxX, y: notchY2 + notchH / 2))
            path.closeSubpath()

            ctx.addPath(path)
            ctx.fillPath()
        }
        ctx.restoreGState()
    }

    private static func drawDateStamp(
        into ctx: CGContext,
        text: String,
        in imageRect: CGRect,
        style: DateStampStyle
    ) {
        ctx.saveGState()

        let rgb = style.rgbColor
        let color = CGColor(red: rgb.r, green: rgb.g, blue: rgb.b, alpha: 0.95)

        // Authentisches LED-Glimmen mit Schlagschatten
        ctx.setShadow(offset: .zero, blur: 5, color: CGColor(red: rgb.r, green: rgb.g, blue: rgb.b, alpha: 0.8))
        ctx.setFillColor(color)

        // Monospaced LED-Stil Schriftgröße relativ zur Bildgröße
        let fontSize = max(14.0, imageRect.height * 0.038)
        let fontName = "Menlo-Bold" as CFString
        let font = CTFontCreateWithName(fontName, fontSize, nil)

        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color
        ]
        let attrString = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)!
        let line = CTLineCreateWithAttributedString(attrString)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)

        // Unten rechts mit Randabstand platzieren
        let marginX = imageRect.width * 0.04
        let marginY = imageRect.height * 0.04
        let posX = imageRect.maxX - bounds.width - marginX
        let posY = imageRect.minY + marginY

        ctx.textPosition = CGPoint(x: posX, y: posY)
        CTLineDraw(line, ctx)

        ctx.restoreGState()
    }
}
