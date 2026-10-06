import Foundation
import Testing
@testable import ImmichPhone

// Prüft die Auswahllogik des Albumrasters, die bis zu diesem Umbau in vier
// privaten Rechen-Eigenschaften von `PhoneAlbumGridView` steckte und damit
// unerreichbar war. `PhoneAlbumSections` ist ein reiner Wertetyp: kein SwiftUI,
// kein `ModelContext`, kein Netz — deshalb genügt hier ein Album-Literal und
// eine Abbildung `albumId → OfflineBadge`.

private func album(
    _ id: String,
    _ name: String,
    angelegt: String = "2026-01-01T00:00:00.000Z",
    geaendert: String? = nil,
    inhaltAb: String? = nil,
    inhaltBis: String? = nil
) -> Album {
    Album(
        id: id, albumName: name, description: nil,
        createdAt: angelegt, updatedAt: geaendert ?? angelegt,
        startDate: inhaltAb, endDate: inhaltBis, assetCount: 0, albumThumbnailAssetId: nil,
        shared: nil, hasSharedLink: nil, owner: nil
    )
}

@Suite("PhoneAlbumSections")
struct PhoneAlbumSectionsTests {

    private let eigene = [album("e-1", "Urlaub"), album("e-2", "Claras Geburtstag"), album("e-3", "Garten")]
    private let geteilt = [album("g-1", "Clara und Ben"), album("g-2", "Familientreffen")]

    @Test("Online bleibt der Offline-Abschnitt leer, auch bei gepinnten Alben")
    func onlineOhneOfflineAbschnitt() {
        let abschnitte = PhoneAlbumSections.berechnen(
            eigene: eigene, geteilte: geteilt,
            abzeichen: ["e-1": .offline, "g-1": .pending],
            suchtext: "", istOffline: false
        )

        #expect(abschnitte.aufDemTelefon.isEmpty)
        // Und die gepinnten Alben bleiben dort, wo sie online hingehören.
        #expect(abschnitte.eigene.map(\.id) == ["e-1", "e-2", "e-3"])
        #expect(abschnitte.geteilte.map(\.id) == ["g-1", "g-2"])
    }

    @Test("Offline enthält der Abschnitt genau die Alben mit Abzeichen ungleich .cloud, aus beiden Gruppen")
    func offlineSammeltAusBeidenGruppen() {
        let abschnitte = PhoneAlbumSections.berechnen(
            eigene: eigene, geteilte: geteilt,
            // Alle drei Nicht-Cloud-Zustände zählen, nicht nur `.offline`.
            abzeichen: ["e-1": .offline, "e-3": .failed, "g-1": .pending, "g-2": .cloud],
            suchtext: "", istOffline: true
        )

        #expect(abschnitte.aufDemTelefon.map(\.id) == ["e-1", "e-3", "g-1"])
    }

    @Test("Ein Album im Offline-Abschnitt erscheint nicht zusätzlich in eigene oder geteilte")
    func keineDopplung() {
        let abschnitte = PhoneAlbumSections.berechnen(
            eigene: eigene, geteilte: geteilt,
            abzeichen: ["e-1": .offline, "g-1": .pending],
            suchtext: "", istOffline: true
        )

        #expect(abschnitte.aufDemTelefon.map(\.id) == ["e-1", "g-1"])
        #expect(abschnitte.eigene.map(\.id) == ["e-2", "e-3"])
        #expect(abschnitte.geteilte.map(\.id) == ["g-2"])
    }

    @Test("Die Suche filtert alle drei Abschnitte")
    func sucheTrifftAlleAbschnitte() {
        let abschnitte = PhoneAlbumSections.berechnen(
            eigene: eigene + [album("e-4", "Clara im Schnee")],
            geteilte: geteilt,
            abzeichen: ["e-1": .offline],
            suchtext: "clara", istOffline: true
        )

        // "e-1"/"Urlaub" ist gepinnt, passt aber nicht — der Offline-Abschnitt ist
        // ebenso gefiltert wie die beiden anderen.
        #expect(abschnitte.aufDemTelefon.isEmpty)
        #expect(abschnitte.eigene.map(\.id) == ["e-2", "e-4"])
        #expect(abschnitte.geteilte.map(\.id) == ["g-1"])
    }

    @Test("Ein gepinntes Album ohne Suchtreffer verschwindet ganz, statt nach unten zu rutschen")
    func gepinntesAlbumOhneTrefferVerschwindet() {
        let abschnitte = PhoneAlbumSections.berechnen(
            eigene: eigene, geteilte: geteilt,
            abzeichen: ["e-1": .offline],
            suchtext: "Garten", istOffline: true
        )

        #expect(abschnitte.aufDemTelefon.isEmpty)
        // Entscheidend: "e-1" taucht auch nicht in `eigene` wieder auf — die
        // Entdopplung greift gegen den ungefilterten Offline-Abschnitt.
        #expect(abschnitte.eigene.map(\.id) == ["e-3"])
        #expect(abschnitte.geteilte.isEmpty)
    }

    /// **Ersetzt einen Test, der die Eingabereihenfolge festhielt.** Bis hierher
    /// reichte die Berechnung die Serverreihenfolge durch (nach Anlegedatum);
    /// jetzt sortiert sie nach dem Inhalt. Der alte Test war nicht falsch, er
    /// beschrieb nur ein Verhalten, das es nicht mehr gibt.
    @Test("Sortiert wird nach dem Inhalt, neuestes zuerst")
    func sortiertNachInhalt() {
        let unsortiert = [
            album("e-9", "Zypern", inhaltBis: "2019-06-01T00:00:00.000Z"),
            album("e-8", "Alpen",  inhaltBis: "2024-08-01T00:00:00.000Z"),
            album("e-7", "Mühle",  inhaltBis: "2021-03-01T00:00:00.000Z")
        ]
        let geteilt = [
            album("g-9", "Zoo",      inhaltBis: "2015-01-01T00:00:00.000Z"),
            album("g-8", "Aquarium", inhaltBis: "2023-01-01T00:00:00.000Z")
        ]

        let abschnitte = PhoneAlbumSections.berechnen(
            eigene: unsortiert, geteilte: geteilt,
            abzeichen: ["e-7": .offline, "g-9": .offline],
            suchtext: "", istOffline: true
        )

        // Alpen (2024) vor Zypern (2019) — die Eingabereihenfolge war umgekehrt.
        #expect(abschnitte.eigene.map(\.id) == ["e-8", "e-9"])
        #expect(abschnitte.geteilte.map(\.id) == ["g-8"])
        // Auch der zusammengesetzte Offline-Abschnitt folgt dem Inhalt: die
        // Mühle (2021) steht vor dem Zoo (2015), obwohl "eigene" zuerst kommen.
        #expect(abschnitte.aufDemTelefon.map(\.id) == ["e-7", "g-9"])
    }

    /// Die Kette `endDate → startDate → updatedAt → createdAt`, dieselbe wie am
    /// Mac (`AlbumsSidebarSection.sortDate`). Jede Stufe wird einzeln
    /// festgenagelt: Fällt eine weg, greift der Test.
    @Test("Die Datumskette folgt erst den Medien, dann der Verwaltung")
    func datumskette() {
        let nurEnde = album("e", "E", inhaltBis: "2020-01-01T00:00:00.000Z")
        #expect(PhoneAlbumSections.sortierschluessel(fuer: nurEnde) == "2020-01-01T00:00:00.000Z")

        // Kein Enddatum, aber ein Anfangsdatum: das zählt, nicht die Verwaltung.
        let nurAnfang = album("a", "A", angelegt: "2026-01-01T00:00:00.000Z",
                              inhaltAb: "2015-05-05T00:00:00.000Z")
        #expect(PhoneAlbumSections.sortierschluessel(fuer: nurAnfang) == "2015-05-05T00:00:00.000Z")

        // Gar keine Mediendaten: `updatedAt` vor `createdAt` — ein gerade
        // befülltes Album ist eher „neu" als eines, das seit dem Anlegen leer blieb.
        let nurVerwaltung = album("v", "V", angelegt: "2026-01-01T00:00:00.000Z",
                                  geaendert: "2026-08-17T00:00:00.000Z")
        #expect(PhoneAlbumSections.sortierschluessel(fuer: nurVerwaltung) == "2026-08-17T00:00:00.000Z")

        // Endedatum schlägt alles andere, auch ein jüngeres `updatedAt`.
        let alles = album("x", "X", angelegt: "2026-01-01T00:00:00.000Z",
                          geaendert: "2026-09-01T00:00:00.000Z",
                          inhaltAb: "2011-01-01T00:00:00.000Z",
                          inhaltBis: "2012-01-01T00:00:00.000Z")
        #expect(PhoneAlbumSections.sortierschluessel(fuer: alles) == "2012-01-01T00:00:00.000Z")
    }

    /// Ein Album ohne jedes Mediendatum verschwindet nicht und rutscht nicht
    /// ans Ende. Erreicht wird das bei einem frisch gespiegelten Smart Album,
    /// das noch keine Fotos hat — bei dieser Mediathek genau `✦ GIFs`.
    @Test("Ohne Mediendaten wird trotzdem einsortiert")
    func ohneMediendatenTrotzdemEinsortiert() {
        let alben = [
            album("alt",  "Alt",  inhaltBis: "2010-01-01T00:00:00.000Z"),
            album("leer", "Leer", angelegt: "2026-09-06T00:00:00.000Z"),
            album("mitte", "Mitte", inhaltBis: "2020-01-01T00:00:00.000Z")
        ]
        #expect(PhoneAlbumSections.nachInhalt(alben).map(\.id) == ["leer", "mitte", "alt"])
    }

    /// `sorted(by:)` ist in Swift **nicht stabil**: Ohne den Gleichstands-
    /// Vergleich könnten zwei Alben mit demselben Datum bei jedem Neuzeichnen
    /// die Plätze tauschen. Genau der Fall tritt hier ein — 271 Alben dieser
    /// Mediathek tragen denselben Anlegetag.
    @Test("Bei gleichem Datum entscheidet die ID, nicht der Zufall")
    func gleichstandIstStabil() {
        let gleich = "2026-06-12T10:00:00.000Z"
        let vorwaerts = [album("c", "C", inhaltBis: gleich),
                         album("a", "A", inhaltBis: gleich),
                         album("b", "B", inhaltBis: gleich)]
        let rueckwaerts = Array(vorwaerts.reversed())

        #expect(PhoneAlbumSections.nachInhalt(vorwaerts).map(\.id) == ["a", "b", "c"])
        #expect(PhoneAlbumSections.nachInhalt(rueckwaerts).map(\.id) == ["a", "b", "c"])
    }

    @Test("Leerer Suchtext filtert nichts weg")
    func leererSuchtextFiltertNicht() {
        let abschnitte = PhoneAlbumSections.berechnen(
            eigene: eigene, geteilte: geteilt,
            abzeichen: [:], suchtext: "", istOffline: true
        )

        #expect(abschnitte.aufDemTelefon.isEmpty)
        #expect(abschnitte.eigene.map(\.id) == ["e-1", "e-2", "e-3"])
        #expect(abschnitte.geteilte.map(\.id) == ["g-1", "g-2"])
    }

    @Test("Die Suche ist unabhängig von Groß-/Kleinschreibung und Diakritika")
    func sucheIstLocalizedStandard() {
        let abschnitte = PhoneAlbumSections.berechnen(
            eigene: [album("e-1", "MÜHLE am Fluß")], geteilte: [],
            abzeichen: [:], suchtext: "muhle", istOffline: false
        )

        #expect(abschnitte.eigene.map(\.id) == ["e-1"])
    }

    @Test("alleLeer meldet nur, wenn keiner der drei Abschnitte etwas enthält")
    func alleLeerMeldetDenLeerzustand() {
        let mitTreffer = PhoneAlbumSections.berechnen(
            eigene: eigene, geteilte: geteilt,
            abzeichen: [:], suchtext: "Garten", istOffline: false
        )
        #expect(!mitTreffer.alleLeer)

        let ohneTreffer = PhoneAlbumSections.berechnen(
            eigene: eigene, geteilte: geteilt,
            abzeichen: ["e-1": .offline], suchtext: "gibtesnicht", istOffline: true
        )
        #expect(ohneTreffer.alleLeer)
    }
}

// MARK: - Gespiegelte Smart Alben
//
// Der Mac legt für ein gespiegeltes Smart Album ein Serveralbum namens
// `"✦ \(name)"` an (`SmartAlbumMirrorService.enableMirror`). Vom Telefon aus ist
// dieses Präfix das einzige Erkennungsmerkmal — die `SmartAlbum`-Datensätze
// selbst liegen nur auf dem Mac. Deshalb prüfen diese Tests ausschließlich über
// den Namen.

@Suite("PhoneAlbumSections – Smart Alben")
struct PhoneAlbumSectionsSmartTests {

    private let eigene = [
        album("e-1", "Urlaub"),
        album("e-2", "✦ Leica Favs"),
        album("e-3", "Garten"),
        album("e-4", "✦ GIFs")
    ]
    private let geteilt = [album("g-1", "Familientreffen"), album("g-2", "✦ Emma und Ben")]

    @Test("Alben mit ✦-Präfix landen im Smart-Abschnitt, aus beiden Gruppen")
    func smartSammeltAusBeidenGruppen() {
        let abschnitte = PhoneAlbumSections.berechnen(
            eigene: eigene, geteilte: geteilt,
            abzeichen: [:], suchtext: "", istOffline: false
        )

        #expect(abschnitte.smart.map(\.id) == ["e-2", "e-4", "g-2"])
    }

    @Test("Ein Smart Album steht nicht zusätzlich in eigene oder geteilte")
    func smartWirdAusDenAnderenAbschnittenEntfernt() {
        let abschnitte = PhoneAlbumSections.berechnen(
            eigene: eigene, geteilte: geteilt,
            abzeichen: [:], suchtext: "", istOffline: false
        )

        #expect(abschnitte.eigene.map(\.id) == ["e-1", "e-3"])
        #expect(abschnitte.geteilte.map(\.id) == ["g-1"])
    }

    @Test("Nur das genaue Präfix ✦ + Leerzeichen zählt")
    func nurDasGenauePraefixZaehlt() {
        let abschnitte = PhoneAlbumSections.berechnen(
            // "✦GIFs" ohne Leerzeichen und "Leica ✦ Favs" mit dem Zeichen in der
            // Mitte legt der Mac nie an — beide bleiben normale Alben.
            eigene: [album("e-1", "✦GIFs"), album("e-2", "Leica ✦ Favs")],
            geteilte: [],
            abzeichen: [:], suchtext: "", istOffline: false
        )

        #expect(abschnitte.smart.isEmpty)
        #expect(abschnitte.eigene.map(\.id) == ["e-1", "e-2"])
    }

    @Test("Offline gewinnt „Auf dem Telefon\" gegen den Smart-Abschnitt")
    func gepinntesSmartAlbumStehtAufDemTelefon() {
        let abschnitte = PhoneAlbumSections.berechnen(
            eigene: eigene, geteilte: geteilt,
            abzeichen: ["e-2": .offline], suchtext: "", istOffline: true
        )

        // Bewusste Entscheidung, siehe Kommentar in `PhoneAlbumSections`: Der
        // Offline-Abschnitt erscheint nur ohne Netz und muss dann vollständig
        // sein — er ist die Liste dessen, was überhaupt noch geht.
        #expect(abschnitte.aufDemTelefon.map(\.id) == ["e-2"])
        #expect(abschnitte.smart.map(\.id) == ["e-4", "g-2"])
        #expect(abschnitte.eigene.map(\.id) == ["e-1", "e-3"])
    }

    @Test("Online bleibt ein gepinntes Smart Album im Smart-Abschnitt")
    func onlineBleibtDasGepinnteSmartAlbumSmart() {
        let abschnitte = PhoneAlbumSections.berechnen(
            eigene: eigene, geteilte: geteilt,
            abzeichen: ["e-2": .offline], suchtext: "", istOffline: false
        )

        #expect(abschnitte.aufDemTelefon.isEmpty)
        #expect(abschnitte.smart.map(\.id) == ["e-2", "e-4", "g-2"])
    }

    @Test("Die Suche im Smart-Abschnitt arbeitet auf dem angezeigten Namen")
    func sucheArbeitetAufDemAngezeigtenNamen() {
        let abschnitte = PhoneAlbumSections.berechnen(
            eigene: eigene, geteilte: geteilt,
            abzeichen: [:], suchtext: "leica", istOffline: false
        )
        #expect(abschnitte.smart.map(\.id) == ["e-2"])

        // Der Reiter zeigt die Namen ohne Präfix — eine Suche nach "✦" kann
        // deshalb nichts treffen, sonst suchte der Nutzer nach etwas, das
        // nirgends auf dem Bildschirm steht.
        let nachPraefix = PhoneAlbumSections.berechnen(
            eigene: eigene, geteilte: geteilt,
            abzeichen: [:], suchtext: "✦", istOffline: false
        )
        #expect(nachPraefix.smart.isEmpty)

        // **Und sie tauchen auch nirgendwo sonst wieder auf.** Das ist die
        // eigentliche Zusicherung dieses Falls: Die Entdopplung greift gegen die
        // **ungefilterte** Smart-Liste. Liefe sie gegen die gefilterte, wären
        // hier — wo der Suchtext auf den gekürzten Namen nicht passt — plötzlich
        // alle vier Smart Alben zurück unter „Meine Alben" und „Geteilte Alben".
        //
        // Beim Offline-Abschnitt sind beide Varianten gleichwertig, weil dort
        // dasselbe Prädikat filtert; erst hier, wo gekürzt und roh
        // auseinandergehen, hat die Unterscheidung Zähne. Ohne diese zwei Zeilen
        // überlebt genau diese Fehlimplementierung alle Tests.
        #expect(nachPraefix.eigene.isEmpty)
        #expect(nachPraefix.geteilte.isEmpty)
    }

    @Test("alleLeer zählt den Smart-Abschnitt mit")
    func alleLeerZaehltSmart() {
        // Seit September 2026 steht der Smart-Abschnitt im Albumraster. Träfe die
        // Suche nur ein Smart Album und zählte `smart` nicht mit, meldete das Raster
        // "Keine Alben gefunden" direkt unter dem gefundenen Album.
        let nurSmartTrifft = PhoneAlbumSections.berechnen(
            eigene: eigene, geteilte: geteilt,
            abzeichen: [:], suchtext: "Leica", istOffline: false
        )

        #expect(nurSmartTrifft.smart.map(\.id) == ["e-2"])
        #expect(!nurSmartTrifft.alleLeer)
    }

    @Test("anzeigename schneidet das Präfix ab und lässt andere Namen unberührt")
    func anzeigenameSchneidetDasPraefixAb() {
        #expect(PhoneAlbumSections.anzeigename(fuer: album("a", "✦ Leica Favs")) == "Leica Favs")
        #expect(PhoneAlbumSections.anzeigename(fuer: album("a", "Garten")) == "Garten")
        // Ein Album, das nur aus dem Präfix besteht, behielte sonst einen leeren
        // Namen — dann lieber den rohen zeigen als eine namenlose Kachel.
        #expect(PhoneAlbumSections.anzeigename(fuer: album("a", "✦ ")) == "✦ ")
    }

    /// Der Abschnitt „Auf dem Telefon" zeigt seine Kacheln seit der
    /// Vereinheitlichung ebenfalls ohne `✦` — also muss die Suche auch dort auf
    /// dem gekürzten Namen arbeiten. Das ist der einzige Ort, an dem ein
    /// gespiegeltes Smart Album ausserhalb des Smart-Reiters erscheint.
    @Test("Die Suche im Offline-Abschnitt arbeitet auf dem angezeigten Namen")
    func offlineSucheArbeitetAufDemAngezeigtenNamen() {
        let gepinnt: [String: OfflineBadge] = ["e-2": .offline]

        // Nach dem gekürzten Namen gesucht: gefunden.
        let treffer = PhoneAlbumSections.berechnen(
            eigene: eigene, geteilte: geteilt,
            abzeichen: gepinnt, suchtext: "leica", istOffline: true
        )
        #expect(treffer.aufDemTelefon.map(\.id) == ["e-2"])
        // Und es steht nicht zusätzlich im Smart-Abschnitt.
        #expect(treffer.smart.isEmpty)

        // Nach dem Präfix gesucht: nichts, denn es steht nirgends auf dem Schirm.
        let nachPraefix = PhoneAlbumSections.berechnen(
            eigene: eigene, geteilte: geteilt,
            abzeichen: gepinnt, suchtext: "✦", istOffline: true
        )
        #expect(nachPraefix.aufDemTelefon.isEmpty)
    }

}
