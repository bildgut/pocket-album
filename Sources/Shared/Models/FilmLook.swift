import Foundation

/// Kategorie eines Looks — steuert die Chips im Raster. `schwarzweiss` ist eine eigene
/// Familie für die S/W-Varianten ohne Kamera-Vorbild (Filtersimulationen, Sepia);
/// `analog` sind Looks, die an Pixelmator Pros „Klassische Filme" **gemessen** wurden
/// (Vorher/Nachher am Bild, siehe FilmLookCatalog).
enum LookFamilie: String, Codable, Sendable, CaseIterable {
    case fuji, leica, schwarzweiss, analog
    /// Aus Pixelmator Pros übrigen Sammlungen **modelliert** (Cinematic, Landscape, Vintage,
    /// Urban + Night) — mit dem an „Klassische Filme" kalibrierten Modell, nicht am Bild
    /// gemessen. Siehe FilmLookCatalog.
    case kino, landschaft, vintage, urban
    /// Aus Lightroom-Community-Presets des Nutzers gemessen (XMP-Werte als Start, Fit gegen
    /// Lightrooms Export).
    case community
}

/// Ein Film-Look: ein editorunabhängiger Satz Effektwerte, den ``FilmLookRenderer``
/// auf ein `CIImage` anwendet — dieselbe Stufe für RAW- und JPEG-Pfad.
///
/// Bewusst **kein** `RawDevelopParams`: Der kennt keine freie Kurve und kein
/// Split-Toning, und er trägt Stufe-1-Felder (Weißabgleich, Rauschminderung), die ein
/// Look nie setzen darf — ein Look mit `temperature` überschriebe den Weißabgleich
/// des Nutzers.
///
/// Decoding ist vorwärtskompatibel: Fehlende Effektfelder fallen auf ihren Neutralwert
/// zurück, wie bei `RawDevelopParams`.
struct FilmLook: Codable, Equatable, Sendable, Identifiable {
    let id: String
    var name: String
    var familie: LookFamilie
    var hinweis: String

    var kurve: ToneCurve
    var hsl: HSLMixerParams
    var kontrast: Double      // 0.5…2, wie RawDevelopParams.contrast
    var saettigung: Double    // 0…2
    var vibrance: Double      // −1…+1
    var splitToning: SplitToning?
    var korn: Double          // 0…100
    /// Kurven je Farbkanal, **vor** der gemeinsamen Kurve angewendet (Pixelmators Reihenfolge).
    var kanalkurven: KanalKurven?
    var vignette: Double      // 0…100, wie RawDevelopParams.vignette

    // Basisregler — dieselben Skalen wie RawDevelopParams; sie laufen im Renderer als
    // erste Stufe über `RawDevelopEngine.applyToneStage`. Nötig für Lightroom-Presets,
    // die zu großen Teilen aus Belichtung, Lichter/Schatten und Klarheit bestehen.
    var belichtung: Double    // EV, −3…+3
    var lichter: Double       // −100…+100
    var schatten: Double      // −100…+100
    var weiss: Double         // −100…+100
    var schwarz: Double       // −100…+100
    var klarheit: Double      // −100…+100
    var struktur: Double      // −100…+100
    var dunst: Double         // −100…+100
    var waerme: Double        // −100…+100 (Weißabgleich wärmer/kühler)
    var toenung: Double       // −100…+100 (Grün ↔ Magenta)

    init(
        id: String,
        name: String,
        familie: LookFamilie,
        hinweis: String,
        kurve: ToneCurve = .identity,
        hsl: HSLMixerParams = .identity,
        kontrast: Double = 1,
        saettigung: Double = 1,
        vibrance: Double = 0,
        splitToning: SplitToning? = nil,
        korn: Double = 0,
        kanalkurven: KanalKurven? = nil,
        vignette: Double = 0,
        belichtung: Double = 0, lichter: Double = 0, schatten: Double = 0, weiss: Double = 0, schwarz: Double = 0,
        klarheit: Double = 0, struktur: Double = 0, dunst: Double = 0, waerme: Double = 0, toenung: Double = 0
    ) {
        self.id = id
        self.name = name
        self.familie = familie
        self.hinweis = hinweis
        self.kurve = kurve
        self.hsl = hsl
        self.kontrast = kontrast
        self.saettigung = saettigung
        self.vibrance = vibrance
        self.splitToning = splitToning
        self.korn = korn
        self.kanalkurven = kanalkurven
        self.vignette = vignette
        self.belichtung = belichtung; self.lichter = lichter; self.schatten = schatten; self.weiss = weiss; self.schwarz = schwarz
        self.klarheit = klarheit; self.struktur = struktur; self.dunst = dunst; self.waerme = waerme; self.toenung = toenung
    }

    /// Ob einer der Basisregler steht — dann läuft die erste Renderstufe.
    var hatBasisregler: Bool {
        belichtung != 0 || lichter != 0 || schatten != 0 || weiss != 0 || schwarz != 0
            || klarheit != 0 || struktur != 0 || dunst != 0 || waerme != 0 || toenung != 0
    }

    /// Alle Effektwerte neutral — unabhängig von Name und Familie.
    var isIdentity: Bool {
        kurve.isIdentity && hsl.isIdentity
            && kontrast == 1 && saettigung == 1 && vibrance == 0
            && (splitToning?.isIdentity ?? true)
            && korn == 0
            && (kanalkurven?.isIdentity ?? true)
            && vignette == 0
            && !hatBasisregler
    }

    var istSchwarzweiss: Bool { saettigung == 0 }

    // MARK: - Vorwärtskompatibles Decoding

    private enum CodingKeys: String, CodingKey {
        case id, name, familie, hinweis
        case kurve, hsl, kontrast, saettigung, vibrance, splitToning, korn
        case kanalkurven, vignette
        case belichtung, lichter, schatten, weiss, schwarz, klarheit, struktur, dunst, waerme, toenung
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        familie = try c.decode(LookFamilie.self, forKey: .familie)
        hinweis = try c.decodeIfPresent(String.self, forKey: .hinweis) ?? ""
        kurve = try c.decodeIfPresent(ToneCurve.self, forKey: .kurve) ?? .identity
        hsl = try c.decodeIfPresent(HSLMixerParams.self, forKey: .hsl) ?? .identity
        kontrast = try c.decodeIfPresent(Double.self, forKey: .kontrast) ?? 1
        saettigung = try c.decodeIfPresent(Double.self, forKey: .saettigung) ?? 1
        vibrance = try c.decodeIfPresent(Double.self, forKey: .vibrance) ?? 0
        splitToning = try c.decodeIfPresent(SplitToning.self, forKey: .splitToning)
        korn = try c.decodeIfPresent(Double.self, forKey: .korn) ?? 0
        kanalkurven = try c.decodeIfPresent(KanalKurven.self, forKey: .kanalkurven)
        vignette = try c.decodeIfPresent(Double.self, forKey: .vignette) ?? 0
        belichtung = try c.decodeIfPresent(Double.self, forKey: .belichtung) ?? 0
        lichter = try c.decodeIfPresent(Double.self, forKey: .lichter) ?? 0
        schatten = try c.decodeIfPresent(Double.self, forKey: .schatten) ?? 0
        weiss = try c.decodeIfPresent(Double.self, forKey: .weiss) ?? 0
        schwarz = try c.decodeIfPresent(Double.self, forKey: .schwarz) ?? 0
        klarheit = try c.decodeIfPresent(Double.self, forKey: .klarheit) ?? 0
        struktur = try c.decodeIfPresent(Double.self, forKey: .struktur) ?? 0
        dunst = try c.decodeIfPresent(Double.self, forKey: .dunst) ?? 0
        waerme = try c.decodeIfPresent(Double.self, forKey: .waerme) ?? 0
        toenung = try c.decodeIfPresent(Double.self, forKey: .toenung) ?? 0
    }
}
