import Foundation

/// Die Abschnitte des Albumrasters und der Smart-Alben-Reiter, aus Eingaben
/// gerechnet statt in der Ansicht gehalten.
///
/// Bis zu diesem Umbau steckte diese Auswahl in vier privaten Rechen-Eigenschaften
/// von `PhoneAlbumGridView` (`offlineAbschnittAlben`, `eigeneAlben`, `geteilteAlben`,
/// `gefilterteOfflineAlben`) und war damit unprüfbar — obwohl genau dort zwei
/// Feinheiten sitzen, die erst eine Prüfung fand: die Entdopplung gegen den
/// **ungefilterten** Offline-Abschnitt und die Frage, ob die Suche alle drei
/// Abschnitte trifft.
///
/// Bewusst ein reiner Wertetyp: kein SwiftUI, kein `ModelContext`, kein Netz. Die
/// Abzeichen kommen als fertige Abbildung herein (`PhoneOfflineModel.badges`), die
/// Verbindungslage als einfaches `istOffline`.
///
/// **Die vier Listen sind eine Zerlegung, keine Sichten:** Jedes hereingereichte
/// Album steht in höchstens einer von ihnen. Das ist die Eigenschaft, auf der
/// die Entdopplung beruht, und sie gilt auch über Bildschirmgrenzen hinweg
/// (`smart` speist einen eigenen Reiter) — siehe die Rangfolge in `berechnen`.
struct PhoneAlbumSections {

    /// Präfix, mit dem der Mac ein gespiegeltes Smart Album auf dem Server
    /// anlegt: `SmartAlbumMirrorService.enableMirror` ruft
    /// `createAlbum(name: "✦ \(album.name)")` (U+2726 WHITE FOUR POINTED STAR
    /// plus Leerzeichen).
    ///
    /// **Es gibt vom Telefon aus kein besseres Signal — such nicht danach.** Die
    /// `SmartAlbum`-Datensätze selbst sind ein reines Mac-Modell: Sie stehen
    /// weder in `Sources/ImmichPhone` noch im geteilten `PhoneModelContainer`,
    /// und die Server-API kennzeichnet ein gespiegeltes Album in keiner Weise —
    /// für sie ist es ein gewöhnliches Album, das zufällig so heißt. Der Name
    /// ist also das einzige Merkmal, das hier ankommt.
    static let spiegelPraefix = "✦ "

    /// "Auf dem Telefon" — gefiltert wie die anderen Abschnitte.
    let aufDemTelefon: [Album]
    /// Gespiegelte Smart Alben — ein eigener Abschnitt im Albumraster, direkt nach
    /// „Auf dem Telefon“ (bis September 2026 ein eigener Reiter).
    let smart: [Album]
    /// "Meine Alben", ohne die schon im Offline- oder Smart-Abschnitt stehenden.
    let eigene: [Album]
    /// "Geteilte Alben", ohne die schon im Offline- oder Smart-Abschnitt stehenden.
    let geteilte: [Album]

    /// Kein **im Albumraster gezeigter** Abschnitt enthält etwas. Die Ansicht
    /// macht daraus zusammen mit einem nichtleeren Suchtext den Leerzustand
    /// "Keine Alben gefunden" — von "der Server kennt keine Alben" bleibt das
    /// getrennt.
    ///
    /// `smart` zählt mit: Der Smart-Abschnitt steht im selben Raster. Sonst meldete
    /// eine Suche, die nur ein Smart Album trifft, „Keine Alben gefunden“ direkt
    /// unter dem gefundenen Album.
    var alleLeer: Bool {
        aufDemTelefon.isEmpty && smart.isEmpty && eigene.isEmpty && geteilte.isEmpty
    }

    /// Trägt das Album das Spiegel-Präfix? Bewusst am **genauen** Präfix samt
    /// Leerzeichen geprüft: Der Mac schreibt nie etwas anderes, und ein Album,
    /// das der Nutzer selbst "✦Wichtig" nennt, soll nicht in einem Reiter
    /// landen, in dem er es nie gesucht hätte.
    static func istGespiegeltesSmartAlbum(_ album: Album) -> Bool {
        album.albumName.hasPrefix(spiegelPraefix)
    }

    /// Der im Smart-Reiter gezeigte Name: ohne Präfix, weil der Reiter schon
    /// sagt, was diese Alben sind. Nicht-Smart-Alben gibt die Funktion
    /// unverändert zurück, ein Album, das nur aus dem Präfix besteht, ebenso —
    /// ein leerer Name wäre schlimmer als ein Präfix zu viel.
    /// Wonach die Reiter sortieren: nach dem **Inhalt** des Albums, neuestes
    /// zuerst — nicht danach, wann es in Immich angelegt wurde.
    ///
    /// Der Server liefert seine Liste nach `createdAt`, und danach richtete sich
    /// die App bisher. Bei dieser Mediathek heißt das wenig: 271 Alben tragen
    /// denselben Anlegetag (ein Massenimport), innerhalb dessen nur noch die
    /// Importreihenfolge entscheidet — für den Leser also gar keine Ordnung.
    /// Und `Japan 2023` stand ganz unten, weil es im Januar angelegt wurde,
    /// nicht weil die Fotos alt sind.
    ///
    /// Die Kette ist **dieselbe wie am Mac** (`AlbumsSidebarSection.sortDate`):
    /// `endDate → startDate → updatedAt → createdAt`. Erst die Zeitachse der
    /// Medien, dann die Verwaltungsdaten.
    ///
    /// Warum nicht nur `endDate`: Ein Album, dessen jüngstes Foto kein Datum
    /// trägt, hat womöglich trotzdem ein ältestes mit einem — dann ist
    /// `startDate` die bessere Auskunft als das Anlegedatum. `updatedAt` steht
    /// vor `createdAt`, weil ein gerade befülltes Album eher „neu" ist als
    /// eines, das seit dem Anlegen leer blieb.
    ///
    /// Alle vier kommen vom Server als UTC-ISO-8601 **fester Breite** (24
    /// Zeichen, dreistellige Millisekunden, festes `Z`) — nachgemessen über den
    /// ganzen Bestand. Bei fester Breite fallen lexikographische und
    /// chronologische Ordnung zusammen, deshalb genügt der Stringvergleich,
    /// ohne ein `Date` zu bauen. Der Mac parst, weil er zusätzlich die
    /// Jahreszahl für seine Überschriften braucht; hier reicht die Ordnung.
    static func sortierschluessel(fuer album: Album) -> String {
        for kandidat in [album.endDate, album.startDate, album.updatedAt, album.createdAt] {
            if let kandidat, !kandidat.isEmpty { return kandidat }
        }
        return ""
    }

    /// Sortiert absteigend nach ``sortierschluessel(fuer:)``, bei Gleichstand
    /// nach der Album-ID.
    ///
    /// **Hier und nur hier**, weil beide Wege durch diese Funktion laufen: Der
    /// Server liefert unsortiert (`AlbumManager` reicht seine Reihenfolge
    /// durch), der Cache sortiert nach `createdAt`. Genau diese Asymmetrie ließ
    /// die Liste früher beim Offline-Gehen umspringen. Eine Sortierung an
    /// dieser Stelle vereinheitlicht beide, ohne `AlbumManager` — und damit den
    /// Mac-Client — anzufassen.
    ///
    /// Der Gleichstands-Vergleich ist kein Zierrat: `sorted(by:)` ist in Swift
    /// nicht stabil. Ohne ihn könnten zwei Alben mit demselben Datum bei jedem
    /// Neuzeichnen die Plätze tauschen.
    static func nachInhalt(_ alben: [Album]) -> [Album] {
        alben.sorted { links, rechts in
            let a = sortierschluessel(fuer: links)
            let b = sortierschluessel(fuer: rechts)
            if a != b { return a > b }
            return links.id < rechts.id
        }
    }

    static func anzeigename(fuer album: Album) -> String {
        guard istGespiegeltesSmartAlbum(album) else { return album.albumName }
        let gekuerzt = String(album.albumName.dropFirst(spiegelPraefix.count))
        return gekuerzt.isEmpty ? album.albumName : gekuerzt
    }

    /// - Parameters:
    ///   - eigene: `AlbumManager.albums`, in Eingabereihenfolge.
    ///   - geteilte: `AlbumManager.sharedAlbums`, in Eingabereihenfolge.
    ///   - abzeichen: `albumId → OfflineBadge`; fehlt eine ID, gilt `.cloud`.
    ///   - suchtext: leer heißt "nicht filtern".
    ///   - istOffline: `connection.state.isOffline`.
    static func berechnen(
        eigene: [Album],
        geteilte: [Album],
        abzeichen: [String: OfflineBadge],
        suchtext: String,
        istOffline: Bool
    ) -> PhoneAlbumSections {

        // **Eine** Regel für alle Abschnitte: Die Suche arbeitet auf dem Namen,
        // der auf dem Bildschirm steht. Seit die Kachel überall über
        // `anzeigename` geht, ist das der gekürzte — sonst fände eine Eingabe
        // von "✦" Alben, bei denen dieses Zeichen nirgends zu sehen ist. Für
        // Nicht-Smart-Alben gibt `anzeigename` den Namen unverändert zurück,
        // für sie ändert sich also nichts.
        let eigene = nachInhalt(eigene)
        let geteilte = nachInhalt(geteilte)

        func passtZurSuche(_ album: Album) -> Bool {
            suchtext.isEmpty || anzeigename(fuer: album).localizedStandardContains(suchtext)
        }

        // Alben mit einem Abzeichen ungleich `.cloud`, aber nur wenn die Verbindung
        // offline ist — online ist die Unterscheidung Zierde, nicht Zweck. Bewusst
        // nicht auf `badge == .offline` geprüft: `OfflineBadge.from` lässt `.failed`
        // über `.offline` gewinnen, und ein noch laufender Download steht auf
        // `.pending` — ein vollständig geladenes Album mit gesetztem `lastError` oder
        // ein gerade ladendes fiele damit aus diesem Abschnitt, obwohl beide hierher
        // (dorthin, nicht in die Cloud) gehören. Bewusst über beide Gruppen hinweg
        // gebildet: Ein geteiltes Album kann ebenso gepinnt sein wie ein eigenes.
        let offlineAlben: [Album] = istOffline
            ? (eigene + geteilte).filter { (abzeichen[$0.id] ?? .cloud) != .cloud }
            : []

        // Die Entdopplung greift gegen den **ungefilterten** Offline-Abschnitt: Ein
        // gepinntes Album, das nicht zum Suchtext passt, verschwindet dadurch ganz,
        // statt in "Meine Alben" wieder aufzutauchen.
        let offlineIds = Set(offlineAlben.map(\.id))

        // **Rangfolge bei der Kollision "Smart Album ist offline gepinnt":
        // „Auf dem Telefon" gewinnt.** Der Abschnitt erscheint überhaupt nur
        // ohne Netz, und dann ist er die vollständige Liste dessen, was gerade
        // noch geht — fehlte dort ausgerechnet das gepinnte Album, behauptete
        // der erste Abschnitt des ersten Reiters etwas Falsches über den
        // Gerätezustand, in der Lage, in der diese Auskunft am meisten zählt.
        // Der Preis ist bekannt und bewusst in Kauf genommen: Solange die
        // Verbindung offline ist, fehlt genau dieses Album im Smart-Reiter. Es
        // bleibt aber sichtbar und öffenbar — unter "Auf dem Telefon", mit dem
        // ✦ im Namen, das es dort als Smart Album ausweist. Online kehrt es von
        // selbst in den Smart-Reiter zurück, weil `offlineAlben` dann leer ist.
        let smartAlben = (eigene + geteilte).filter {
            !offlineIds.contains($0.id) && istGespiegeltesSmartAlbum($0)
        }
        // Wie oben gegen die **ungefilterte** Liste: Ein Smart Album, das nicht
        // zum Suchtext passt, soll nicht ersatzweise in "Meine Alben" auftauchen.
        let ausgelagerteIds = offlineIds.union(smartAlben.map(\.id))

        return PhoneAlbumSections(
            aufDemTelefon: offlineAlben.filter(passtZurSuche),
            smart: smartAlben.filter(passtZurSuche),
            eigene: eigene.filter { !ausgelagerteIds.contains($0.id) && passtZurSuche($0) },
            geteilte: geteilte.filter { !ausgelagerteIds.contains($0.id) && passtZurSuche($0) }
        )
    }
}
