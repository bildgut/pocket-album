import Foundation

// MARK: - HSLBandID

/// Die acht Farbbänder des Farbmischers, angelehnt an Lightrooms Farbmischer-Aufteilung.
///
/// `hueDegrees` ist das Bandzentrum auf dem Farbkreis (0…360). Die Bandbreite ergibt
/// sich aus den Nachbarzentren — siehe `HSLColorCube.bandWeights`.
enum HSLBandID: String, CaseIterable, Codable, Sendable, Identifiable {
    case rot, orange, gelb, gruen, aqua, blau, lila, magenta

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .rot: return "Rot"
        case .orange: return "Orange"
        case .gelb: return "Gelb"
        case .gruen: return "Grün"
        case .aqua: return "Aquamarin"
        case .blau: return "Blau"
        case .lila: return "Lila"
        case .magenta: return "Magenta"
        }
    }

    var hueDegrees: Double {
        switch self {
        case .rot: return 0
        case .orange: return 30
        case .gelb: return 60
        case .gruen: return 120
        case .aqua: return 180
        case .blau: return 240
        case .lila: return 280
        case .magenta: return 320
        }
    }
}

// MARK: - HSLBand

/// Die drei Regler eines Farbbands, jeweils −100…+100 (0 = unverändert). Der Regler im
/// RAW-Editor bleibt bei ±100 (= ±30° Farbton); `FilmLook`-Kataloge dürfen den Farbton bis
/// ±200 (= ±60°) treiben — der Würfel rechnet linear, Lightrooms Aqua-Verschiebung von
/// +100 reicht sonst nicht.
struct HSLBand: Codable, Hashable, Sendable {
    var hue: Double = 0
    var sat: Double = 0
    var lum: Double = 0

    var isIdentity: Bool { hue == 0 && sat == 0 && lum == 0 }
}

// MARK: - HSLMixerParams

/// Alle acht Farbbänder des Farbmischers. Teil von ``RawDevelopParams`` (Stufe 2) und
/// wandert damit automatisch in Presets, Batch-Läufe und die nicht-destruktive
/// Persistenz.
struct HSLMixerParams: Codable, Hashable, Sendable {
    var rot = HSLBand()
    var orange = HSLBand()
    var gelb = HSLBand()
    var gruen = HSLBand()
    var aqua = HSLBand()
    var blau = HSLBand()
    var lila = HSLBand()
    var magenta = HSLBand()

    static let identity = HSLMixerParams()

    var isIdentity: Bool { self == .identity }

    subscript(band: HSLBandID) -> HSLBand {
        get {
            switch band {
            case .rot: return rot
            case .orange: return orange
            case .gelb: return gelb
            case .gruen: return gruen
            case .aqua: return aqua
            case .blau: return blau
            case .lila: return lila
            case .magenta: return magenta
            }
        }
        set {
            switch band {
            case .rot: rot = newValue
            case .orange: orange = newValue
            case .gelb: gelb = newValue
            case .gruen: gruen = newValue
            case .aqua: aqua = newValue
            case .blau: blau = newValue
            case .lila: lila = newValue
            case .magenta: magenta = newValue
            }
        }
    }

    /// Vorwärtskompatibles Decoding wie bei ``RawDevelopParams``: fehlende Bänder
    /// fallen auf Identität zurück, statt das ganze Params-JSON scheitern zu lassen.
    init() {}

    private enum CodingKeys: String, CodingKey {
        case rot, orange, gelb, gruen, aqua, blau, lila, magenta
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rot = try container.decodeIfPresent(HSLBand.self, forKey: .rot) ?? HSLBand()
        orange = try container.decodeIfPresent(HSLBand.self, forKey: .orange) ?? HSLBand()
        gelb = try container.decodeIfPresent(HSLBand.self, forKey: .gelb) ?? HSLBand()
        gruen = try container.decodeIfPresent(HSLBand.self, forKey: .gruen) ?? HSLBand()
        aqua = try container.decodeIfPresent(HSLBand.self, forKey: .aqua) ?? HSLBand()
        blau = try container.decodeIfPresent(HSLBand.self, forKey: .blau) ?? HSLBand()
        lila = try container.decodeIfPresent(HSLBand.self, forKey: .lila) ?? HSLBand()
        magenta = try container.decodeIfPresent(HSLBand.self, forKey: .magenta) ?? HSLBand()
    }
}
