import Foundation

// MARK: - Seitenverhältnis

enum CropAspect: String, CaseIterable, Identifiable, Sendable {
    case free        = "Frei"
    case square      = "1:1"
    case fourThree   = "4:3"
    case threeTwo    = "3:2"
    case sixteenNine = "16:9"
    case threeFour   = "3:4"
    case twoThree    = "2:3"
    case nineSixteen = "9:16"

    var id: String { rawValue }

    /// Die 5 Grundformate für den Segmented-Picker (Querformat als Basis).
    static let basisFormate: [CropAspect] = [.free, .square, .fourThree, .threeTwo, .sixteenNine]

    /// Breite geteilt durch Höhe, oder `nil` bei freiem Beschnitt.
    var ratio: Double? {
        switch self {
        case .free:        return nil
        case .square:      return 1
        case .fourThree:   return 4.0 / 3.0
        case .threeTwo:    return 3.0 / 2.0
        case .sixteenNine: return 16.0 / 9.0
        case .threeFour:   return 3.0 / 4.0
        case .twoThree:    return 2.0 / 3.0
        case .nineSixteen: return 9.0 / 16.0
        }
    }

    var istHochformat: Bool {
        switch self {
        case .threeFour, .twoThree, .nineSixteen: return true
        default: return false
        }
    }

    var kannOrientierungWechseln: Bool {
        switch self {
        case .free, .square: return false
        default: return true
        }
    }

    /// Kippt zwischen Quer- und Hochformat (`4:3` ↔ `3:4`, `3:2` ↔ `2:3`, `16:9` ↔ `9:16`).
    var gedreht: CropAspect {
        switch self {
        case .fourThree:   return .threeFour
        case .threeFour:   return .fourThree
        case .threeTwo:    return .twoThree
        case .twoThree:    return .threeTwo
        case .sixteenNine: return .nineSixteen
        case .nineSixteen: return .sixteenNine
        default:           return self
        }
    }

    func inOrientierung(hochformat: Bool) -> CropAspect {
        guard kannOrientierungWechseln else { return self }
        return istHochformat == hochformat ? self : gedreht
    }
}
