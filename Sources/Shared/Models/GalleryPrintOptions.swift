import Foundation
import CoreGraphics

// MARK: - Paper Size

/// Standardisierte Papier- und Druckformate für Fine-Art & Ausstellungsdrucke.
public enum PrintPaperSize: String, CaseIterable, Identifiable, Codable, Sendable {
    case a4 = "DIN A4 (21 x 29,7 cm)"
    case a3 = "DIN A3 (29,7 x 42 cm)"
    case a2 = "DIN A2 (42 x 59,4 cm)"
    case usLetter = "US Letter (8,5 x 11 in)"
    case square30 = "Quadrat (30 x 30 cm)"
    case postcard10x15 = "Postkarte (10 x 15 cm)"
    case photo13x18 = "Foto (13 x 18 cm)"
    case fitToImage = "Proportional zum Bild"

    public var id: String { rawValue }

    /// Abmessungen in Millimetern (Breite x Höhe im Hochformat).
    public var dimensionsMm: (width: Double, height: Double)? {
        switch self {
        case .a4: return (210.0, 297.0)
        case .a3: return (297.0, 420.0)
        case .a2: return (420.0, 594.0)
        case .usLetter: return (215.9, 279.4)
        case .square30: return (300.0, 300.0)
        case .postcard10x15: return (100.0, 150.0)
        case .photo13x18: return (130.0, 180.0)
        case .fitToImage: return nil
        }
    }

    /// Berechnet die Zielpixel bei vorgegebener DPI (Standard 300 DPI Druckauflösung).
    public func pixelSize(dpi: Double = 300.0, landscape: Bool = false, fallbackImageSize: CGSize = CGSize(width: 3000, height: 2000)) -> CGSize {
        guard let dim = dimensionsMm else {
            let w = landscape ? max(fallbackImageSize.width, fallbackImageSize.height) : min(fallbackImageSize.width, fallbackImageSize.height)
            let h = landscape ? min(fallbackImageSize.width, fallbackImageSize.height) : max(fallbackImageSize.width, fallbackImageSize.height)
            return CGSize(width: w, height: h)
        }

        let mmToInch = 1.0 / 25.4
        let wPx = round(dim.width * mmToInch * dpi)
        let hPx = round(dim.height * mmToInch * dpi)

        if landscape {
            return CGSize(width: max(wPx, hPx), height: min(wPx, hPx))
        } else {
            return CGSize(width: min(wPx, hPx), height: max(wPx, hPx))
        }
    }
}

// MARK: - Print Orientation

public enum PrintOrientation: String, CaseIterable, Identifiable, Codable, Sendable {
    case auto = "Automatisch"
    case portrait = "Hochformat"
    case landscape = "Querformat"

    public var id: String { rawValue }

    public func isLandscape(forImageSize size: CGSize) -> Bool {
        switch self {
        case .auto: return size.width >= size.height
        case .portrait: return false
        case .landscape: return true
        }
    }
}

// MARK: - Passepartout Color

public enum PassepartoutColor: String, CaseIterable, Identifiable, Codable, Sendable {
    case museumWhite = "Museum White"
    case warmIvory = "Warm Ivory"
    case galleryCream = "Gallery Cream"
    case archivalBlack = "Archival Black"
    case slateGray = "Slate Gray"

    public var id: String { rawValue }

    /// RGB-Werte (0...1) für Rendering und Vorschau
    public var rgb: (r: Double, g: Double, b: Double) {
        switch self {
        case .museumWhite:  return (0.975, 0.970, 0.960)
        case .warmIvory:    return (0.960, 0.940, 0.905)
        case .galleryCream: return (0.940, 0.915, 0.855)
        case .archivalBlack:return (0.100, 0.100, 0.105)
        case .slateGray:    return (0.230, 0.235, 0.245)
        }
    }

    /// Typografie-Grundfarbe, die optimalen Kontrast zum Passepartout bietet
    public var textColorRgb: (r: Double, g: Double, b: Double) {
        switch self {
        case .archivalBlack, .slateGray:
            return (0.88, 0.88, 0.88)
        case .museumWhite, .warmIvory, .galleryCream:
            return (0.22, 0.22, 0.24)
        }
    }

    /// Feine Kantenfarbe für Schrägschnitt-Linien
    public var bevelRgb: (shadow: (r: Double, g: Double, b: Double), highlight: (r: Double, g: Double, b: Double)) {
        switch self {
        case .archivalBlack, .slateGray:
            return (shadow: (0.05, 0.05, 0.05), highlight: (0.28, 0.28, 0.30))
        default:
            return (shadow: (0.75, 0.74, 0.72), highlight: (1.0, 1.0, 1.0))
        }
    }
}

// MARK: - Frame Edge Style

public enum FrameEdgeStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    case none = "Keine Kante"
    case innerBevel = "Schrägschnitt (Bevel)"
    case thinKeyline = "Feine Haarlinie"

    public var id: String { rawValue }
}

// MARK: - Typography Style

public enum GalleryFontDesign: String, CaseIterable, Identifiable, Codable, Sendable {
    case classicSerif = "Klassische Serif (Fine Art)"
    case modernSans = "Moderne Grotesk (Clean)"
    case minimalMono = "Technisch (Monospace)"

    public var id: String { rawValue }
}

public enum GalleryCaptionAlignment: String, CaseIterable, Identifiable, Codable, Sendable {
    case center = "Zentriert"
    case splitExif = "Titel links • EXIF rechts"

    public var id: String { rawValue }
}

// MARK: - Export Format

public enum GalleryExportFormat: String, CaseIterable, Identifiable, Codable, Sendable {
    case tiff = "TIFF (300 DPI, verlustfrei)"
    case jpeg = "JPEG (300 DPI, Höchste Qualität)"
    case pdf = "PDF (Druckfertig, 300 DPI)"

    public var id: String { rawValue }

    public var fileExtension: String {
        switch self {
        case .tiff: return "tiff"
        case .jpeg: return "jpg"
        case .pdf: return "pdf"
        }
    }
}

// MARK: - Main Configuration

public struct GalleryPrintConfig: Codable, Hashable, Sendable {
    public var paperSize: PrintPaperSize = .a4
    public var orientation: PrintOrientation = .auto
    public var mattingColor: PassepartoutColor = .museumWhite
    /// Randstärke in Prozent der kürzeren Papierseite (z.B. 0.08 = 8%)
    public var marginScale: Double = 0.08
    /// Klassische Galerie-Gewichtung: unterer Rand ist ca. 45% höher für optische Mitte
    public var isExhibitionWeighted: Bool = true
    public var edgeStyle: FrameEdgeStyle = .innerBevel

    // Typografie & Prägung
    public var showTypography: Bool = true
    public var fontDesign: GalleryFontDesign = .classicSerif
    public var alignment: GalleryCaptionAlignment = .center
    public var titleText: String = ""
    public var subtitleText: String = ""
    public var dateLocationText: String = ""
    public var embossEffect: Bool = true

    public var exportFormat: GalleryExportFormat = .jpeg

    public init(
        paperSize: PrintPaperSize = .a4,
        orientation: PrintOrientation = .auto,
        mattingColor: PassepartoutColor = .museumWhite,
        marginScale: Double = 0.08,
        isExhibitionWeighted: Bool = true,
        edgeStyle: FrameEdgeStyle = .innerBevel,
        showTypography: Bool = true,
        fontDesign: GalleryFontDesign = .classicSerif,
        alignment: GalleryCaptionAlignment = .center,
        titleText: String = "",
        subtitleText: String = "",
        dateLocationText: String = "",
        embossEffect: Bool = true,
        exportFormat: GalleryExportFormat = .jpeg
    ) {
        self.paperSize = paperSize
        self.orientation = orientation
        self.mattingColor = mattingColor
        self.marginScale = marginScale
        self.isExhibitionWeighted = isExhibitionWeighted
        self.edgeStyle = edgeStyle
        self.showTypography = showTypography
        self.fontDesign = fontDesign
        self.alignment = alignment
        self.titleText = titleText
        self.subtitleText = subtitleText
        self.dateLocationText = dateLocationText
        self.embossEffect = embossEffect
        self.exportFormat = exportFormat
    }

    /// Hilfsfunktion zur automatischen Erzeugung von EXIF-Text
    public static func makeExifSummary(
        make: String?,
        model: String?,
        lens: String?,
        focalLength: Double?,
        fNumber: Double?,
        exposureTime: String?,
        iso: Double?
    ) -> String {
        var parts: [String] = []

        // Kamera
        if let model, !model.isEmpty {
            if let make, !make.isEmpty, !model.localizedCaseInsensitiveContains(make) {
                parts.append("\(make.uppercased()) \(model.uppercased())")
            } else {
                parts.append(model.uppercased())
            }
        }

        // Objektiv
        if let lens, !lens.isEmpty {
            parts.append(lens.uppercased())
        }

        // Aufnahmedaten
        var captureParts: [String] = []
        if let focalLength, focalLength > 0 {
            captureParts.append("\(Int(round(focalLength)))mm")
        }
        if let fNumber, fNumber > 0 {
            let fStr = fNumber < 10 ? String(format: "ƒ/%.1f", fNumber) : String(format: "ƒ/%.0f", fNumber)
            captureParts.append(fStr)
        }
        if let exposureTime, !exposureTime.isEmpty {
            captureParts.append("\(exposureTime)s")
        }
        if let iso, iso > 0 {
            captureParts.append("ISO \(Int(round(iso)))")
        }

        if !captureParts.isEmpty {
            parts.append(captureParts.joined(separator: " • "))
        }

        return parts.joined(separator: "  |  ")
    }

    /// Hilfsfunktion für Datum & Ort
    public static func makeDateLocationSummary(date: Date?, city: String?, country: String?) -> String {
        var parts: [String] = []

        if let city, !city.isEmpty {
            if let country, !country.isEmpty {
                parts.append("\(city.uppercased()), \(country.uppercased())")
            } else {
                parts.append(city.uppercased())
            }
        } else if let country, !country.isEmpty {
            parts.append(country.uppercased())
        }

        if let date {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            formatter.locale = Locale(identifier: "de_DE")
            parts.append(formatter.string(from: date).uppercased())
        }

        return parts.joined(separator: "  •  ")
    }
}
