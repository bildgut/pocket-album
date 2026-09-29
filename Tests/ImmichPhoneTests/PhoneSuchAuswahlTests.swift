import Foundation
import Testing
@testable import ImmichPhone

// Der Kern des Orte-Reiters: Hier entsteht der Filter für Raster, Zählabfragen
// und Personendurchlauf. Zwei Dinge daran sind lautlos gefährlich — ein
// `visibility`, das `locked` treffen könnte (401), und eine Gleichheit, die bei
// derselben Auswahl „ungleich" sagt (unnötiges Neuladen) oder bei einer anderen
// „gleich" (Cursor wird weiterverwendet, Treffer fehlen).

@Suite("PhoneSuchAuswahl")
struct PhoneSuchAuswahlTests {

    @Test("Leere Auswahl ist exakt der Filter des Fotos-Reiters")
    func leer() {
        #expect(PhoneSuchAuswahl.leer.istLeer)
        #expect(PhoneSuchAuswahl.leer.searchFilter() == .visibleLibrary(type: nil))
        #expect(PhoneSuchAuswahl.leer.searchFilter(type: .video) == .visibleLibrary(type: .video))
    }

    @Test("Land setzt country und behält visibility und trashedAt")
    func land() {
        let filter = PhoneSuchAuswahl.land("Japan").searchFilter()
        #expect(filter.country == .equals("Japan"))
        #expect(filter.city == nil)
        #expect(filter.state == nil)
        #expect(filter.visibility == .oneOf([.timeline]))
        #expect(filter.trashedAt == .isNull)
    }

    @Test("Stadt setzt city, Region setzt state — nie beides verwechselt")
    func stadtUndRegion() {
        let stadt = PhoneSuchAuswahl.stadt("Tokyo", in: "Japan").searchFilter()
        #expect(stadt.country == .equals("Japan"))
        #expect(stadt.city == .equals("Tokyo"))
        #expect(stadt.state == nil)

        let region = PhoneSuchAuswahl.region("Kanagawa", in: "Japan").searchFilter()
        #expect(region.state == .equals("Kanagawa"))
        #expect(region.city == nil)
    }

    @Test("Ein Jahr wird zum halboffenen UTC-Fenster")
    func jahr() {
        let filter = PhoneSuchAuswahl.land("Japan").mitJahr(2019).searchFilter()
        #expect(filter.takenAt?.gte == "2019-01-01T00:00:00.000Z")
        #expect(filter.takenAt?.lt == "2020-01-01T00:00:00.000Z")
        #expect(filter.takenAt?.lte == nil)
    }

    @Test("Zwei Personen sind UND-verknüpft, nie ODER")
    func zweiPersonen() {
        let filter = PhoneSuchAuswahl.land("Japan").mitPerson("b").mitPerson("a").searchFilter()
        #expect(filter.personIds == .allOf(["a", "b"]))
        #expect(filter.personIds?.any == nil)
    }

    @Test("Ohne Personen gibt es keine personIds-Bedingung")
    func keinePersonen() {
        #expect(PhoneSuchAuswahl.land("Japan").searchFilter().personIds == nil)
    }

    @Test("Die Reihenfolge der Personenwahl ändert die Auswahl nicht")
    func personenReihenfolge() {
        let ab = PhoneSuchAuswahl.land("Japan").mitPerson("a").mitPerson("b")
        let ba = PhoneSuchAuswahl.land("Japan").mitPerson("b").mitPerson("a")
        #expect(ab == ba)
    }

    @Test("Ein anderes Jahr ist eine andere Auswahl — daran hängt der Cursor-Reset")
    func anderesJahrUngleich() {
        let basis = PhoneSuchAuswahl.land("Japan")
        #expect(basis.mitJahr(2019) != basis.mitJahr(2023))
        #expect(basis.mitJahr(2019) != basis)
    }

    @Test("Chips schalten um: zweimal dieselbe Stadt, dasselbe Jahr, dieselbe Person heben auf")
    func umschalten() {
        let basis = PhoneSuchAuswahl.land("Japan")
        #expect(basis.mitStadt("Tokyo").mitStadt("Tokyo") == basis)
        #expect(basis.mitJahr(2019).mitJahr(2019) == basis)
        #expect(basis.mitPerson("a").mitPerson("a") == basis)
        #expect(basis.mitStadt("Tokyo").mitStadt("Kyoto").stadt == "Kyoto")
        #expect(basis.mitJahr(2019).mitJahr(2023).jahr == 2023)
    }

    @Test("Eine Stadt verdrängt die Region")
    func stadtVerdraengtRegion() {
        let auswahl = PhoneSuchAuswahl.region("Kanagawa", in: "Japan").mitStadt("Yokohama")
        #expect(auswahl.stadt == "Yokohama")
        #expect(auswahl.region == nil)
    }

    @Test("ohneStadt behält die Region, ohneStadtUndRegion nicht")
    func entfernen() {
        let region = PhoneSuchAuswahl.region("Kanagawa", in: "Japan")
        #expect(region.ohneStadt().region == "Kanagawa")
        #expect(region.ohneStadtUndRegion() == .land("Japan"))
        #expect(PhoneSuchAuswahl.land("Japan").mitJahr(2019).ohneJahr() == .land("Japan"))
    }

    @Test("istNurLand nur ohne jede weitere Einschränkung")
    func nurLand() {
        #expect(PhoneSuchAuswahl.land("Japan").istNurLand)
        #expect(!PhoneSuchAuswahl.leer.istNurLand)
        #expect(!PhoneSuchAuswahl.land("Japan").mitJahr(2019).istNurLand)
        #expect(!PhoneSuchAuswahl.region("Kanagawa", in: "Japan").istNurLand)
        #expect(!PhoneSuchAuswahl.land("Japan").mitPerson("a").istNurLand)
    }
}

@Suite("PhoneSuchAuswahl ohne Pflicht-Land")
struct PhoneSuchAuswahlOhneLandTests {
    @Test("Nur eine Person ist eine gültige Auswahl")
    func nurPerson() {
        let a = PhoneSuchAuswahl.person("p1")
        #expect(!a.istLeer)
        var erwartet = SearchFilter.visibleLibrary(type: nil)
        erwartet.personIds = .allOf(["p1"])
        #expect(a.searchFilter() == erwartet)
    }

    @Test("Jahr und Person ohne Land")
    func jahrUndPerson() {
        let a = PhoneSuchAuswahl.jahr(2019).mitPerson("p1")
        let f = a.searchFilter()
        #expect(f.country == nil)
        #expect(f.personIds == .allOf(["p1"]))
        #expect(f.takenAt != nil)
    }

    @Test("Land entfernen lässt Person und Jahr stehen")
    func ohneLand() {
        let a = PhoneSuchAuswahl.stadt("Rome", in: "Italy").mitJahr(2019).mitPerson("p1").ohneLand()
        #expect(a.land == nil && a.stadt == nil && a.region == nil)
        #expect(a.jahr == 2019 && a.personen == ["p1"])
    }

    @Test("Zeitraum, Typ, Favoriten wirken im Filter; Typ der Auswahl schlägt den Parameter")
    func weitereFelder() {
        let von = Date(timeIntervalSince1970: 1_700_000_000)
        let a = PhoneSuchAuswahl.leer
            .mitZeitraum(.init(von: von, bis: nil, label: "seit 2023"))
            .mitTyp(.video)
            .mitFavoriten(true)
        let f = a.searchFilter(type: .image)
        #expect(f.type == .equals(.video))
        #expect(f.isFavorite == .equals(true))
        #expect(f.takenAt == SearchCondition<String>.dateRange(from: von, to: .distantFuture))
    }

    @Test("Freitext allein ist eine Auswahl, geht aber nicht in den Filter")
    func freitext() {
        let a = PhoneSuchAuswahl.leer.mitFreitext("  Strand ")
        #expect(a.freitext == "Strand")
        #expect(!a.istLeer)
        #expect(a.searchFilter() == .visibleLibrary(type: nil))
        #expect(PhoneSuchAuswahl.leer.mitFreitext("   ").istLeer)
    }

    @Test("Leer ist leer, auch nach Hin und Zurück")
    func leer() {
        #expect(PhoneSuchAuswahl.leer.istLeer)
        #expect(PhoneSuchAuswahl.person("p").mitPerson("p").istLeer)
    }

    @Test("Codable für „Zuletzt gesucht“")
    func codable() throws {
        let a = PhoneSuchAuswahl.land("Italy").mitJahr(2019).mitPerson("p").mitFreitext("Strand")
        let zurueck = try JSONDecoder().decode(PhoneSuchAuswahl.self, from: JSONEncoder().encode(a))
        #expect(zurueck == a)
    }
}
