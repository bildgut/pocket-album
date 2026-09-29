import Foundation

/// Basiskorrektur für Looks im RAW-Pfad.
///
/// Alle Looks sind gegen **Lightrooms** neutrale Entwicklung gefittet (Pixelmator- und
/// Lightroom-Exporte, Adobes Kameraprofile). Apples RAW-Decoder liefert dieselbe Datei aber
/// deutlich anders: an einer X-T3-RAF gemessen (07.09.2026) im Mittel 17 Stufen dunkler und
/// etwas kühler, Abstand 19 von 255. Ein Look auf Apples Neutral lag damit **weiter** vom
/// Fuji-Profil entfernt als gar keiner (22–24 statt 10–13).
///
/// Diese Stufe zieht Apples Neutral auf Lightrooms Neutral (Rest 7.3), bevor der Look kommt —
/// gefittet wie ein Look, mit denselben Reglern. Sie läuft **nur, wenn ein Look aktiv ist**,
/// mit dessen Stärke; ohne Look bleibt die RAW-Entwicklung, wie sie war. Mit ihr treffen
/// Velvia, Classic Chrome, Acros und Provia im RAW-Pfad das Profil auf 8–9.
///
/// Eine Messung, eine Kamera. Der Helligkeits- und Kurvenanteil ist Adobes Stil gegenüber
/// Apples und dürfte für andere Hersteller ähnlich sein; der Farbanteil ist X-T3-spezifisch.
/// Das Rot-Band blieb bewusst frei — es hatte im Messbild zu wenige Pixel, und ein Fit mit
/// Rot war um 0.01 besser bei extremen Werten (Farbton +50, Sättigung −68).
enum RawLookBasis {

    static let korrektur: FilmLook = {
        var hsl = HSLMixerParams.identity
        hsl[.orange] = HSLBand(hue: 0, sat: -60, lum: -24)
        hsl[.gelb] = HSLBand(hue: -10, sat: -32, lum: -36)
        hsl[.gruen] = HSLBand(hue: -50, sat: -8, lum: 6)
        hsl[.aqua] = HSLBand(hue: -20, sat: -32, lum: 21)
        hsl[.blau] = HSLBand(hue: 0, sat: -12, lum: 0)
        return FilmLook(
            id: "raw-basis", name: "RAW-Basis", familie: .fuji,
            hinweis: "Apples neutrale RAW-Entwicklung auf Lightrooms Neutral gezogen — X-T3, Fit 19 → 7.3",
            kurve: ToneCurve([
                CGPoint(x: 0, y: 0.030), CGPoint(x: 0.25, y: 0.316), CGPoint(x: 0.5, y: 0.530),
                CGPoint(x: 0.75, y: 0.711), CGPoint(x: 1, y: 0.948),
            ]),
            hsl: hsl,
            belichtung: 0.3, lichter: -48, schwarz: 60, klarheit: 8, waerme: 40
        )
    }()
}
