import Foundation

/// Alle Regler des RAW-Develop-Moduls, in einem Wert gebündelt.
///
/// Zwei Stufen: `temperature` … `lensCorrection` gehen direkt an `CIRAWFilter` (dessen
/// Defaults pro Datei verschieden sind — deshalb `nil` = "wie aufgenommen", nicht ein
/// fester Zahlenwert). `highlights` … `hsl` laufen durch eine nachgelagerte
/// `CIFilter`-Kette und haben feste, dateiunabhängige Defaults.
///
/// **Versionierung:** `version` unterscheidet die Wertebereiche. v1 (Key fehlt im JSON)
/// hatte einseitige Regler (`highlights` −1…0, `shadows` 0…+1, `blackPoint`/`whitePoint`
/// 0…0.2); v2 arbeitet mit zweiseitigen −100…+100-Reglern (`highlights`, `shadows`,
/// `whites`, `blacks`). `init(from:)` migriert v1-Werte so, dass exakt dieselbe Kurve
/// entsteht wie vorher. Akzeptiertes Risiko: Eine ÄLTERE App-Version, die v2-JSON liest,
/// deutet die Werte auf der alten Skala — der Store ist aber lokal (kein Server-Sync),
/// ein Downgrade ist der einzige Weg dorthin.
/// v3 ergänzt nur `lookID`/`lookStaerke` (Film-Look); die Skalen bleiben die von v2 —
/// ein v2-Leser sieht zwei unbekannte Keys und ignoriert sie.
///
/// **Vorwärtskompatibles Decoding:** Ein künftiges Release kann neue Felder ergänzen,
/// ohne dass ältere `paramsJSON`-Werte (aus `RawDevelopState`/`DevelopPreset`) beim
/// Decodieren scheitern — fehlende Keys fallen auf den Default zurück.
struct RawDevelopParams: Codable, Hashable, Sendable {

    static let currentVersion = 3

    /// Skalen-Version der Stufe-2-Werte; nach dem Decoding immer `currentVersion`.
    var version: Int = RawDevelopParams.currentVersion

    // Stufe 1: CIRAWFilter-Properties. nil = as-shot/Kamera-Default (CIRAWFilter-Defaults sind pro Datei!)
    var temperature: Double?      // Kelvin; nil = as-shot (neutralTemperature)
    var tint: Double?             // nil = as-shot
    var exposure: Double = 0      // EV, -3…+3
    var luminanceNR: Double?      // 0…1; nil = Kamera-Default
    var colorNR: Double?          // 0…1; nil = Kamera-Default
    var sharpness: Double?        // 0…1; nil = Default
    var lensCorrection: Bool = true

    // Stufe 2: nachgelagerte CIFilter-Kette (Tonwerte, zweiseitig −100…+100)
    var highlights: Double = 0    // −100…+100
    var shadows: Double = 0       // −100…+100
    var whites: Double = 0        // −100…+100
    var blacks: Double = 0        // −100…+100
    var contrast: Double = 1      // 0.5…2
    var saturation: Double = 1    // 0…2
    var vibrance: Double = 0      // -1…+1

    // Stufe 2: Effekte
    var clarity: Double = 0       // −100…+100
    var texture: Double = 0       // −100…+100
    var dehaze: Double = 0        // −100…+100
    var vignette: Double = 0      // −100…+100 (negativ = aufhellen)
    var grain: Double = 0         // 0…100

    // Stufe 2: Farbmischer
    var hsl: HSLMixerParams = .identity

    // Stufe 3: Film-Look — als Katalog-ID, nicht eingebettet: kleines JSON, und ein
    // später entfernter Look ergibt „kein Look" statt eines Decoding-Fehlers.
    var lookID: String?
    var lookStaerke: Double = 1   // 0…1

    static let identity = RawDevelopParams()

    var isIdentity: Bool { self == .identity }

    init() {}

    init(
        temperature: Double? = nil,
        tint: Double? = nil,
        exposure: Double = 0,
        luminanceNR: Double? = nil,
        colorNR: Double? = nil,
        sharpness: Double? = nil,
        lensCorrection: Bool = true,
        highlights: Double = 0,
        shadows: Double = 0,
        whites: Double = 0,
        blacks: Double = 0,
        contrast: Double = 1,
        saturation: Double = 1,
        vibrance: Double = 0,
        clarity: Double = 0,
        texture: Double = 0,
        dehaze: Double = 0,
        vignette: Double = 0,
        grain: Double = 0,
        hsl: HSLMixerParams = .identity,
        lookID: String? = nil,
        lookStaerke: Double = 1
    ) {
        self.temperature = temperature
        self.tint = tint
        self.exposure = exposure
        self.luminanceNR = luminanceNR
        self.colorNR = colorNR
        self.sharpness = sharpness
        self.lensCorrection = lensCorrection
        self.highlights = highlights
        self.shadows = shadows
        self.whites = whites
        self.blacks = blacks
        self.contrast = contrast
        self.saturation = saturation
        self.vibrance = vibrance
        self.clarity = clarity
        self.texture = texture
        self.dehaze = dehaze
        self.vignette = vignette
        self.grain = grain
        self.hsl = hsl
        self.lookID = lookID
        self.lookStaerke = lookStaerke
    }

    // MARK: - Vorwärtskompatibles Decoding + v1→v2-Migration

    private enum CodingKeys: String, CodingKey {
        case version
        case temperature, tint, exposure, luminanceNR, colorNR, sharpness, lensCorrection
        case highlights, shadows, whites, blacks, contrast, saturation, vibrance
        case clarity, texture, dehaze, vignette, grain, hsl
        case lookID, lookStaerke
    }

    /// Nur beim Lesen von v1-JSON relevant; v2 schreibt diese Keys nicht mehr.
    private enum LegacyKeys: String, CodingKey {
        case blackPoint, whitePoint
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = RawDevelopParams()

        temperature   = try container.decodeIfPresent(Double.self, forKey: .temperature)
        tint          = try container.decodeIfPresent(Double.self, forKey: .tint)
        exposure      = try container.decodeIfPresent(Double.self, forKey: .exposure) ?? defaults.exposure
        luminanceNR   = try container.decodeIfPresent(Double.self, forKey: .luminanceNR)
        colorNR       = try container.decodeIfPresent(Double.self, forKey: .colorNR)
        sharpness     = try container.decodeIfPresent(Double.self, forKey: .sharpness)
        lensCorrection = try container.decodeIfPresent(Bool.self, forKey: .lensCorrection) ?? defaults.lensCorrection

        contrast      = try container.decodeIfPresent(Double.self, forKey: .contrast) ?? defaults.contrast
        saturation    = try container.decodeIfPresent(Double.self, forKey: .saturation) ?? defaults.saturation
        vibrance      = try container.decodeIfPresent(Double.self, forKey: .vibrance) ?? defaults.vibrance

        let fileVersion = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        version = Self.currentVersion

        if fileVersion >= 2 {
            highlights = try container.decodeIfPresent(Double.self, forKey: .highlights) ?? 0
            shadows    = try container.decodeIfPresent(Double.self, forKey: .shadows) ?? 0
            whites     = try container.decodeIfPresent(Double.self, forKey: .whites) ?? 0
            blacks     = try container.decodeIfPresent(Double.self, forKey: .blacks) ?? 0
        } else {
            // v1 → v2: gleiche Wirkung, neue Skala. `highlights`/`shadows` waren −1…0
            // bzw. 0…+1 → ×100. `blackPoint`/`whitePoint` (0…0.2, „crush"/„clip") sind
            // in v2 die NEGATIVE Richtung von Schwarz/Weiß — Vorzeichen spiegeln.
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            let oldHighlights = try container.decodeIfPresent(Double.self, forKey: .highlights) ?? 0
            let oldShadows    = try container.decodeIfPresent(Double.self, forKey: .shadows) ?? 0
            let oldBlackPoint = try legacy.decodeIfPresent(Double.self, forKey: .blackPoint) ?? 0
            let oldWhitePoint = try legacy.decodeIfPresent(Double.self, forKey: .whitePoint) ?? 0
            highlights = oldHighlights * 100
            shadows    = oldShadows * 100
            blacks     = -(oldBlackPoint / 0.2) * 100
            whites     = -(oldWhitePoint / 0.2) * 100
        }

        clarity  = try container.decodeIfPresent(Double.self, forKey: .clarity) ?? 0
        texture  = try container.decodeIfPresent(Double.self, forKey: .texture) ?? 0
        dehaze   = try container.decodeIfPresent(Double.self, forKey: .dehaze) ?? 0
        vignette = try container.decodeIfPresent(Double.self, forKey: .vignette) ?? 0
        grain    = try container.decodeIfPresent(Double.self, forKey: .grain) ?? 0
        hsl      = try container.decodeIfPresent(HSLMixerParams.self, forKey: .hsl) ?? .identity
        lookID   = try container.decodeIfPresent(String.self, forKey: .lookID)
        lookStaerke = try container.decodeIfPresent(Double.self, forKey: .lookStaerke) ?? 1
    }

    // MARK: - JSON-Helfer

    /// JSON-Repräsentation für `RawDevelopState.paramsJSON` / `DevelopPreset.paramsJSON`.
    /// Leerstring, falls die Kodierung wider Erwarten scheitert (soll nie passieren, da
    /// alle Felder simple Value-Typen sind).
    func encodedJSON() -> String {
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    init?(json: String) {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(RawDevelopParams.self, from: data)
        else { return nil }
        self = decoded
    }
}
