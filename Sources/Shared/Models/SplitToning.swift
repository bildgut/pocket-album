import Foundation

/// Getrennte Färbung von Schatten und Lichtern — der Baustein hinter kühl/warm
/// getönten Looks (Selenium, Sepia, „Teal & Orange").
///
/// Farbtöne in Grad (0…360), Stärken 0…100. `balance` verschiebt die Grenze zwischen
/// Schatten und Lichtern: negativ färbt mehr Tonwerte wie Schatten, positiv mehr wie
/// Lichter.
struct SplitToning: Codable, Equatable, Sendable {
    var schattenFarbton: Double
    var schattenStaerke: Double
    var lichterFarbton: Double
    var lichterStaerke: Double
    var balance: Double

    var isIdentity: Bool { schattenStaerke == 0 && lichterStaerke == 0 }

    /// Voll gesättigte Farbe eines Farbtons — HSV mit S = V = 1.
    struct RGB: Equatable, Sendable {
        var r: Double
        var g: Double
        var b: Double
    }

    static func rgb(farbton: Double) -> RGB {
        var h = farbton.truncatingRemainder(dividingBy: 360) / 60
        if h < 0 { h += 6 }
        let x = 1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)
        switch Int(h) {
        case 0: return RGB(r: 1, g: x, b: 0)
        case 1: return RGB(r: x, g: 1, b: 0)
        case 2: return RGB(r: 0, g: 1, b: x)
        case 3: return RGB(r: 0, g: x, b: 1)
        case 4: return RGB(r: x, g: 0, b: 1)
        default: return RGB(r: 1, g: 0, b: x)
        }
    }
}
