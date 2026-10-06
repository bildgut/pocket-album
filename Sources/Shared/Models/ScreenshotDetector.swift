import Foundation

/// Centralised screenshot detection logic.
/// Mirrors the heuristics from immich-refiner's `isScreenshot()`.
///
/// Die Kriterien zerfallen in zwei Klassen, und diese Trennung ist der Grund für
/// den dreiwertigen Zuschnitt weiter unten:
/// * **Kriterien 1+2 (Namensmuster)** lesen nur den Dateinamen. Sie sind immer
///   entscheidbar und liefern ein definitives Ja.
/// * **Kriterium 3 (PNG ohne Kamerafelder)** liest EXIF. Für ein Asset, dessen EXIF
///   nie beim Server erfragt wurde, sind `make`/`model` nicht „leer", sondern
///   „unbekannt" — das Kriterium ist dort schlicht nicht auswertbar.
enum ScreenshotDetector {

    /// Woran ein Dateiname ein Bildschirmfoto verrät — **eine** Stelle.
    ///
    /// Alle kleingeschrieben; verglichen wird gegen den kleingeschriebenen Namen, in dem
    /// der typografische Apostroph zuvor auf den geraden abgebildet wurde.
    ///
    /// `GridIndexStore.loadPanoramas` schloss dieselben Namen mit einer eigenen Liste
    /// aus fünf `LIKE`-Mustern aus — und der fehlte ausgerechnet **„bildschirmfoto"**.
    /// Auf einem deutschen System heißen Bildschirmfotos genau so. Ein breites
    /// Bildschirmfoto (Ultrawide oder 5K, also über der 4000-px-Grenze) landete damit
    /// in der Medienart „Panoramen".
    static let filenameMarkers: [String] = [
        "screenshot",
        "bildschirmfoto",
        "screen shot",
        "screencapture",
        "captura de pantalla",
        "capture d'écran",
    ]

    /// `LIKE`-Bedingungen für SQLite, aus ``filenameMarkers`` erzeugt.
    ///
    /// Enthält ein Marker einen Apostroph, entstehen **zwei** Muster — gerade und
    /// typografisch. Die Normalisierung, die die Swift-Fassung vorschaltet, gibt es in
    /// SQL nicht, und macOS schreibt „Capture d’écran" mit U+2019.
    ///
    /// `COLLATE NOCASE` faltet nur ASCII. Das genügt: Die Marker unterscheiden sich von
    /// den echten Dateinamen nur in ASCII-Buchstaben („Bildschirmfoto" → „bildschirmfoto").
    static var screenshotNameExclusionSQL: String {
        filenameMarkers
            .flatMap { marker -> [String] in
                marker.contains("'")
                    ? [marker, marker.replacingOccurrences(of: "'", with: "\u{2019}")]
                    : [marker]
            }
            // Apostrophe für das SQL-Literal verdoppeln.
            .map { $0.replacingOccurrences(of: "'", with: "''") }
            .map { "AND originalFileName NOT LIKE '%\($0)%' COLLATE NOCASE" }
            .joined(separator: "\n                  ")
    }

    /// Kriterien 1+2: reine Namensmuster, brauchen kein EXIF.
    ///
    /// Öffentlich, weil `WebOriginDetector` genau diesen definitiven Teil vor seinen
    /// eigenen Namensmustern abfragt, ohne den EXIF-lesenden Rest mitzuziehen.
    static func matchesScreenshotFilename(_ asset: Asset) -> Bool {
        // Der typografische Apostroph wird auf den geraden abgebildet, bevor
        // verglichen wird.
        //
        // macOS legt das französische Bildschirmfoto als „Capture d’écran …“ ab —
        // mit U+2019, nicht mit dem ASCII-Zeichen. Das Muster unten trug den
        // geraden Apostroph und traf deshalb **nie**. Normalisieren statt zwei
        // Schreibweisen zu pflegen: Der nächste Sprachname mit Apostroph erbt die
        // Behandlung, ohne dass jemand daran denken muss.
        let name = asset.originalFileName
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .lowercased()

        // 1) Filename patterns
        if filenameMarkers.contains(where: { name.contains($0) }) {
            return true
        }

        // 2) iOS PNG pattern: IMG_0001.png – IMG_9999.png
        if name.range(of: #"^img_\d{4}\.png$"#, options: .regularExpression) != nil {
            return true
        }

        return false
    }

    /// Dreiwertig: `true` = Treffer, `false` = sicher kein Screenshot, `nil` = unbekannt.
    ///
    /// - Parameter exifIsAuthoritative: Ob die EXIF-Felder des Assets etwas aussagen,
    ///   also ob der Server für dieses Asset schon nach EXIF gefragt wurde.
    ///
    /// `nil` entsteht genau dann, wenn die Namensmuster nicht gegriffen haben, die Datei
    /// aber ein PNG ist und die Kamerafelder nichts aussagen. Ein `false` wäre dort falsch:
    /// Die Smart-Album-Regel `isScreenshot` ist negierbar, und ein negierbares `false`
    /// hätte `familie.png` (echtes Foto, EXIF nie erfragt) über den Umweg
    /// „Nicht: Bildschirmfoto" ebenso falsch einsortiert wie das ungegatete `true`
    /// es direkt tat.
    ///
    /// Warum die Fallunterscheidung hier und nicht im Aufrufer steht: Die Kriterien
    /// existieren nur an dieser Stelle. Ein Aufrufer, der aus „hat über den Namen
    /// getroffen" und dem Gate-Flag selbst ein Gesamtergebnis zusammensetzt, würde
    /// genau die Rekonstruktion wiederholen, die den Negierungs-Fehler erzeugt hat.
    static func isScreenshot(_ asset: Asset, exifIsAuthoritative: Bool) -> Bool? {
        if matchesScreenshotFilename(asset) { return true }

        // 3) PNG without camera make/model → very likely a screenshot
        let ext = (asset.originalFileName as NSString).pathExtension.lowercased()
        guard ext == "png" else { return false }

        // Nur PNGs kommen überhaupt an Kriterium 3 — für alles andere steht das Nein
        // schon fest, unabhängig vom Gate.
        guard exifIsAuthoritative else { return nil }

        let make = (asset.exifInfo?.make ?? "").trimmingCharacters(in: .whitespaces)
        let model = (asset.exifInfo?.model ?? "").trimmingCharacters(in: .whitespaces)
        return make.isEmpty && model.isEmpty
    }

    /// Zweiwertige Fassade für Aufrufer ohne Gate-Wissen (`AssetFilter`, `HighlightScorer`).
    ///
    /// Sie reichen `exifIsAuthoritative: true` durch — damit kann das Ergebnis nie `nil`
    /// werden und `== true` bildet das frühere Verhalten Zeichen für Zeichen ab. Das ist
    /// bewusst so gewählt und nicht etwa `!= nil`: `!= nil` wäre für jedes Asset wahr.
    ///
    /// Vertretbar ist die Annahme dort, weil beide Aufrufer nur filtern bzw. gewichten
    /// und keine Negation kennen — ein Fehltreffer blendet ein Bild in einer Ansicht ein
    /// oder zieht fünf Punkte ab, statt es dauerhaft in ein Album zu schreiben.
    static func isScreenshot(_ asset: Asset) -> Bool {
        isScreenshot(asset, exifIsAuthoritative: true) == true
    }
}
