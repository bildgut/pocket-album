import Foundation
import Testing
@testable import ImmichPhone

// Prüft `PhoneDiashowFolge` — die gesamte Logik der Diashow: welcher Index als
// Nächstes kommt, dass Videos ausgelassen werden, und dass es am Ende wieder
// von vorn losgeht.
//
// **Warum das hier geprüft werden kann und die Ansicht nicht:**
// `PhoneDiashowView` ist Vollbild, schwarz, mit Timer und Nuke-Pipeline — an
// ihr selbst ist nichts zu messen. Die Fortschaltung dagegen ist eine reine
// Funktion über die Eintragsliste, ohne Umgebung. Derselbe Schnitt wie bei
// `PhoneMediaSource`.
@Suite("PhoneDiashowFolge")
struct PhoneDiashowFolgeTests {

    private func foto(_ id: String) -> PhoneAlbumGridEintrag {
        PhoneAlbumGridEintrag(id: id)
    }

    private func video(_ id: String) -> PhoneAlbumGridEintrag {
        PhoneAlbumGridEintrag(id: id, isVideo: true, duration: "00:03:12.000")
    }

    @Test("Beginnt beim ersten Foto")
    func startBeimErsten() {
        let folge = PhoneDiashowFolge(eintraege: [foto("a"), foto("b"), foto("c")])
        #expect(folge.position == 0)
        #expect(folge.aktuelles?.id == "a")
        #expect(folge.istLeer == false)
    }

    @Test("Schaltet der Reihe nach weiter")
    func schaltetWeiter() {
        var folge = PhoneDiashowFolge(eintraege: [foto("a"), foto("b"), foto("c")])
        folge.weiter()
        #expect(folge.aktuelles?.id == "b")
        folge.weiter()
        #expect(folge.aktuelles?.id == "c")
    }

    @Test("Am Ende geht es wieder von vorn los")
    func umbruchAmEnde() {
        var folge = PhoneDiashowFolge(eintraege: [foto("a"), foto("b")])
        folge.weiter()
        #expect(folge.aktuelles?.id == "b")
        folge.weiter()
        #expect(folge.aktuelles?.id == "a")
        #expect(folge.position == 0)
    }

    @Test("Zurück vor dem ersten Bild landet beim letzten")
    func umbruchAmAnfang() {
        var folge = PhoneDiashowFolge(eintraege: [foto("a"), foto("b"), foto("c")])
        folge.zurueck()
        #expect(folge.aktuelles?.id == "c")
        folge.zurueck()
        #expect(folge.aktuelles?.id == "b")
    }

    @Test("Videos kommen in der Folge nicht vor")
    func videosAusgelassen() {
        let folge = PhoneDiashowFolge(
            eintraege: [foto("a"), video("v1"), foto("b"), video("v2"), foto("c")]
        )
        #expect(folge.bilder.map(\.id) == ["a", "b", "c"])
        #expect(folge.uebersprungeneVideos == 2)
        #expect(folge.nurVideos == false)
    }

    @Test("Ein Video zwischen zwei Fotos wird übersprungen, nicht gezeigt")
    func springtUeberVideoHinweg() {
        var folge = PhoneDiashowFolge(eintraege: [foto("a"), video("v"), foto("b")])
        #expect(folge.aktuelles?.id == "a")
        folge.weiter()
        #expect(folge.aktuelles?.id == "b")
    }

    @Test("Ein Video am Anfang verschiebt den Start auf das erste Foto")
    func videoAmAnfang() {
        let folge = PhoneDiashowFolge(eintraege: [video("v"), foto("a")])
        #expect(folge.aktuelles?.id == "a")
    }

    @Test("Nur Videos ist ein eigener Zustand, nicht einfach leer")
    func nurVideos() {
        let folge = PhoneDiashowFolge(eintraege: [video("v1"), video("v2")])
        #expect(folge.istLeer)
        #expect(folge.nurVideos)
        #expect(folge.aktuelles == nil)
        #expect(folge.naechstes == nil)
    }

    @Test("Ein leeres Album ist leer, aber nicht „nur Videos“")
    func leeresAlbum() {
        var folge = PhoneDiashowFolge(eintraege: [])
        #expect(folge.istLeer)
        #expect(folge.nurVideos == false)
        #expect(folge.naechstePosition == nil)
        #expect(folge.vorherigePosition == nil)
        // Fortschalten auf einer leeren Folge darf nicht abstürzen und nichts
        // verändern — der Automatik-Takt der Ansicht läuft weiter, auch wenn
        // nichts zu zeigen ist.
        folge.weiter()
        folge.zurueck()
        #expect(folge.position == 0)
    }

    @Test("Bei einem einzigen Foto bleibt die Folge darauf stehen")
    func einzelnesFoto() {
        var folge = PhoneDiashowFolge(eintraege: [foto("a"), video("v")])
        #expect(folge.naechstes?.id == "a")
        folge.weiter()
        #expect(folge.aktuelles?.id == "a")
        folge.zurueck()
        #expect(folge.aktuelles?.id == "a")
    }

    @Test("Das vorzuladende Bild ist das, das als Nächstes gezeigt wird")
    func vorladenPasstZurFortschaltung() {
        var folge = PhoneDiashowFolge(eintraege: [foto("a"), foto("b"), foto("c")])
        for _ in 0..<5 {
            let angekuendigt = folge.naechstes?.id
            folge.weiter()
            #expect(folge.aktuelles?.id == angekuendigt)
        }
    }
}
