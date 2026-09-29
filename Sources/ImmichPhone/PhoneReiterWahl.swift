import Foundation

/// Die Reiter des iOS-Clients, in der Reihenfolge des Tab-Balkens.
enum PhoneReiter: Hashable, CaseIterable, Sendable {
    case alben, fotos, entdecken, einstellungen
}

/// Was ein Tipp auf einen Reiter außer dem Wechsel noch auslöst.
///
/// Reiner Wertetyp, damit die Regel ohne SwiftUI prüfbar ist (`PhoneReiterWahlTests`).
/// Die `TabView` in `PhoneRootView` ruft ihn aus dem Setter ihrer Auswahl-Bindung.
enum PhoneReiterWahl {

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
