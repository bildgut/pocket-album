import Foundation

/// Die Fortschaltung der Diashow als reiner Wertetyp: welches Bild gerade
/// dran ist, welches als Nächstes kommt, und wo die Folge wieder von vorn
/// beginnt. Ohne SwiftUI, ohne Timer, ohne Netz — deshalb prüfbar, siehe
/// `Tests/ImmichPhoneTests/PhoneDiashowFolgeTests.swift`.
///
/// **Warum überhaupt ein eigener Typ.** `PhoneDiashowView` ist eine
/// Vollbildansicht; an ihr selbst lässt sich nichts prüfen. Die einzige Logik,
/// die sie enthält — welcher Index als Nächstes kommt, dass Videos ausgelassen
/// werden, dass es am Ende wieder von vorn losgeht —, ist eine reine Funktion
/// über die Eintragsliste. Genau derselbe Schnitt wie bei `PhoneMediaSource`
/// (`Sources/ImmichPhone/PhoneMediaSource.swift`): Was ohne Umgebung
/// entscheidbar ist, wird ohne Umgebung entschieden.
///
/// **Videos werden ausgelassen — eine Entscheidung, keine Lücke.**
/// Eine Diashow, die auf einem dreiminütigen Video stehenbleibt, ist keine:
/// Der feste 4-Sekunden-Takt würde entweder mitten in die Wiedergabe
/// hineinschalten oder für die Dauer des Videos aussetzen. Beides wäre
/// schlechter als das Auslassen. Die Filterung sitzt bewusst an genau **einer**
/// Stelle, dem `init` unten: Wer sie später umdrehen will, ersetzt dort das
/// `filter` durch die volle Liste und gibt der Ansicht eine Anzeigedauer je
/// Eintrag mit (für ein Video dessen `duration`, statt der festen 4 Sekunden)
/// — `aktuelles`, `naechstes`, `weiter()` und `zurueck()` bleiben dabei
/// unverändert, sie kennen den Medientyp gar nicht.
///
/// Enthält ein Album ausschließlich Videos, sagt ``nurVideos`` das — die
/// Ansicht zeigt dann einen Hinweis statt einer leeren schwarzen Fläche.
struct PhoneDiashowFolge: Equatable, Sendable {

    /// Die zu zeigenden Fotos in der Reihenfolge des Albums.
    let bilder: [PhoneAlbumGridEintrag]

    /// Wie viele Einträge der Ursprungsliste Videos waren. Nur für die
    /// Unterscheidung „leeres Album" ↔ „Album ohne ein einziges Foto".
    let uebersprungeneVideos: Int

    /// Position in ``bilder``, nicht in der Ursprungsliste.
    private(set) var position: Int

    init(eintraege: [PhoneAlbumGridEintrag]) {
        let fotos = eintraege.filter { !$0.isVideo }
        self.bilder = fotos
        self.uebersprungeneVideos = eintraege.count - fotos.count
        self.position = 0
    }

    var istLeer: Bool { bilder.isEmpty }

    /// Es gab Einträge, aber kein einziges Foto darunter.
    var nurVideos: Bool { bilder.isEmpty && uebersprungeneVideos > 0 }

    var aktuelles: PhoneAlbumGridEintrag? {
        bilder.indices.contains(position) ? bilder[position] : nil
    }

    /// Die Position nach ``weiter()`` — am Ende wieder 0. `nil` nur bei leerer
    /// Folge.
    var naechstePosition: Int? {
        guard !bilder.isEmpty else { return nil }
        return (position + 1) % bilder.count
    }

    /// Die Position nach ``zurueck()`` — vor dem ersten Bild das letzte.
    var vorherigePosition: Int? {
        guard !bilder.isEmpty else { return nil }
        return (position + bilder.count - 1) % bilder.count
    }

    /// Das Bild, das die Ansicht vorlädt, damit der Wechsel nicht schwarz
    /// aufblitzt. Bei einer einelementigen Folge ist das dasselbe wie
    /// ``aktuelles`` — dann ist ohnehin nichts vorzuladen.
    var naechstes: PhoneAlbumGridEintrag? {
        naechstePosition.map { bilder[$0] }
    }

    mutating func weiter() {
        guard let naechstePosition else { return }
        position = naechstePosition
    }

    mutating func zurueck() {
        guard let vorherigePosition else { return }
        position = vorherigePosition
    }
}
