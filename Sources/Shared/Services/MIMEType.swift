import Foundation

/// MIME-Typ einer hochzuladenden Datei — **eine** Stelle für alle Upload-Pfade.
///
/// Zuvor gab es zwei Zuordnungen: die hier (aus `UploadManager`) und eine eigene in
/// `ExternalEditorService`. Beide kannten je etwas, das die andere nicht kannte — die
/// eine Videos, die andere TIFF und HEIF —, und keine kannte BMP.
///
/// Der eigentliche Bruch lag aber woanders: Der Import-Dialog in `MainView` nahm 23
/// Endungen an, die Zuordnung kannte 10. Alles Übrige ging als
/// `application/octet-stream` hinaus, darunter **sämtliche RAW-Formate**.
///
/// Dass der Typ zählt und der Rückfall nicht genügt, sagt das Projekt selbst: Für MXF
/// steht in der Roadmap eine eigene Anforderung („UploadManager maps MXF →
/// application/mxf"). Hätte `application/octet-stream` gereicht, hätte es die nicht
/// gebraucht.
enum MIMEType {

    /// Die Endungen, die die App zum Hochladen annimmt — Quelle für den Import-Dialog
    /// **und** für die Zuordnung unten. Getrennte Listen sind genau auseinandergelaufen.
    static let supportedUploadExtensions: Set<String> = Set(byExtension.keys)

    /// Welche Endungen als RAW gelten — Quelle für die Smart-Album-Regel `.isRAW`.
    ///
    /// Bewusst **größer** als die RAW-Schnittmenge von ``supportedUploadExtensions``:
    /// Was diese App nicht selbst hochlädt, kann trotzdem in der Bibliothek liegen,
    /// vom Handy oder aus dem Web. Die Regel muss es erkennen, der Import-Dialog
    /// muss es nicht annehmen — das sind zwei verschiedene Fragen.
    ///
    /// Umgekehrt gilt aber sehr wohl: Was hier hochgeladen werden kann und dabei
    /// einen RAW-Typ bekommt, **muss** die Regel kennen. Genau das war
    /// auseinandergelaufen — `raw` war hochladbar und galt der Regel trotzdem nicht
    /// als RAW. `UploadManagerTests` sichert die Richtung ab.
    static let rawExtensions: Set<String> = [
        "dng", "arw", "cr2", "cr3", "nef", "raf", "orf", "rw2", "pef", "srw", "raw",
    ]

    /// Endungen, deren Inhalt ein Video ist.
    ///
    /// `mxf` zählt dazu, obwohl sein MIME-Typ `application/mxf` lautet — es ist ein
    /// professionelles Videoformat, und für jeden Aufrufer, der Standbilder von
    /// Videos trennt, gehört es auf diese Seite.
    static let videoExtensions: Set<String> = Set(
        byExtension.filter { $0.value.hasPrefix("video/") || $0.value == "application/mxf" }.keys
    )

    /// Hochladbare Endungen ohne Videos — für Pfade, die nur Standbilder verarbeiten.
    static let stillImageUploadExtensions: Set<String> =
        supportedUploadExtensions.subtracting(videoExtensions)

    private static let byExtension: [String: String] = [
        // Bilder
        "jpg":  "image/jpeg",
        "jpeg": "image/jpeg",
        "png":  "image/png",
        "gif":  "image/gif",
        "webp": "image/webp",
        "avif": "image/avif",
        "bmp":  "image/bmp",
        "tiff": "image/tiff",
        "tif":  "image/tiff",
        // HEIC/HEIF bewusst beide auf `image/heic`: So ordnete es der Editor-Pfad
        // schon zu, und dieser Wert läuft in der Praxis. `image/heif` wäre der
        // registrierte Typ — die Umstellung wäre eine Verhaltensänderung ohne Not.
        "heic": "image/heic",
        "heif": "image/heic",

        // RAW. Die App nimmt sie im Import-Dialog an; ohne Zuordnung gingen sie
        // als `application/octet-stream` hinaus.
        "dng":  "image/x-adobe-dng",
        "cr2":  "image/x-canon-cr2",
        "nef":  "image/x-nikon-nef",
        "arw":  "image/x-sony-arw",
        "raw":  "image/x-dcraw",

        // Videos
        "mp4":  "video/mp4",
        "mov":  "video/quicktime",
        "avi":  "video/avi",
        "m4v":  "video/x-m4v",
        "mkv":  "video/x-matroska",
        "webm": "video/webm",
        "mxf":  "application/mxf",
    ]

    static func mimeType(for url: URL) -> String {
        byExtension[url.pathExtension.lowercased()] ?? "application/octet-stream"
    }

    /// Ob die Endung überhaupt zum Hochladen taugt.
    static func isSupported(_ url: URL) -> Bool {
        supportedUploadExtensions.contains(url.pathExtension.lowercased())
    }
}
