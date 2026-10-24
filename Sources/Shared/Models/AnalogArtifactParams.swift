import Foundation
import CoreGraphics

// MARK: - FilmFrameStyle

public enum FilmFrameStyle: String, Codable, Hashable, Sendable, CaseIterable {
    case none             // Kein Rahmen
    case sprocket35mm     // 35mm Kleinbild-Filmstreifen mit Perforationslöchern & Filmmarke
    case polaroid         // Sofortbild-Rahmen mit breitem Boden für handschriftliche Notizen
    case mediumFormat6x6  // Hasselblad 6x6 Mittelformat mit Filmhalter-Kerben (Rebate Notches)

    public var title: String {
        switch self {
        case .none: return "Kein Rahmen"
        case .sprocket35mm: return "35mm Filmstreifen"
        case .polaroid: return "Polaroid Sofortbild"
        case .mediumFormat6x6: return "Mittelformat 6×6"
        }
    }

    /// Berechnet die Gesamtmaße der Leinwand inklusive Rahmen
    public func canvasSize(for contentSize: CGSize) -> CGSize {
        switch self {
        case .none:
            return contentSize
        case .sprocket35mm:
            // Oben und unten jeweils 16 % Höhe für Perforationsleiste
            let borderY = contentSize.height * 0.16
            let borderX = contentSize.width * 0.04
            return CGSize(width: contentSize.width + borderX * 2, height: contentSize.height + borderY * 2)
        case .polaroid:
            // Oben/Links/Rechts 6 %, Unten 24 % (typischer Sofortbild-Fuß)
            let borderSide = contentSize.width * 0.06
            let borderTop = contentSize.height * 0.06
            let borderBottom = contentSize.height * 0.22
            return CGSize(width: contentSize.width + borderSide * 2, height: contentSize.height + borderTop + borderBottom)
        case .mediumFormat6x6:
            // Quadratischer Rahmen um das Bild mit 8 % Rand
            let maxDim = max(contentSize.width, contentSize.height)
            let margin = maxDim * 0.08
            return CGSize(width: maxDim + margin * 2, height: maxDim + margin * 2)
        }
    }
}

// MARK: - DateStampStyle

public enum DateStampStyle: String, Codable, Hashable, Sendable, CaseIterable {
    case amber90s  // Klassisches warmes Bernstein-Orange ('90s Kompaktkamera)
    case redLED    // Rote 7-Segment-LED (80er/90er SLR-Datenrückwand)
    case greenLCD  // Grüne Fluoreszenz-Anzeige

    public var title: String {
        switch self {
        case .amber90s: return "Bernstein (90er)"
        case .redLED: return "Rote LED"
        case .greenLCD: return "Grünes LCD"
        }
    }

    public var rgbColor: (r: Double, g: Double, b: Double) {
        switch self {
        case .amber90s: return (r: 1.0, g: 0.45, b: 0.05)
        case .redLED: return (r: 1.0, g: 0.12, b: 0.12)
        case .greenLCD: return (r: 0.2, g: 0.95, b: 0.3)
        }
    }
}

// MARK: - DateStampFormat

public enum DateStampFormat: String, Codable, Hashable, Sendable, CaseIterable {
    case yyMMdd  // '98 10 24
    case ddMMyy  // 24 10 '98
    case mmDDyy  // 10 24 '98

    public var title: String {
        switch self {
        case .yyMMdd: return "'JJ MM TT"
        case .ddMMyy: return "TT MM 'JJ"
        case .mmDDyy: return "MM TT 'JJ"
        }
    }
}

// MARK: - DateStampConfig

public struct DateStampConfig: Codable, Hashable, Equatable, Sendable {
    public var isEnabled: Bool = false
    public var style: DateStampStyle = .amber90s
    public var format: DateStampFormat = .yyMMdd
    public var includeTime: Bool = false

    public init(
        isEnabled: Bool = false,
        style: DateStampStyle = .amber90s,
        format: DateStampFormat = .yyMMdd,
        includeTime: Bool = false
    ) {
        self.isEnabled = isEnabled
        self.style = style
        self.format = format
        self.includeTime = includeTime
    }

    /// Formatiert ein Datum im analogen Kompaktkamera-Stil
    public func formattedString(for date: Date) -> String {
        let cal = Calendar(identifier: .gregorian)
        let year = cal.component(.year, from: date) % 100
        let month = cal.component(.month, from: date)
        let day = cal.component(.day, from: date)

        let yyStr = String(format: "'%02d", year)
        let mmStr = String(format: "%02d", month)
        let ddStr = String(format: "%02d", day)

        let dateStr: String
        switch format {
        case .yyMMdd:
            dateStr = "\(yyStr) \(mmStr) \(ddStr)"
        case .ddMMyy:
            dateStr = "\(ddStr) \(mmStr) \(yyStr)"
        case .mmDDyy:
            dateStr = "\(mmStr) \(ddStr) \(yyStr)"
        }

        if includeTime {
            let hour = cal.component(.hour, from: date)
            let minute = cal.component(.minute, from: date)
            let timeStr = String(format: "%02d:%02d", hour, minute)
            return "\(dateStr) \(timeStr)"
        }
        return dateStr
    }
}

// MARK: - AnalogArtifactParams

/// Konfigurierbare physikalische Artefakte der analogen Dunkelkammer.
public struct AnalogArtifactParams: Codable, Hashable, Equatable, Sendable {
    /// Halation: Rötliches Überstrahlen an Kontrast- und Lichtkanten (0…100)
    public var halation: Double = 0.0

    /// Light Leak: Sanfter Lichteinfall am Rand / in den Ecken (0…100)
    public var lightLeak: Double = 0.0

    /// Film-Rahmen (None, 35mm Sprocket, Polaroid, Mittelformat)
    public var filmFrame: FilmFrameStyle = .none

    /// 90er-Jahre Datumsstempel
    public var dateStamp: DateStampConfig = DateStampConfig()

    public init(
        halation: Double = 0.0,
        lightLeak: Double = 0.0,
        filmFrame: FilmFrameStyle = .none,
        dateStamp: DateStampConfig = DateStampConfig()
    ) {
        self.halation = halation
        self.lightLeak = lightLeak
        self.filmFrame = filmFrame
        self.dateStamp = dateStamp
    }

    public var isIdentity: Bool {
        halation == 0.0 &&
        lightLeak == 0.0 &&
        filmFrame == .none &&
        !dateStamp.isEnabled
    }
}
