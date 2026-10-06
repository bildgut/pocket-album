import Foundation

// MARK: - Seitenverhältnis

enum CropAspect: String, CaseIterable, Identifiable, Sendable {
    case free       = "Frei"
    case square     = "1:1"
    case fourThree  = "4:3"
    case threeTwo   = "3:2"
    case sixteenNine = "16:9"

    var id: String { rawValue }

    /// Breite geteilt durch Höhe, oder `nil` bei freiem Beschnitt.
    var ratio: Double? {
        switch self {
        case .free:        return nil
        case .square:      return 1
        case .fourThree:   return 4.0 / 3.0
        case .threeTwo:    return 3.0 / 2.0
        case .sixteenNine: return 16.0 / 9.0
        }
    }
}
