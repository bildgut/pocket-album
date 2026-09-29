import Foundation

/// Erkennt Bilder, die nicht aus einer Kamera stammen, sondern aus einem Messenger,
/// einem Web-Download oder einem sozialen Netzwerk.
///
/// Bewusst pauschal statt nach Quelle aufgeschlüsselt: der Nutzer soll einen Schalter
/// umlegen, nicht Muster pflegen. Der Preis ist, dass Fehltreffer nicht eingegrenzt
/// werden können — dafür lässt sich die Regel im Editor mit anderen kombinieren.
enum WebOriginDetector {

    /// Dateiendungen, die im Web verbreitet sind, aus Kameras aber praktisch nie kommen.
    private static let webFormats: Set<String> = ["webp", "gif"]

    /// Bekannte Namensmuster der gängigen Messenger, Netzwerke und Browser-Downloads.
    /// Alle gegen den kleingeschriebenen Dateinamen geprüft, alle am Namensanfang
    /// verankert (`^`). Unverankerte Teilzeichenketten wie ein früheres "download"/
    /// "unnamed"-Substring-Kriterium träfen auch von Hand vergebene Namen wie
    /// "Familienalbum_1978_Tante_unnamed.jpg" oder "IMG_Bootssteg_Download_
    /// Bestätigung.jpg" — echte Kamerafotos mit vollem EXIF. Browser-Downloads heißen
    /// dagegen buchstäblich "download.jpg", "download (1).jpg" oder "unnamed.jpg";
    /// die Verankerung trifft genau das.
    private static let filenamePatterns: [String] = [
        #"^img-\d{8}-wa\d+\."#,                               // WhatsApp Android
        #"^whatsapp image \d{4}-"#,                           // WhatsApp iOS/Desktop
        #"^photo_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}\."#,     // Telegram Desktop
        #"^signal-\d{4}-\d{2}-\d{2}-"#,                       // Signal
        #"^fb_img_\d+\."#,                                    // Facebook
        #"^received_\d+\."#,                                  // Messenger
        #"^snapchat-\d+\."#,                                  // Snapchat
        #"^viber_image_"#,                                    // Viber
        #"^image \(\d+\)\."#,                                 // Browser-Download-Duplikat
        #"^download(\s*\(\d+\))?\."#,                         // Browser-Download
        #"^unnamed(\s*\(\d+\))?\."#,                          // Browser-Download ohne Namen
    ]

    /// Vorkompilierte Fassung von `filenamePatterns`. `NSRegularExpression` kompiliert
    /// das Muster beim Anlegen einmalig statt — wie zuvor bei `String.range(of:options:
    /// .regularExpression)` — bei jedem Aufruf neu. Bei ~155.000 Assets mal bis zu elf
    /// Mustern, und weil die Live-Vorschau im Smart-Album-Editor bei jeder Regeländerung
    /// neu auswertet, macht das spürbar etwas aus.
    private static let compiledFilenamePatterns: [NSRegularExpression] =
        filenamePatterns.map { pattern in
            // Force-try ist hier vertretbar: Die Muster sind Compile-Zeit-Konstanten aus
            // dieser Datei — ein ungültiges Regex wäre ein Programmierfehler, kein
            // Laufzeitfall, der behandelt werden müsste.
            try! NSRegularExpression(pattern: pattern)
        }

    /// Obergrenze für Kriterium 3. Messenger skalieren Bilder auf wenige hundert
    /// Kilobyte herunter; darüber ist die Vermutung nicht mehr tragfähig.
    private static let maxStrippedFileSize = 500 * 1024

    /// - Parameters:
    ///   - asset: Das zu prüfende Asset.
    ///   - exifIsAuthoritative: Ob die EXIF-Felder des Assets verlässlich sind, also
    ///     ob der Server für dieses Asset schon nach EXIF gefragt wurde. Bei `false`
    ///     entfallen die beiden EXIF-lesenden Schritte: Kriterium 3 und der
    ///     *heuristische* Teil des Screenshot-Ausschlusses (PNG ohne Kamerafelder).
    ///     Endung, Dateiname und der Screenshot-Ausschluss über Namensmuster brauchen
    ///     kein EXIF und gelten weiter.
    /// - Returns: `true` = sicherer Treffer, `false` = sicheres Nein, `nil` = unbekannt.
    ///   `nil` entsteht genau dann, wenn die EXIF-freien Kriterien nicht gegriffen haben
    ///   **und** die EXIF-Felder nichts aussagen — dann ist schlicht nicht entscheidbar,
    ///   ob das Bild aus dem Web stammt.
    ///
    ///   Warum `Bool?` statt einer zweiten Methode „hat über Name/Endung getroffen":
    ///   Die Dreiwertigkeit entsteht hier, wo die Kriterien stehen. Eine zweite Methode
    ///   müsste der Aufrufer mit dem Gate-Flag wieder zu einem Gesamtergebnis
    ///   zusammensetzen — genau diese Rekonstruktion im Aufrufer war die Quelle des
    ///   Negierungs-Fehlers (ein gegatetes `false` wurde zu `true` umgedreht). Mit `Bool?`
    ///   erzwingt der Compiler beim Aufrufer das Auspacken; „unbekannt" kann nicht mehr
    ///   versehentlich als „nein" gelesen werden.
    static func isWebOrMessenger(_ asset: Asset, exifIsAuthoritative: Bool) -> Bool? {
        // 0) Screenshots haben ebenfalls kein EXIF und würden das Album dominieren.
        // Für sie gibt es die eigene Regel `isScreenshot`.
        //
        // Hier nur der **definitive** Teil des Ausschlusses — die Namensmuster. Ein
        // „Screenshot 2024-01-01.png" ist kein Web-Bild, egal wie es sonst aussieht,
        // und das steht ohne jedes EXIF fest.
        //
        // Der EXIF-lesende Teil des Screenshot-Ausschlusses folgt erst nach den eigenen
        // Namenskriterien (Schritt 2b). Stand er wie früher komplett vorn, verschluckte er
        // sichere Treffer: „download.png" oder „FB_IMG_123.png" mit ungeprüftem EXIF
        // fielen unter die PNG-Heuristik und lieferten `nil`, obwohl das verankerte
        // Namensmuster ein sicheres Ja ist — genau die zugesicherte Eigenschaft
        // „ein WhatsApp-Bild wird auch ohne EXIF gefunden" ging damit verloren.
        if ScreenshotDetector.matchesScreenshotFilename(asset) { return false }

        let name = asset.originalFileName.lowercased()

        // 1) Web-typische Dateiendung
        let ext = (asset.originalFileName as NSString).pathExtension.lowercased()
        if webFormats.contains(ext) { return true }

        // 2) Bekanntes Namensmuster
        let fullRange = NSRange(name.startIndex..<name.endIndex, in: name)
        for pattern in compiledFilenamePatterns
        where pattern.firstMatch(in: name, range: fullRange) != nil {
            return true
        }

        // Bewusste Priorisierung: Die Schritte 1 und 2 stehen vor der PNG-Heuristik.
        // Ein geprüftes PNG, das nach der Heuristik ein Screenshot wäre und zugleich
        // „download.png" heißt, trifft deshalb. Das verankerte Download-Namensmuster ist
        // das stärkere Signal — es beschreibt, woher die Datei kam, während die Heuristik
        // nur aus „PNG ohne Kamerafelder" rät. Vorher unterdrückte der pauschale
        // Frühausstieg auch diesen Fall.

        // Ab hier führt nur noch Kriterium 3 zu einem Ja. Ist die Dateigröße bekannt und
        // über der Obergrenze, kann das nicht mehr eintreten — dann steht das Nein fest,
        // auch ohne EXIF-Prüfung und ohne die Screenshot-Frage zu klären. `fileSizeInByte`
        // wird nie geschätzt, sondern stammt immer aus einer echten Server-EXIF-Antwort
        // (siehe Begründung an `fileSizeMaxKB` im SmartAlbumEvaluator); ein vorhandener
        // Wert ist deshalb unabhängig vom Gate-Status belastbar.
        if let size = asset.exifInfo?.fileSizeInByte, size > maxStrippedFileSize { return false }

        // 2b) Heuristischer Teil des Screenshot-Ausschlusses: PNG ohne Kamerafelder.
        // Bei ungeprüftem EXIF ist dieses Nein selbst nicht belastbar — ein `false` von
        // hier dürfte eine Negation nicht zu einem Treffer machen. Also „unbekannt".
        switch ScreenshotDetector.isScreenshot(asset, exifIsAuthoritative: exifIsAuthoritative) {
        case true?:  return false
        case nil:    return nil
        case false?: break
        }

        // 3) EXIF gestrippt und klein — nur wenn die EXIF-Felder etwas aussagen.
        // Ohne EXIF-Prüfung ist hier nichts entscheidbar: „kein Hersteller/Modell" kann
        // „gestrippt" heißen oder „nie gefragt". Deshalb `nil` (unbekannt) statt `false`.
        guard exifIsAuthoritative else { return nil }
        let make  = (asset.exifInfo?.make ?? "").trimmingCharacters(in: .whitespaces)
        let model = (asset.exifInfo?.model ?? "").trimmingCharacters(in: .whitespaces)
        guard make.isEmpty, model.isEmpty else { return false }
        guard asset.exifInfo?.latitude == nil, asset.exifInfo?.longitude == nil else { return false }
        guard let size = asset.exifInfo?.fileSizeInByte else { return false }
        return size <= maxStrippedFileSize
    }
}
