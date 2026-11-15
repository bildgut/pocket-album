import Foundation

// MARK: - Parameters

/// Die Regler des Anpassen-Panels für Nicht-RAW-Fotos.
///
/// Liegt in `Shared` und ist `Codable`, weil die Werte als Teil einer ``Bearbeitung``
/// am Original auf dem Server landen und Pocket Album sie später lesen soll. Gerendert
/// wird weiter am Mac (`ImageAdjustmentsService`).
struct ImageAdjustmentParams: Hashable, Sendable {

    // MARK: Licht
    var exposure:   Double = 0      // EV −2…+2
    var highlights: Double = 0      // −1…0
    var shadows:    Double = 0      // 0…+1
    var brightness: Double = 0      // −0.5…+0.5
    var contrast:   Double = 1      // 0.5…2
    var blackPoint: Double = 0      // 0…0.2  (crush blacks)
    var lightEnabled: Bool = true

    // MARK: Gradationskurve
    var toneCurve: ToneCurve = .identity
    var curveEnabled: Bool = true

    // MARK: Farbe
    var saturation: Double = 1      // 0…2
    var vibrance:   Double = 0 { didSet { normalisiereFarbModell() } }  // −1…+1  (Lebendigkeit)
    var warmth:     Double = 0      // −1…+1  (Temperatur)
    var tint:       Double = 0      // −1…+1  (Tönung Grün–Magenta)
    var colorEnabled: Bool = true

    // MARK: Farbmischer & Farbtonung
    var hsl: HSLMixerParams = .identity
    var hslEnabled: Bool = true
    var splitToning: SplitToning = .identity
    var splitToningEnabled: Bool = true

    /// Welche Rechnung die Lebendigkeit nutzt, siehe `FarbModell`. Neue Werte rechnen mit dem
    /// aktuellen Modell; ein JSON ohne den Schlüssel stammt aus der `CIVibrance`-Zeit (0).
    /// Bei Lebendigkeit 0 gibt es nichts zu bewahren — dann gilt das aktuelle Modell.
    var farbModell: Int = FarbModell.aktuell

    private mutating func normalisiereFarbModell() {
        if vibrance == 0 { farbModell = FarbModell.aktuell }
    }

    // MARK: Detail
    var clarity:   Double = 0       // −1…+1  (Klarheit, Mitten)
    var texture:   Double = 0       // −1…+1  (Struktur, feine Details)
    var sharpness: Double = 0       // 0…1
    var vignette:  Double = 0       // 0…1
    var detailEnabled: Bool = true

    // MARK: Look
    var lookID: String? = nil
    var lookStaerke: Double = 1     // 0…1

    // MARK: Analoge Artefakte
    var analogArtifacts: AnalogArtifactParams = AnalogArtifactParams()

    // MARK: Identity helpers

    var isIdentity: Bool {
        exposure == 0 && highlights == 0 && shadows == 0 &&
        brightness == 0 && contrast == 1 && blackPoint == 0 &&
        toneCurve.isIdentity &&
        saturation == 1 && vibrance == 0 && warmth == 0 && tint == 0 &&
        hsl.isIdentity && splitToning.isIdentity &&
        clarity == 0 && texture == 0 && sharpness == 0 && vignette == 0 && lookID == nil &&
        analogArtifacts.isIdentity
    }

    var lightIsModified: Bool {
        exposure != 0 || highlights != 0 || shadows != 0 ||
        brightness != 0 || contrast != 1 || blackPoint != 0
    }
    var curveIsModified: Bool { !toneCurve.isIdentity }
    var colorIsModified: Bool { saturation != 1 || vibrance != 0 || warmth != 0 || tint != 0 }
    var hslIsModified: Bool { !hsl.isIdentity }
    var splitToningIsModified: Bool { !splitToning.isIdentity }
    var detailIsModified: Bool { clarity != 0 || texture != 0 || sharpness != 0 || vignette != 0 }
    var artifactsAreModified: Bool { !analogArtifacts.isIdentity }

    // MARK: Section resets

    mutating func resetLight()  { exposure = 0; highlights = 0; shadows = 0; brightness = 0; contrast = 1; blackPoint = 0 }
    mutating func resetCurve()  { toneCurve = .identity }
    mutating func resetColor()  { saturation = 1; vibrance = 0; warmth = 0; tint = 0; farbModell = FarbModell.aktuell }
    mutating func resetHSL()    { hsl = .identity }
    mutating func resetSplitToning() { splitToning = .identity }
    mutating func resetDetail() { clarity = 0; texture = 0; sharpness = 0; vignette = 0 }
    mutating func resetArtifacts() { analogArtifacts = AnalogArtifactParams() }

    static let identity = ImageAdjustmentParams()
}

// MARK: - Codable

/// Jedes Feld ist optional im JSON: Ein Eintrag, der vor einem neuen Regler
/// geschrieben wurde, muss lesbar bleiben — fehlende Felder bekommen den Vorgabewert.
extension ImageAdjustmentParams: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ImageAdjustmentParams()
        self.init()
        exposure = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? d.exposure
        highlights = try c.decodeIfPresent(Double.self, forKey: .highlights) ?? d.highlights
        shadows = try c.decodeIfPresent(Double.self, forKey: .shadows) ?? d.shadows
        brightness = try c.decodeIfPresent(Double.self, forKey: .brightness) ?? d.brightness
        contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? d.contrast
        blackPoint = try c.decodeIfPresent(Double.self, forKey: .blackPoint) ?? d.blackPoint
        lightEnabled = try c.decodeIfPresent(Bool.self, forKey: .lightEnabled) ?? d.lightEnabled
        toneCurve = try c.decodeIfPresent(ToneCurve.self, forKey: .toneCurve) ?? d.toneCurve
        curveEnabled = try c.decodeIfPresent(Bool.self, forKey: .curveEnabled) ?? d.curveEnabled
        saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? d.saturation
        vibrance = try c.decodeIfPresent(Double.self, forKey: .vibrance) ?? d.vibrance
        warmth = try c.decodeIfPresent(Double.self, forKey: .warmth) ?? d.warmth
        tint = try c.decodeIfPresent(Double.self, forKey: .tint) ?? d.tint
        colorEnabled = try c.decodeIfPresent(Bool.self, forKey: .colorEnabled) ?? d.colorEnabled
        hsl = try c.decodeIfPresent(HSLMixerParams.self, forKey: .hsl) ?? d.hsl
        hslEnabled = try c.decodeIfPresent(Bool.self, forKey: .hslEnabled) ?? d.hslEnabled
        splitToning = try c.decodeIfPresent(SplitToning.self, forKey: .splitToning) ?? d.splitToning
        splitToningEnabled = try c.decodeIfPresent(Bool.self, forKey: .splitToningEnabled) ?? d.splitToningEnabled
        farbModell = try c.decodeIfPresent(Int.self, forKey: .farbModell) ?? 0
        clarity = try c.decodeIfPresent(Double.self, forKey: .clarity) ?? d.clarity
        texture = try c.decodeIfPresent(Double.self, forKey: .texture) ?? d.texture
        sharpness = try c.decodeIfPresent(Double.self, forKey: .sharpness) ?? d.sharpness
        vignette = try c.decodeIfPresent(Double.self, forKey: .vignette) ?? d.vignette
        detailEnabled = try c.decodeIfPresent(Bool.self, forKey: .detailEnabled) ?? d.detailEnabled
        lookID = try c.decodeIfPresent(String.self, forKey: .lookID)
        lookStaerke = try c.decodeIfPresent(Double.self, forKey: .lookStaerke) ?? d.lookStaerke
        analogArtifacts = try c.decodeIfPresent(AnalogArtifactParams.self, forKey: .analogArtifacts)
            ?? d.analogArtifacts
        if vibrance == 0 { farbModell = FarbModell.aktuell }
    }
}
