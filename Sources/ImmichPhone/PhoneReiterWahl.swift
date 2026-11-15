import Foundation

/// Die Reiter des iOS-Clients, in der Standardreihenfolge des Tab-Balkens.
enum PhoneReiter: String, Hashable, CaseIterable, Sendable {
    case fotos, alben, entdecken, einstellungen
}

/// Was ein Tipp auf einen Reiter außer dem Wechsel noch auslöst.
///
/// Reiner Wertetyp, damit die Regel ohne SwiftUI prüfbar ist (`PhoneReiterWahlTests`).
/// Die `TabView` in `PhoneRootView` ruft ihn aus dem Setter ihrer Auswahl-Bindung.
enum PhoneReiterWahl {

    static let startReiterSchluessel = "phone.startReiter.v1"

    /// Standardmäßig öffnet die App auf „Fotos“. Nur wer in den Einstellungen
    /// „Alben“ wählt, startet auf dem Alben-Reiter.
    static func ersterReiter(defaults: UserDefaults = AppEnvironment.defaults) -> PhoneReiter {
        guard let roh = defaults.string(forKey: startReiterSchluessel),
              roh == PhoneReiter.alben.rawValue else {
            return .fotos
        }
        return .alben
    }

    static func setzeErstenReiter(_ reiter: PhoneReiter, defaults: UserDefaults = AppEnvironment.defaults) {
        let ziel: PhoneReiter = (reiter == .alben) ? .alben : .fotos
        defaults.set(ziel.rawValue, forKey: startReiterSchluessel)
    }

    static func reihenfolge(erster: PhoneReiter = ersterReiter()) -> [PhoneReiter] {
        switch erster {
        case .alben:
            return [.alben, .fotos, .entdecken, .einstellungen]
        default:
            return [.fotos, .alben, .entdecken, .einstellungen]
        }
    }

    /// Ein erneuter Tipp auf den **schon aktiven** Reiter „Entdecken“ führt zurück zur
    /// Startseite — alle Chips und ein offenes Suchfeld sind danach weg. Der übliche
    /// iOS-Weg „Reiter nochmal antippen = an den Anfang“ (Nutzerwunsch 13.09.2026).
    ///
    /// Der Wechsel **zu** „Entdecken“ aus einem anderen Reiter setzt bewusst nicht
    /// zurück: Wer kurz in „Fotos“ schaut und zurückkommt, findet seine Auswahl wieder.
    static func setztEntdeckenZurueck(aktuell: PhoneReiter, getippt: PhoneReiter) -> Bool {
        aktuell == .entdecken && getippt == .entdecken
    }

    /// Smart Alben (vom Mac-Client gespiegelt, Präfix „✦ “) erscheinen als Abschnitt im
    /// Alben-Reiter — nur, wenn es welche gibt. Ohne Mac-Client gäbe es nie welche.
    static func zeigtSmartAlben(alben: [Album]) -> Bool {
        alben.contains(where: PhoneAlbumSections.istGespiegeltesSmartAlbum)
    }
}
