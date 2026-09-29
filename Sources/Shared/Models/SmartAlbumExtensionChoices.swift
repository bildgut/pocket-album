import Foundation

/// Die Endungen, die der Regel-Picker für `.fileExtensionIs` anbietet — in drei Gruppen.
///
/// Die RAW-Gruppe entsteht aus ``MIMEType/rawExtensions``, derselben Liste, die die Regel
/// `.isRAW` auswertet. Ein festes Array hier wäre genau so auseinandergelaufen wie früher
/// die Upload- und die RAW-Liste; der Test hält beide zusammen.
enum SmartAlbumExtensionChoices {

    struct Eintrag: Hashable, Sendable {
        /// klein, ohne Punkt — so, wie `.fileExtensionIs` vergleicht
        let endung: String
        let beschriftung: String
    }

    struct Gruppe: Sendable {
        let titel: String
        let eintraege: [Eintrag]
    }

    /// Herstellerhinweis je RAW-Endung. Endungen ohne Eintrag erscheinen nackt.
    private static let rawHersteller: [String: String] = [
        "raf": "Fujifilm", "dng": "Leica, Apple, Adobe", "cr2": "Canon", "cr3": "Canon",
        "arw": "Sony", "nef": "Nikon", "orf": "OM System / Olympus", "rw2": "Panasonic",
        "pef": "Pentax", "srw": "Samsung",
    ]

    static let gruppen: [Gruppe] = [
        Gruppe(titel: "Bilder", eintraege: ["jpg", "jpeg", "heic", "png", "webp", "gif", "tiff", "avif"].map { Eintrag(endung: $0, beschriftung: ".\($0)") }),
        Gruppe(titel: "Videos", eintraege: ["mp4", "mov", "m4v", "avi", "mkv"].map { Eintrag(endung: $0, beschriftung: ".\($0)") }),
        Gruppe(titel: "RAW", eintraege: MIMEType.rawExtensions.sorted().map { ext in
            let hersteller = rawHersteller[ext].map { " (\($0))" } ?? ""
            return Eintrag(endung: ext, beschriftung: ".\(ext)\(hersteller)")
        }),
    ]

    static var alle: [Eintrag] { gruppen.flatMap(\.eintraege) }
}
