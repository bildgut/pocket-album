import CoreGraphics
import Foundation

/// Die mitgelieferten Looks. Statisch im Code — kein `@Model`, keine Schema-Version.
/// Vier Familien: Fuji und Leica (aus Beschreibungen abgestimmt), Schwarzweiß-Varianten,
/// Analog (an Pixelmator Pro gemessen, siehe unten).
///
/// Die Namen sind Marken ihrer Inhaber (Fujifilm, Leica); die Werte sind Annäherungen aus
/// der beschriebenen Charakteristik der Vorbilder, keine Originalkurven. Nachjustieren
/// heißt hier eine Zahl ändern, nicht Logik anfassen — die Kurven sind bewusst als fünf
/// nackte Stützpunkte notiert, nicht hinter Hilfsfunktionen versteckt.
///
/// HSL-Werte in Schwarzweiß-Looks wirken **vor** der Entsättigung (siehe
/// `FilmLookRenderer`) und simulieren so Farbfilter: Ein Gelbfilter hellt Gelb/Orange
/// auf und dunkelt Blau ab.
enum FilmLookCatalog {

    static func look(id: String) -> FilmLook? {
        alle.first { $0.id == id }
    }

    static let alle: [FilmLook] = fuji + leica + schwarzweiss + analog + modelliert + community

    // MARK: - Fuji

    private static let fuji: [FilmLook] = [
        FilmLook(
            id: "fuji-provia", name: "Provia", familie: .fuji,
            hinweis: "Nach Adobes Kameraprofil PROVIA/Std v2 für die Fujifilm X-T3 gemessen — Fit 6 → 2.2 bei Wirkung 10",
            kurve: kurve(0.033, 0.256, 0.498, 0.799, 1.000),
            hsl: hsl(rot: (-10, 0, 21), gelb: (20, 0, -15), gruen: (10, 28, -6), aqua: (-20, 48, 0)),
            kontrast: 1.05, saettigung: 1.05,
            weiss: 48, schwarz: 88, klarheit: -8
        ),
        FilmLook(
            id: "fuji-velvia", name: "Velvia", familie: .fuji,
            hinweis: "Nach Adobes Kameraprofil Velvia/Kräftig v2 für die Fujifilm X-T3 gemessen — Fit 17 → 3.0 bei Wirkung 13",
            kurve: kurve(0.003, 0.275, 0.517, 0.809, 1.000),
            hsl: hsl(rot: (20, 38, 6), orange: (0, -12, 0), gelb: (20, 12, -15), gruen: (40, 27, -15), aqua: (30, -32, 21), blau: (10, 15, 0)),
            kontrast: 1.08, saettigung: 1.20, vibrance: 0.15,
            lichter: -20, weiss: 88, schwarz: 88
        ),
        FilmLook(
            id: "fuji-astia", name: "Astia", familie: .fuji,
            hinweis: "Nach Adobes Kameraprofil ASTIA/Weich v2 für die Fujifilm X-T3 gemessen — Fit 16 → 6.2 bei Wirkung 11",
            kurve: kurve(0.000, 0.183, 0.486, 0.783, 1.000),
            hsl: hsl(rot: (20, 43, -9), orange: (0, -2, 6), gelb: (0, 40, -30), gruen: (20, 48, -66), aqua: (10, 32, 0), blau: (0, 20, 0)),
            kontrast: 0.95, saettigung: 1.10, vibrance: 0.1,
            schatten: -28, weiss: 68, klarheit: 8
        ),
        FilmLook(
            id: "fuji-classic-chrome", name: "Classic Chrome", familie: .fuji,
            hinweis: "Nach Adobes Kameraprofil CLASSIC CHROME v2 für die Fujifilm X-T3 gemessen — Fit 17 → 2.8 bei Wirkung 12",
            kurve: kurve(0.048, 0.274, 0.508, 0.810, 0.995),
            hsl: hsl(rot: (-10, -12, 9), orange: (0, -8, 10), gelb: (0, -2, -15), gruen: (40, 12, -6), aqua: (-20, 72, -24), blau: (-40, -8, 0)),
            kontrast: 1.08, saettigung: 0.92, vibrance: -0.05,
            splitToning: SplitToning(schattenFarbton: 200, schattenStaerke: 6, lichterFarbton: 60, lichterStaerke: 0, balance: 0),
            schwarz: 88, waerme: 20
        ),
        FilmLook(
            id: "fuji-classic-negative", name: "Classic Negative", familie: .fuji,
            hinweis: "Farbnegativ-Anmutung — kühle Schatten, verschobenes Grün, hartes Licht",
            kurve: kurve(0.05, 0.21, 0.5, 0.78, 0.97),
            hsl: hsl(
                rot: (5, -10, 0), gelb: (-10, 0, 5), gruen: (15, -15, 0),
                aqua: (0, -10, 0), blau: (0, -15, 0)
            ),
            kontrast: 1.12, saettigung: 0.85,
            splitToning: SplitToning(
                schattenFarbton: 160, schattenStaerke: 10,
                lichterFarbton: 30, lichterStaerke: 8, balance: 0
            )
        ),
        FilmLook(
            id: "fuji-nostalgic-negative", name: "Nostalgic Neg.", familie: .fuji,
            hinweis: "Warme Lichter, weiche Schatten — Farbdruck der Siebziger",
            kurve: kurve(0.06, 0.27, 0.52, 0.77, 0.96),
            hsl: hsl(orange: (0, 10, 0), gelb: (0, 5, 0), aqua: (0, -15, 0), blau: (0, -20, 0)),
            kontrast: 0.98, saettigung: 0.95,
            splitToning: SplitToning(
                schattenFarbton: 30, schattenStaerke: 8,
                lichterFarbton: 40, lichterStaerke: 18, balance: 20
            )
        ),
        FilmLook(
            id: "fuji-eterna", name: "Eterna", familie: .fuji,
            hinweis: "Nach Adobes Kameraprofil ETERNA/Cinema v2 für die Fujifilm X-T3 gemessen — Fit 24 → 2.3 bei Wirkung 6",
            kurve: kurve(0.000, 0.180, 0.474, 0.764, 0.994),
            hsl: hsl(rot: (10, -18, -30), orange: (0, -8, -15), gelb: (0, -12, -30), gruen: (80, 68, -54), aqua: (-10, 20, -24), blau: (-30, 2, -15)),
            kontrast: 0.98, saettigung: 0.82,
            splitToning: SplitToning(schattenFarbton: 200, schattenStaerke: 0, lichterFarbton: 215, lichterStaerke: 12, balance: 0),
            lichter: 20, schatten: 20, weiss: 88, dunst: 8, waerme: 20
        ),
        FilmLook(
            id: "fuji-acros", name: "Acros", familie: .fuji,
            hinweis: "Nach Adobes Kameraprofil ACROS v2 für die Fujifilm X-T3 gemessen — Fit 15 → 3.3 bei Wirkung 15",
            kurve: kurve(0.045, 0.322, 0.515, 0.814, 0.997),
            hsl: hsl(rot: (0, 0, -29), orange: (0, 0, -6), gelb: (0, 0, -30), gruen: (0, 0, -15), aqua: (0, 0, -6), blau: (0, 0, -4)),
            kontrast: 1.10, saettigung: 0.00, korn: 15,
            schatten: -20, weiss: 8, schwarz: 88, klarheit: -8
        ),
        FilmLook(
            id: "fuji-pro-neg-hi", name: "Pro Neg. Hi", familie: .fuji,
            hinweis: "Nach Adobes Kameraprofil Pro Neg Hi v2 für die Fujifilm X-T3 gemessen — Fit 5 → 2.4 bei Wirkung 11",
            kurve: kurve(0.008, 0.241, 0.498, 0.800, 0.998),
            hsl: hsl(rot: (20, -12, 15), gelb: (10, 28, -15), gruen: (20, 12, -9), aqua: (-10, 28, 6)),
            kontrast: 1.05, saettigung: 0.95,
            weiss: 88, schwarz: 88
        ),
    ]

    // MARK: - Leica

    private static let leica: [FilmLook] = [
        // Gemessen an der Leica Q3 (07.09.2026): Kamera-JPGs mit Look gegen das Kamera-JPG
        // „Standard" derselben Szene (Stativ, manuell, DNG+JPG). Die Basis ist also Leicas
        // Standard-Rendering, nicht Adobe Farbe wie bei den übrigen Familien.
        FilmLook(
            id: "leica-vivid", name: "Leica Vivid", familie: .leica,
            hinweis: "An der Leica Q3 gemessen — Kamera-Look Vivid gegen Standard, Fit 23 → 3.3 bei Wirkung 7",
            kurve: kurve(0.038, 0.359, 0.558, 0.775, 1.0),
            hsl: hsl(rot: (-30, -12, 6), orange: (0, -32, 0), blau: (-30, -12, -39)),
            kontrast: 1.12, saettigung: 0.96,
            splitToning: SplitToning(schattenFarbton: 0, schattenStaerke: 0, lichterFarbton: 30, lichterStaerke: 6, balance: 0),
            schwarz: 88, klarheit: -20
        ),
        FilmLook(
            id: "leica-teal", name: "Leica Teal", familie: .leica,
            hinweis: "An der Leica Q3 gemessen — Kamera-Look „Teal“ gegen Standard, Fit 5 → 1.9 bei Wirkung 5",
            kurve: kurve(0.0, 0.238, 0.486, 0.753, 1.0),
            hsl: hsl(rot: (20, -40, -9), orange: (0, -8, 0), blau: (-10, -72, -54)),
            kontrast: 1.0, saettigung: 0.94,
            splitToning: SplitToning(schattenFarbton: 0, schattenStaerke: 0, lichterFarbton: 45, lichterStaerke: 12, balance: 0),
            schatten: -20, weiss: 8, schwarz: 32
        ),
        FilmLook(
            id: "leica-mono-natural", name: "Leica Monochrom Natural", familie: .leica,
            hinweis: "An der Leica Q3 gemessen — Kamera-Look B&W Natural gegen Standard, Fit 2 → 1.2 bei Wirkung 5",
            kurve: kurve(0.002, 0.253, 0.503, 0.756, 1.0),
            hsl: hsl(rot: (0, 0, 15), orange: (0, 0, 6), blau: (0, 0, -9)),
            kontrast: 1.0, saettigung: 0
        ),
        FilmLook(
            id: "leica-greg-williams", name: "Leica Greg Williams", familie: .leica,
            hinweis: "An der Leica Q3 gemessen — Leica Look „Greg Williams“ (Schwarzweiß) gegen Standard, Fit 7 → 3.1 bei Wirkung 8",
            kurve: kurve(0.002, 0.245, 0.515, 0.775, 1.0),
            hsl: hsl(rot: (0, 0, 24), orange: (0, 0, 15), blau: (0, 0, 15)),
            kontrast: 1.0, saettigung: 0,
            schatten: -20, weiss: 12
        ),
        FilmLook(
            id: "leica-selenium", name: "Leica Selenium", familie: .leica,
            hinweis: "Schwarzweiß mit selenfarbener, kühler Tönung in den Schatten — beschrieben, kein Kamera-JPG vorhanden",
            kurve: kurve(0.02, 0.23, 0.5, 0.78, 0.99),
            kontrast: 1.08, saettigung: 0,
            splitToning: SplitToning(
                schattenFarbton: 265, schattenStaerke: 22,
                lichterFarbton: 260, lichterStaerke: 6, balance: -15
            ),
            korn: 8
        ),
    ]

    // MARK: - Schwarzweiß-Varianten

    private static let schwarzweiss: [FilmLook] = [
        FilmLook(
            id: "sw-acros-gelb", name: "Acros + Gelbfilter", familie: .schwarzweiss,
            hinweis: "Nach Adobes Kameraprofil ACROS+Ge v2 für die Fujifilm X-T3 gemessen — Fit 18 → 3.1 bei Wirkung 16",
            kurve: kurve(0.042, 0.293, 0.517, 0.820, 0.997),
            hsl: hsl(rot: (0, 0, 21), orange: (0, 0, 12), gelb: (0, 0, -19), gruen: (0, 0, -21), aqua: (0, 0, -10), blau: (0, 0, -40)),
            kontrast: 1.10, saettigung: 0.00, korn: 15,
            weiss: 48, schwarz: 88, klarheit: -8
        ),
        FilmLook(
            id: "sw-acros-rot", name: "Acros + Rotfilter", familie: .schwarzweiss,
            hinweis: "Nach Adobes Kameraprofil ACROS+R v2 für die Fujifilm X-T3 gemessen — Fit 24 → 3.8 bei Wirkung 19",
            kurve: kurve(0.040, 0.305, 0.513, 0.817, 0.996),
            hsl: hsl(rot: (0, 0, 45), orange: (0, 0, 34), gelb: (0, 0, -11), gruen: (0, 0, -11), aqua: (0, 0, -41), blau: (0, 0, -51)),
            kontrast: 1.15, saettigung: 0.00, korn: 15,
            weiss: 52, schwarz: 48, klarheit: -12, dunst: -20
        ),
        FilmLook(
            id: "sw-acros-gruen", name: "Acros + Grünfilter", familie: .schwarzweiss,
            hinweis: "Nach Adobes Kameraprofil ACROS+G v2 für die Fujifilm X-T3 gemessen — Fit 17 → 3.7 bei Wirkung 15",
            kurve: kurve(0.047, 0.320, 0.513, 0.811, 0.993),
            hsl: hsl(rot: (0, 0, -39), orange: (0, 0, -23), gelb: (0, 0, -30), gruen: (0, 0, -15), aqua: (0, 0, 24), blau: (0, 0, -15)),
            kontrast: 1.10, saettigung: 0.00, korn: 15,
            schatten: -20, weiss: 8, schwarz: 88, klarheit: -8
        ),
        FilmLook(
            id: "sw-fuji-monochrom", name: "Fuji Monochrom", familie: .schwarzweiss,
            hinweis: "Nach Adobes Kameraprofil Monochrom v2 für die Fujifilm X-T3 gemessen — Fit 7 → 1.8 bei Wirkung 13",
            kurve: kurve(0.008, 0.201, 0.487, 0.799, 1.000),
            hsl: hsl(rot: (0, 0, -6), gelb: (0, 0, -24), gruen: (0, 0, -36)),
            kontrast: 1.0, saettigung: 0,
            weiss: 68
        ),
        FilmLook(
            id: "sw-sepia", name: "Sepia", familie: .schwarzweiss,
            hinweis: "Klassische Braunfärbung mit weichem Kontrast",
            kurve: kurve(0.04, 0.26, 0.52, 0.77, 0.97),
            kontrast: 0.96, saettigung: 0,
            splitToning: SplitToning(
                schattenFarbton: 38, schattenStaerke: 22,
                lichterFarbton: 40, lichterStaerke: 18, balance: 0
            ),
            korn: 12
        ),
    ]

    // MARK: - Analog — an Pixelmator Pro „Klassische Filme" gemessen und gefittet

    /// Anders als die Fuji-/Leica-Einträge stammen diese Zahlen nicht aus Beschreibungen,
    /// sondern aus einer Messung (Befund: `docs/superpowers/specs/2026-09-06-film-look-
    /// analog-messung.md`): Jedes Pixelmator-Preset wurde auf ein Testbild angewendet,
    /// exportiert und mit dem Original verglichen; Kurve, Sättigung und Tönungsstärken
    /// wurden danach per Koordinatenabstieg so gefittet, dass unser Renderer Pixelmators
    /// Ergebnis am nächsten kommt (Restabstand 2–6 von 255 bei Zielwirkungen von 8–17).
    /// Hue/Sat der Farbbänder kommen aus den Preset-Definitionen (Sat halbiert); deren
    /// **Lum-Werte gehören auf 0** — in allen fünf Fits war das das Optimum.
    /// Die Namen sind eigene Arbeitstitel nach Charakter.
    private static let analog: [FilmLook] = [
        FilmLook(
            id: "analog-kraeftig-warm", name: "Analog Kräftig", familie: .analog,
            hinweis: "Gemessen an Pixelmator „Klassische Filme 01“ — Fit 8.1 → 5.9 bei Wirkung 16.9",
            kurve: kurve(0.0, 0.214, 0.461, 0.742, 1.0),
            hsl: hsl(rot: (65, -2, 0), orange: (-5, -2, 0), gelb: (-50, -8, 0), gruen: (50, -12, 0), aqua: (0, -15, 0), blau: (-25, -5, 0), lila: (60, -18, 0), magenta: (65, -18, 0)),
            saettigung: 1.07, vibrance: 0,
            korn: 0,
            kanalkurven: KanalKurven(
                rot: kurve(0.0, 0.174, 0.498, 0.84, 1.0),
                gruen: kurve(0.0, 0.179, 0.542, 0.836, 1.0),
                blau: kurve(0.0, 0.173, 0.531, 0.844, 1.0)
            ),
            vignette: 15
        ),
        FilmLook(
            id: "analog-cyan", name: "Analog Cyan", familie: .analog,
            hinweis: "Gemessen an Pixelmator „Klassische Filme 03“ — Fit 12.1 → 6.9 bei Wirkung 15.7",
            kurve: kurve(0.01, 0.167, 0.438, 0.719, 1.0),
            hsl: hsl(rot: (60, -10, 0), orange: (-20, 5, 0), gelb: (-5, -8, 0), gruen: (45, -10, 0), aqua: (55, -12, 0), blau: (-25, -2, 0), lila: (30, -13, 0), magenta: (60, -15, 0)),
            saettigung: 1.38, vibrance: 0,
            korn: 0,
            kanalkurven: KanalKurven(
                rot: kurve(0.0, 0.201, 0.531, 0.814, 1.0),
                gruen: kurve(0.0, 0.231, 0.534, 0.799, 1.0),
                blau: kurve(0.0, 0.244, 0.528, 0.803, 1.0)
            ),
            vignette: 15
        ),
    ]

    // MARK: - Gemessen an Pixelmator Pros übrigen Sammlungen (per Automator-Action)

    /// Modern Films, Cinematic, Landscape, Vintage, Urban, Night, Black & White — Erstwerte
    /// mit dem an „Klassische Filme" kalibrierten Modell aus den Preset-Definitionen übersetzt (Kurven je Kanal + Tonwerte + Lichter-Regler → Kurve;
    /// Kanaldrift + Farbbalance → Split-Toning; Kurvensteilheit + Sättigungsregler →
    /// Sättigung; Schwarzweiß-Kanalgewichte → Band-Helligkeit), danach am 07.09.2026 **am Bild
    /// gefittet**: Pixelmators Automator-Action wendet jedes Preset headless an (Befund-
    /// Dokument), der Fit minimiert den Pixelabstand. Die Hinweiszeile trägt das Ergebnis.
    /// Seit Kanalkurven und Vignette im Look sind, kommen die r/g/b-Kurven 1:1 aus den Plists
    /// und Cinematic 05 / Urban 05 sind wieder dabei. Namen sind Arbeitstitel.
    private static let modelliert: [FilmLook] = [
        FilmLook(
            id: "analog-modern-verblasst-teal", name: "Analog Verblasst Teal", familie: .analog,
            hinweis: "Gemessen an Pixelmator „Modern Films 03“ — Fit 6.1 → 2.6 bei Wirkung 15.2",
            kurve: kurve(0.014, 0.211, 0.491, 0.734, 1.0),
            hsl: hsl(rot: (25, -2, 0), orange: (-20, 10, 0), gelb: (-65, 0, 0), gruen: (15, -10, 0), aqua: (-45, -8, 0), blau: (-5, -10, 0), lila: (25, -5, 0), magenta: (25, 10, 0)),
            saettigung: 0.75, vibrance: 0,
            korn: 0,
            kanalkurven: KanalKurven(
                rot: kurve(0.0, 0.122, 0.556, 0.806, 1.0),
                gruen: kurve(0.0, 0.192, 0.559, 0.844, 1.0),
                blau: kurve(0.0, 0.199, 0.558, 0.83, 1.0)
            ),
            vignette: 0
        ),
        FilmLook(
            id: "kino-blau", name: "Kino Blau", familie: .kino,
            hinweis: "Gemessen an Pixelmator „Cinematic 01“ — Fit 5.9 → 3.6 bei Wirkung 31.6",
            kurve: kurve(0.026, 0.21, 0.436, 0.666, 0.961),
            hsl: hsl(rot: (100, 15, 0), orange: (10, 5, 0), gelb: (-100, 35, 0), gruen: (70, -22, 0), aqua: (50, 50, 0), blau: (-15, 12, 0), lila: (-100, -10, 0), magenta: (100, -15, 0)),
            saettigung: 1.17, vibrance: 0,
            splitToning: SplitToning(schattenFarbton: 259, schattenStaerke: 7, lichterFarbton: 210, lichterStaerke: 24, balance: 0),
            korn: 0,
            kanalkurven: KanalKurven(
                rot: kurve(0.0, 0.167, 0.415, 0.736, 0.905),
                gruen: kurve(0.0, 0.181, 0.454, 0.766, 0.924),
                blau: kurve(0.021, 0.204, 0.412, 0.671, 0.736)
            ),
            vignette: 0
        ),
        FilmLook(
            id: "kino-gold-teal", name: "Kino Gold Teal", familie: .kino,
            hinweis: "Gemessen an Pixelmator „Cinematic 02“ — Fit 12.5 → 9.0 bei Wirkung 27.9",
            kurve: kurve(0.013, 0.204, 0.373, 0.643, 0.923),
            hsl: hsl(rot: (100, -8, 0), orange: (10, 8, 0), gelb: (-100, -5, 0), gruen: (100, -45, 0), aqua: (45, 0, 0), blau: (-45, -2, 0), lila: (70, -25, 0), magenta: (100, -10, 0)),
            saettigung: 1.38, vibrance: 0,
            splitToning: SplitToning(schattenFarbton: 0, schattenStaerke: 0, lichterFarbton: 113, lichterStaerke: 38, balance: 0),
            korn: 0,
            kanalkurven: KanalKurven(
                rot: kurve(0.01, 0.142, 0.551, 0.822, 0.978),
                gruen: kurve(0.018, 0.244, 0.526, 0.767, 0.971),
                blau: kurve(0.03, 0.271, 0.53, 0.774, 0.979)
            ),
            vignette: 15
        ),
        FilmLook(
            id: "kino-gold-gedaempft", name: "Kino Gold Gedämpft", familie: .kino,
            hinweis: "Gemessen an Pixelmator „Cinematic 03“ — Fit 11.0 → 5.0 bei Wirkung 17.6",
            kurve: kurve(0.016, 0.21, 0.459, 0.695, 0.897),
            hsl: hsl(rot: (35, 3, 0), orange: (10, 2, 0), gelb: (-100, 18, 0), gruen: (-100, -15, 0), aqua: (85, 18, 0), blau: (-45, 10, 0), lila: (-70, -15, 0), magenta: (70, -2, 0)),
            saettigung: 1.13, vibrance: 0,
            splitToning: SplitToning(schattenFarbton: 329, schattenStaerke: 4, lichterFarbton: 52, lichterStaerke: 24, balance: 0),
            korn: 0,
            kanalkurven: KanalKurven(
                rot: kurve(0.004, 0.246, 0.504, 0.746, 0.985),
                gruen: kurve(0.003, 0.248, 0.5, 0.74, 0.978),
                blau: kurve(0.003, 0.248, 0.502, 0.737, 0.973)
            ),
            vignette: 15
        ),
        FilmLook(
            id: "kino-gedaempft", name: "Kino Gedämpft", familie: .kino,
            hinweis: "Gemessen an Pixelmator „Cinematic 05“ — Fit 27.6 → 6.5 bei Wirkung 44.5",
            kurve: kurve(0.027, 0.202, 0.501, 0.751, 1.0),
            hsl: hsl(rot: (40, -12, 0), orange: (0, -5, 0), gelb: (-35, -5, 0), aqua: (-20, -10, 0), blau: (10, -18, 0), lila: (0, -30, 0), magenta: (0, -30, 0)),
            saettigung: 1.16, vibrance: 0.15,
            splitToning: SplitToning(schattenFarbton: 10, schattenStaerke: 16, lichterFarbton: 175, lichterStaerke: 8, balance: 0),
            korn: 15,
            kanalkurven: KanalKurven(
                rot: kurve(0.0, 0.272, 0.476, 0.694, 1.0),
                gruen: kurve(0.0, 0.276, 0.5, 0.702, 1.0),
                blau: kurve(0.0, 0.203, 0.524, 0.742, 1.0)
            ),
            vignette: 100
        ),
        FilmLook(
            id: "kino-gold-gedaempft-2", name: "Kino Gold Gedämpft 2", familie: .kino,
            hinweis: "Gemessen an Pixelmator „Cinematic 06“ — Fit 33.2 → 7.9 bei Wirkung 52.6",
            kurve: kurve(0.019, 0.135, 0.314, 0.576, 0.923),
            hsl: hsl(rot: (100, -8, 0), orange: (20, 18, 0), gelb: (8, -15, 0), gruen: (35, -30, 0), aqua: (16, -5, 0), blau: (-45, -5, 0), lila: (-45, -24, 0), magenta: (75, -12, 0)),
            saettigung: 1.38, vibrance: 0,
            splitToning: SplitToning(schattenFarbton: 69, schattenStaerke: 0, lichterFarbton: 42, lichterStaerke: 0, balance: 0),
            korn: 0,
            vignette: 30
        ),
        FilmLook(
            id: "kino-gold", name: "Kino Gold", familie: .kino,
            hinweis: "Gemessen an Pixelmator „Cinematic 07“ — Fit 10.6 → 3.1 bei Wirkung 13.7",
            kurve: kurve(0.067, 0.185, 0.471, 0.717, 0.9),
            hsl: hsl(rot: (50, -14, 0), orange: (-50, -7, 0), gelb: (-85, -5, 0), gruen: (-90, -15, 0), aqua: (20, -22, 0), blau: (-45, -25, 0), lila: (15, -15, 0), magenta: (20, -10, 0)),
            saettigung: 0.72, vibrance: 0.15,
            splitToning: SplitToning(schattenFarbton: 0, schattenStaerke: 8, lichterFarbton: 30, lichterStaerke: 8, balance: 0),
            korn: 0,
            kanalkurven: KanalKurven(
                rot: kurve(0.0, 0.25, 0.5, 0.75, 1.0),
                gruen: kurve(0.0, 0.25, 0.5, 0.75, 1.0),
                blau: kurve(0.0, 0.244, 0.462, 0.704, 1.0)
            ),
            vignette: 0
        ),
        FilmLook(
            id: "landschaft-klar", name: "Landschaft Klar", familie: .landschaft,
            hinweis: "Gemessen an Pixelmator „Landscape 01“ — Fit 9.4 → 2.9 bei Wirkung 16.3",
            kurve: kurve(0.0, 0.175, 0.399, 0.685, 0.993),
            hsl: hsl(orange: (-20, 8, 0), gelb: (50, -5, 0), gruen: (50, 30, 0), aqua: (10, 10, 0), blau: (30, 8, 0)),
            saettigung: 1.03, vibrance: 0,
            splitToning: SplitToning(schattenFarbton: 112, schattenStaerke: 5, lichterFarbton: 247, lichterStaerke: 42, balance: 0),
            korn: 0,
            kanalkurven: KanalKurven(
                rot: kurve(0.0, 0.199, 0.579, 0.848, 1.0),
                gruen: kurve(0.0, 0.157, 0.559, 0.84, 1.0),
                blau: kurve(0.0, 0.186, 0.606, 0.865, 1.0)
            ),
            vignette: 0
        ),
        FilmLook(
            id: "landschaft-blau-gedaempft", name: "Landschaft Blau Gedämpft", familie: .landschaft,
            hinweis: "Gemessen an Pixelmator „Landscape 02“ — Fit 16.5 → 7.1 bei Wirkung 14.5",
            kurve: kurve(0.062, 0.177, 0.367, 0.677, 0.998),
            hsl: hsl(rot: (45, -2, 0), orange: (-20, 5, 0), gelb: (-40, -5, 0), gruen: (45, -22, 0), aqua: (35, -15, 0), blau: (-40, 20, 0), lila: (50, -30, 0), magenta: (50, -8, 0)),
            saettigung: 1.1, vibrance: 0,
            splitToning: SplitToning(schattenFarbton: 195, schattenStaerke: 8, lichterFarbton: 160, lichterStaerke: 8, balance: 0),
            korn: 24,
            kanalkurven: KanalKurven(
                rot: kurve(0.0, 0.25, 0.568, 0.802, 1.0),
                gruen: kurve(0.0, 0.235, 0.574, 0.827, 1.0),
                blau: kurve(0.0, 0.257, 0.561, 0.826, 1.0)
            ),
            vignette: 0
        ),
        FilmLook(
            id: "landschaft-hell", name: "Landschaft Hell", familie: .landschaft,
            hinweis: "Gemessen an Pixelmator „Landscape 05“ — Fit 10.1 → 7.3 bei Wirkung 11.0",
            kurve: kurve(0.044, 0.176, 0.463, 0.742, 0.963),
            hsl: hsl(rot: (20, -5, 0), orange: (10, -10, 0), gelb: (-50, -8, 0), gruen: (60, 0, 0), aqua: (-35, -10, 0), blau: (85, 20, 0), lila: (30, -18, 0), magenta: (70, -12, 0)),
            saettigung: 1.03, vibrance: 0,
            korn: 0,
            kanalkurven: KanalKurven(
                rot: kurve(0.0, 0.252, 0.549, 0.8, 1.0),
                gruen: kurve(0.0, 0.261, 0.557, 0.798, 1.0),
                blau: kurve(0.0, 0.254, 0.556, 0.805, 1.0)
            ),
            vignette: 0
        ),
        FilmLook(
            id: "vintage-gedaempft", name: "Vintage Gedämpft", familie: .vintage,
            hinweis: "Gemessen an Pixelmator „Vintage 04“ — Fit 17.7 → 8.9 bei Wirkung 25.0",
            kurve: kurve(0.09, 0.159, 0.355, 0.701, 1.0),
            hsl: hsl(rot: (45, -12, 0), orange: (-25, 5, 0), gelb: (25, -5, 0), gruen: (10, -20, 0), aqua: (50, 10, 0), blau: (-60, -38, 0), lila: (50, -30, 0), magenta: (50, -8, 0)),
            saettigung: 0.98, vibrance: 0,
            korn: 24,
            kanalkurven: KanalKurven(
                rot: kurve(0.0, 0.217, 0.512, 0.785, 1.0),
                gruen: kurve(0.0, 0.224, 0.52, 0.779, 1.0),
                blau: kurve(0.0, 0.24, 0.535, 0.786, 1.0)
            ),
            vignette: 15
        ),
        FilmLook(
            id: "vintage-gedaempft-2", name: "Vintage Gedämpft 2", familie: .vintage,
            hinweis: "Gemessen an Pixelmator „Vintage 05“ — Fit 23.4 → 4.6 bei Wirkung 47.1",
            kurve: kurve(0.024, 0.094, 0.297, 0.629, 0.99),
            hsl: hsl(rot: (30, -18, 0), orange: (30, 8, 0), gelb: (5, -15, 0), gruen: (0, -28, 0), aqua: (10, -12, 0), blau: (0, -8, 0), lila: (20, -50, 0), magenta: (20, -32, 0)),
            saettigung: 0.9, vibrance: 0,
            splitToning: SplitToning(schattenFarbton: 0, schattenStaerke: 0, lichterFarbton: 0, lichterStaerke: 16, balance: 0),
            korn: 0,
            vignette: 15
        ),
        FilmLook(
            id: "urban-blau-gedaempft", name: "Urban Blau Gedämpft", familie: .urban,
            hinweis: "Gemessen an Pixelmator „Urban 01“ — Fit 17.1 → 7.7 bei Wirkung 22.4",
            kurve: kurve(0.0, 0.234, 0.405, 0.71, 1.0),
            hsl: hsl(rot: (-15, -5, 0), orange: (25, -8, 0), gelb: (-30, -15, 0), gruen: (10, -10, 0), aqua: (60, 0, 0), blau: (45, -28, 0), lila: (5, -25, 0), magenta: (-90, -18, 0)),
            saettigung: 0.74, vibrance: -0.25,
            korn: 0,
            kanalkurven: KanalKurven(
                rot: kurve(0.0, 0.125, 0.447, 0.726, 0.987),
                gruen: kurve(0.0, 0.181, 0.535, 0.76, 0.992),
                blau: kurve(0.006, 0.256, 0.588, 0.789, 0.996)
            ),
            vignette: 15
        ),
        FilmLook(
            id: "urban-blau", name: "Urban Blau", familie: .urban,
            hinweis: "Gemessen an Pixelmator „Urban 04“ — Fit 10.9 → 5.1 bei Wirkung 19.1",
            kurve: kurve(0.018, 0.194, 0.404, 0.706, 1.0),
            hsl: hsl(rot: (-20, -8, 0), orange: (-35, 5, 0), gelb: (-100, 20, 0), gruen: (100, 5, 0), aqua: (20, -18, 0), blau: (-40, -15, 0), lila: (55, 10, 0), magenta: (85, 15, 0)),
            saettigung: 1.13, vibrance: 0,
            korn: 0,
            kanalkurven: KanalKurven(
                rot: kurve(0.022, 0.198, 0.487, 0.748, 0.923),
                gruen: kurve(0.04, 0.218, 0.512, 0.802, 0.954),
                blau: kurve(0.017, 0.239, 0.552, 0.779, 0.923)
            ),
            vignette: 15
        ),
        FilmLook(
            id: "urban-gedaempft", name: "Urban Gedämpft", familie: .urban,
            hinweis: "Gemessen an Pixelmator „Urban 05“ — Fit 31.1 → 7.3 bei Wirkung 50.9",
            kurve: kurve(0.0, 0.147, 0.442, 0.719, 1.0),
            hsl: hsl(rot: (60, -5, 0), orange: (25, -5, 0), gelb: (-80, -20, 0), gruen: (25, -10, 0), aqua: (60, 0, 0), blau: (20, -22, 0), lila: (5, -25, 0), magenta: (50, -18, 0)),
            saettigung: 0.74, vibrance: -0.35,
            korn: 0,
            vignette: 100
        ),
        FilmLook(
            id: "nacht-gold-gedaempft", name: "Nacht Gold Gedämpft", familie: .urban,
            hinweis: "Gemessen an Pixelmator „Night 02“ — Fit 7.5 → 3.8 bei Wirkung 16.9",
            kurve: kurve(0.0, 0.22, 0.453, 0.63, 0.999),
            hsl: hsl(rot: (-20, 0, 0), orange: (-40, -5, 0), gelb: (-35, -8, 0), gruen: (-15, -12, 0), aqua: (30, -10, 0), blau: (35, -15, 0), lila: (0, -5, 0), magenta: (65, 0, 0)),
            saettigung: 0.94, vibrance: 0,
            splitToning: SplitToning(schattenFarbton: 30, schattenStaerke: 16, lichterFarbton: 60, lichterStaerke: 16, balance: 0),
            korn: 0,
            kanalkurven: KanalKurven(
                rot: kurve(0.035, 0.377, 0.66, 0.871, 0.979),
                gruen: kurve(0.035, 0.319, 0.618, 0.845, 0.977),
                blau: kurve(0.046, 0.28, 0.514, 0.807, 0.962)
            ),
            vignette: 0
        ),
        FilmLook(
            id: "nacht-blau-gedaempft", name: "Nacht Blau Gedämpft", familie: .urban,
            hinweis: "Gemessen an Pixelmator „Night 03“ — Fit 7.9 → 4.6 bei Wirkung 15.1",
            kurve: kurve(0.009, 0.223, 0.444, 0.597, 1.0),
            hsl: hsl(rot: (0, -2, 0), orange: (35, 10, 0), gelb: (-40, -2, 0), gruen: (10, -12, 0), aqua: (-20, 7, 0), blau: (15, -10, 0), lila: (-45, -15, 0), magenta: (60, -20, 0)),
            saettigung: 1.17, vibrance: 0,
            korn: 0,
            kanalkurven: KanalKurven(
                rot: kurve(0.021, 0.219, 0.517, 0.863, 0.947),
                gruen: kurve(0.06, 0.317, 0.584, 0.859, 0.948),
                blau: kurve(0.098, 0.452, 0.706, 0.865, 0.947)
            ),
            vignette: 0
        ),
        FilmLook(
            id: "nacht-gold-gedaempft-2", name: "Nacht Gold Gedämpft 2", familie: .urban,
            hinweis: "Gemessen an Pixelmator „Night 04“ — Fit 9.7 → 3.4 bei Wirkung 15.5",
            kurve: kurve(0.003, 0.272, 0.493, 0.674, 1.0),
            hsl: hsl(rot: (10, 0, 0), orange: (10, 0, 0), gelb: (-5, 8, 0), gruen: (40, -13, 0), aqua: (60, 10, 0), blau: (30, 5, 0), lila: (-30, -12, 0), magenta: (70, 5, 0)),
            saettigung: 1.38, vibrance: 0,
            korn: 0,
            kanalkurven: KanalKurven(
                rot: kurve(0.031, 0.286, 0.694, 0.869, 0.955),
                gruen: kurve(0.034, 0.24, 0.654, 0.861, 0.952),
                blau: kurve(0.053, 0.271, 0.597, 0.816, 0.954)
            ),
            vignette: 0
        ),
        FilmLook(
            id: "mono-weich", name: "Mono Weich", familie: .schwarzweiss,
            hinweis: "Gemessen an Pixelmator „Black & White 01“ — Fit 8.7 → 7.2 bei Wirkung 14.6",
            kurve: kurve(0.023, 0.172, 0.53, 0.825, 0.982),
            hsl: hsl(rot: (0, 0, 14), orange: (0, 0, 11), gelb: (0, 0, 5), aqua: (0, 0, 2), blau: (0, 0, 6), lila: (0, 0, 3), magenta: (0, 0, 7)),
            saettigung: 0.0, vibrance: 0,
            splitToning: SplitToning(schattenFarbton: 35, schattenStaerke: 0, lichterFarbton: 40, lichterStaerke: 0, balance: 0),
            korn: 30,
            vignette: 15
        ),
        FilmLook(
            id: "mono-weich-getoent", name: "Mono Weich Getönt", familie: .schwarzweiss,
            hinweis: "Gemessen an Pixelmator „Black & White 02“ — Fit 10.3 → 6.3 bei Wirkung 14.4",
            kurve: kurve(0.021, 0.163, 0.48, 0.705, 0.938),
            hsl: hsl(rot: (0, 0, 12), orange: (0, 0, 9), gelb: (0, 0, 6), gruen: (0, 0, 4), aqua: (0, 0, 5), blau: (0, 0, 8), lila: (0, 0, 4), magenta: (0, 0, 6)),
            saettigung: 0.0, vibrance: 0,
            splitToning: SplitToning(schattenFarbton: 35, schattenStaerke: 0, lichterFarbton: 40, lichterStaerke: 0, balance: 0),
            korn: 30,
            vignette: 0
        ),
        FilmLook(
            id: "mono-gruenfilter", name: "Mono Grünfilter", familie: .schwarzweiss,
            hinweis: "Gemessen an Pixelmator „Black & White 03“ — Fit 11.5 → 4.3 bei Wirkung 15.7",
            kurve: kurve(0.032, 0.165, 0.447, 0.791, 0.997),
            hsl: hsl(rot: (0, 0, 12), orange: (0, 0, 9), gelb: (0, 0, 10), gruen: (0, 0, 16), aqua: (0, 0, 8), blau: (0, 0, 6), lila: (0, 0, 3), magenta: (0, 0, 6)),
            saettigung: 0.0, vibrance: 0,
            splitToning: SplitToning(schattenFarbton: 35, schattenStaerke: 0, lichterFarbton: 40, lichterStaerke: 0, balance: 0),
            korn: 0,
            vignette: 15
        ),
        FilmLook(
            id: "mono-gruenfilter-getoent", name: "Mono Grünfilter Getönt", familie: .schwarzweiss,
            hinweis: "Gemessen an Pixelmator „Black & White 06“ — Fit 15.3 → 6.6 bei Wirkung 18.2",
            kurve: kurve(0.075, 0.23, 0.432, 0.613, 0.956),
            hsl: hsl(rot: (0, 0, 28), orange: (0, 0, 21), gelb: (0, 0, 26), gruen: (0, 0, 40), aqua: (0, 0, 26), blau: (0, 0, 28), lila: (0, 0, 14), magenta: (0, 0, 14)),
            saettigung: 0.0, vibrance: 0,
            splitToning: SplitToning(schattenFarbton: 35, schattenStaerke: 0, lichterFarbton: 10, lichterStaerke: 6, balance: 0),
            korn: 30,
            vignette: 0
        ),
    ]

    // MARK: - Community — aus Lightroom-Presets des Nutzers gemessen

    /// Acht Community-Presets aus Lightroom. Startwerte kommen aus den XMP-Daten (Farbmischer
    /// und Split Toning 1:1, Kurvenpunkte umgerechnet, Basisregler in RawDevelop-Skalen),
    /// gefittet gegen Lightrooms eigenen Export desselben Bildes. Die Namen sind die
    /// Preset-Titel; der Hinweis nennt den Autor.
    private static let community: [FilmLook] = [
        FilmLook(
            id: "community-shutterspeed", name: "1/40 Shutterspeed", familie: .community,
            hinweis: "Nach dem Lightroom-Community-Preset von Vishal Kuberkar gemessen — Fit 39 → 7.4 bei Wirkung 15",
            kurve: kurve(0.047, 0.239, 0.439, 0.766, 0.960),
            hsl: hsl(rot: (0, -4, 0), orange: (0, 2, 2), gelb: (-12, -3, 0), aqua: (30, -15, -30), blau: (-32, -3, -14), lila: (0, -13, 0), magenta: (0, -15, 0)),
            kontrast: 1.00, saettigung: 0.76, vibrance: 0.4,
            splitToning: SplitToning(schattenFarbton: 55, schattenStaerke: 20, lichterFarbton: 183, lichterStaerke: 5, balance: 0),
            korn: 0, vignette: 30,
            belichtung: 0.3, lichter: -32, schatten: -8, weiss: 44, schwarz: 100, klarheit: 3, struktur: 7, dunst: 8, waerme: 7, toenung: -6
        ),
        FilmLook(
            id: "community-barber-life", name: "Barber Life", familie: .community,
            hinweis: "Nach dem Lightroom-Community-Preset von anthony martin gemessen — Fit 41 → 8.8 bei Wirkung 88",
            kurve: kurve(0.000, 0.046, 0.116, 0.449, 0.611),
            kontrast: 1.00, saettigung: 0.76, vibrance: 0.0,
            splitToning: SplitToning(schattenFarbton: 47, schattenStaerke: 5, lichterFarbton: 207, lichterStaerke: 50, balance: 0),
            korn: 0, vignette: 60,
            belichtung: 0.3, lichter: -24, schatten: 0, weiss: 96, schwarz: 12, klarheit: -21, struktur: 10, dunst: -16, waerme: -24, toenung: 0
        ),
        FilmLook(
            id: "community-castle", name: "Castle", familie: .community,
            hinweis: "Nach dem Lightroom-Community-Preset von Dominik C gemessen — Fit 73 → 12.5 bei Wirkung 37",
            kurve: kurve(0.059, 0.158, 0.280, 0.758, 0.972),
            hsl: hsl(rot: (0, -24, 0), orange: (0, 12, 9), gelb: (-12, -42, 0), gruen: (0, -44, 0), aqua: (-50, -80, 0), blau: (-10, -21, -12), lila: (0, -75, 0), magenta: (0, -15, 10)),
            kontrast: 1.00, saettigung: 0.55, vibrance: -0.18,
            splitToning: SplitToning(schattenFarbton: 135, schattenStaerke: 20, lichterFarbton: 168, lichterStaerke: 20, balance: 0),
            korn: 0, vignette: 60,
            belichtung: 0.3, lichter: -20, schatten: -4, weiss: 84, schwarz: 20, klarheit: 15, struktur: 7, dunst: -60, waerme: -40, toenung: 0
        ),
        FilmLook(
            id: "community-lonely-liquor", name: "Lonely Liquor", familie: .community,
            hinweis: "Nach dem Lightroom-Community-Preset von Julia DeVine gemessen — Fit 39 → 8.7 bei Wirkung 40",
            kurve: kurve(0.000, 0.100, 0.273, 0.744, 0.992),
            kontrast: 1.00, saettigung: 0.97, vibrance: 0.0,
            splitToning: SplitToning(schattenFarbton: 37, schattenStaerke: 0, lichterFarbton: 208, lichterStaerke: 0, balance: 0),
            korn: 0, vignette: 16,
            belichtung: 0.0, lichter: -8, schatten: 0, weiss: 96, schwarz: 12, klarheit: 17, struktur: 10, dunst: -22, waerme: -20, toenung: 0
        ),
        FilmLook(
            id: "community-motocross", name: "Motocross", familie: .community,
            hinweis: "Nach dem Lightroom-Community-Preset von Habeeb Sujan gemessen — Fit 17 → 3.6 bei Wirkung 18",
            kurve: kurve(0.002, 0.193, 0.396, 0.729, 0.980),
            hsl: hsl(rot: (24, 0, 3), orange: (-12, 13, 9), gelb: (-48, -13, 9), gruen: (24, -22, -13), blau: (-36, 0, -13), magenta: (0, -18, 0)),
            kontrast: 1.00, saettigung: 1.04, vibrance: 0.0,
            splitToning: SplitToning(schattenFarbton: 84, schattenStaerke: 16, lichterFarbton: 199, lichterStaerke: 54, balance: 0),
            korn: 0, vignette: 0,
            belichtung: 0.0, lichter: 0, schatten: -12, weiss: 28, schwarz: 4, klarheit: -20, struktur: 0, dunst: 0, waerme: -24, toenung: 1
        ),
        FilmLook(
            id: "community-parque-alerce", name: "Parque Alerce", familie: .community,
            hinweis: "Nach dem Lightroom-Community-Preset von Michell Otto Cifuentes gemessen — Fit 53 → 6.5 bei Wirkung 66",
            kurve: kurve(0.090, 0.137, 0.220, 0.569, 0.915),
            hsl: hsl(rot: (0, 4, 0), orange: (0, 4, 0), gelb: (0, 10, 0), gruen: (0, 10, 0), aqua: (-10, -71, -45), blau: (-100, -43, -51), lila: (0, 10, 0)),
            kontrast: 1.00, saettigung: 1.14, vibrance: -0.2,
            splitToning: SplitToning(schattenFarbton: 55, schattenStaerke: 10, lichterFarbton: 183, lichterStaerke: 100, balance: 0),
            korn: 0, vignette: 0,
            belichtung: -0.3, lichter: 32, schatten: 20, weiss: 100, schwarz: 0, klarheit: 28, struktur: 0, dunst: 32, waerme: -20, toenung: 0
        ),
        FilmLook(
            id: "community-streetart", name: "Streetart RBx", familie: .community,
            hinweis: "Nach dem Lightroom-Community-Preset von François B gemessen — Fit 29 → 12.5 bei Wirkung 31",
            kurve: kurve(0.078, 0.158, 0.307, 0.839, 0.979),
            hsl: hsl(rot: (-23, 100, -77), orange: (9, 86, 32), gelb: (-39, 54, 27)),
            kontrast: 1.00, saettigung: 0.45, vibrance: -0.2,
            splitToning: SplitToning(schattenFarbton: 72, schattenStaerke: 10, lichterFarbton: 187, lichterStaerke: 66, balance: 0),
            korn: 0, vignette: 45,
            belichtung: 0.3, lichter: 8, schatten: 0, weiss: 28, schwarz: 0, klarheit: -60, struktur: 0, dunst: 12, waerme: -4, toenung: 0
        ),
        FilmLook(
            id: "community-tokyo-japan", name: "Tokyo Japan", familie: .community,
            hinweis: "Nach dem Lightroom-Community-Preset von antreas vezakis gemessen — Fit 85 → 8.7 bei Wirkung 42",
            kurve: kurve(0.120, 0.198, 0.316, 0.765, 0.963),
            hsl: hsl(rot: (0, -21, 0), orange: (0, 11, 8), gelb: (-12, -36, 0), gruen: (0, 4, 0), aqua: (-20, -92, 0), blau: (-60, -39, -11), lila: (0, -64, 0), magenta: (0, -71, 0)),
            kontrast: 1.00, saettigung: 0.76, vibrance: -0.18,
            splitToning: SplitToning(schattenFarbton: 79, schattenStaerke: 10, lichterFarbton: 55, lichterStaerke: 5, balance: 0),
            korn: 0, vignette: 15,
            belichtung: 0.0, lichter: -20, schatten: 0, weiss: 100, schwarz: -8, klarheit: 31, struktur: 8, dunst: 48, waerme: 7, toenung: 1
        ),
    ]

    // MARK: - Schreibhilfen

    /// Fünf y-Werte an den festen Stellen x = 0, ¼, ½, ¾, 1.
    private static func kurve(
        _ y0: CGFloat, _ y1: CGFloat, _ y2: CGFloat, _ y3: CGFloat, _ y4: CGFloat
    ) -> ToneCurve {
        ToneCurve([
            CGPoint(x: 0, y: y0), CGPoint(x: 0.25, y: y1), CGPoint(x: 0.5, y: y2),
            CGPoint(x: 0.75, y: y3), CGPoint(x: 1, y: y4),
        ])
    }

    /// Bänder als `(hue, sat, lum)`; nicht genannte bleiben neutral.
    private static func hsl(
        rot: (Double, Double, Double)? = nil,
        orange: (Double, Double, Double)? = nil,
        gelb: (Double, Double, Double)? = nil,
        gruen: (Double, Double, Double)? = nil,
        aqua: (Double, Double, Double)? = nil,
        blau: (Double, Double, Double)? = nil,
        lila: (Double, Double, Double)? = nil,
        magenta: (Double, Double, Double)? = nil
    ) -> HSLMixerParams {
        var m = HSLMixerParams.identity
        func band(_ t: (Double, Double, Double)?) -> HSLBand {
            guard let t else { return HSLBand() }
            return HSLBand(hue: t.0, sat: t.1, lum: t.2)
        }
        m.rot = band(rot); m.orange = band(orange); m.gelb = band(gelb); m.gruen = band(gruen)
        m.aqua = band(aqua); m.blau = band(blau); m.lila = band(lila); m.magenta = band(magenta)
        return m
    }
}
