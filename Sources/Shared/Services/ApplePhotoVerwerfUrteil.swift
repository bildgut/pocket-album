import Foundation

/// Ein in der Import-Vorschau abgewähltes Foto, zum Löschen vorgemerkt.
/// `modificationDate` ist der Stand **zur Zeit der Vorschau** — weicht er beim
/// Löschen ab, hat der Nutzer das Foto inzwischen bearbeitet.
struct ApplePhotoVerwerfKandidat: Equatable, Sendable {
    let localIdentifier: String
    let modificationDate: Date?
}

/// Entscheidet, ob ein abgewähltes Foto aus Apple Fotos gelöscht werden darf.
///
/// Es gibt keine Serverkopie, also keine Byte-Prüfung — die Freigabe beruht auf
/// der ausdrücklichen Entscheidung des Nutzers. Die Schutzregeln verhindern nur
/// die zwei Fälle, in denen diese Entscheidung nicht mehr trägt.
enum ApplePhotoVerwerfUrteil {
    static func urteil(
        existiert: Bool,
        gemeinsameMediathek: Bool?,
        vorschauStand: Date?,
        aktuellerStand: Date?
    ) -> ApplePhotoDeletionVerdict {
        guard existiert else { return .nichtMehrInApplePhotos }
        // Löschen in der gemeinsamen Mediathek wirkte für alle Teilnehmenden.
        switch gemeinsameMediathek {
        case nil:   return .mediathekNichtPrüfbar
        case true?: return .inGeteilterMediathek
        case false?: break
        }
        // Ohne zwei gleiche Stände ist „unverändert" nicht belegt.
        guard let vorschauStand, let aktuellerStand, vorschauStand == aktuellerStand else {
            return .lokalGeändert
        }
        return .abgewähltVerworfen
    }
}
