import Foundation
import Testing
@testable import ImmichPhone

@Suite("PhoneOrtsTexts")
struct PhoneOrtsTextsTests {

    private static let de = Locale(identifier: "de_DE")

    @Test("Monat und Jahr aus dem Zeitstempel, in der Sprache des Geräts")
    func monatJahr() {
        #expect(PhoneOrtsTexts.monatJahr("2025-11-24T08:10:23.000Z", sprache: Self.de) == "Nov. 2025")
        #expect(PhoneOrtsTexts.monatJahr("2026-03-01T00:00:00.000Z", sprache: Self.de) == "März 2026")
        // Die Ortszeit des Fotos zählt: 31. Dezember 23:30 bleibt im Dezember.
        #expect(PhoneOrtsTexts.monatJahr("2019-12-31T23:30:00.000Z", sprache: Self.de) == "Dez. 2019")
        #expect(PhoneOrtsTexts.monatJahr("2025-11-24T08:10:23.000Z", sprache: Locale(identifier: "en_US")) == "Nov 2025")
    }

    @Test("Unbrauchbare Zeitstempel ergeben nil statt eines Absturzes")
    func monatJahrUngueltig() {
        #expect(PhoneOrtsTexts.monatJahr(nil) == nil)
        #expect(PhoneOrtsTexts.monatJahr("2025") == nil)
        #expect(PhoneOrtsTexts.monatJahr("2025-13-01") == nil)
        #expect(PhoneOrtsTexts.monatJahr("2025-00-01") == nil)
        #expect(PhoneOrtsTexts.monatJahr("abcd-ef") == nil)
    }

    @Test("Untertitel der Kachel mit und ohne Datum")
    func landUntertitel() {
        let mit = PhoneOrtsLand(name: "Greece", anzahl: 452, zuletzt: "2026-06-29T12:00:00.000Z", titelbildId: nil, staedte: [], regionen: [])
        let ohne = PhoneOrtsLand(name: "Greece", anzahl: 452, zuletzt: nil, titelbildId: nil, staedte: [], regionen: [])
        // Die Anzahl kommt aus dem String Catalog; der Testlauf ist auf Englisch gestellt.
        #expect(PhoneOrtsTexts.landUntertitel(mit) == "452 photos · Jun 2026")
        #expect(PhoneOrtsTexts.landUntertitel(ohne) == "452 photos")
    }

    @Test("Trefferart nennt das Land außer beim Land selbst")
    func trefferArt() {
        #expect(PhoneOrtsTexts.trefferArt(.land, land: "Japan") == "Country")
        #expect(PhoneOrtsTexts.trefferArt(.stadt, land: "Japan") == "City, Japan")
        #expect(PhoneOrtsTexts.trefferArt(.region, land: "Japan") == "Region, Japan")
    }

    @Test("Einzahl und Mehrzahl der Trefferzahl")
    func trefferZahl() {
        #expect(PhoneOrtsTexts.trefferZahl(1) == "1 photo")
        #expect(PhoneOrtsTexts.trefferZahl(251) == "251 photos")
    }

    @Test("Titel eines Zuletzt-Eintrags: Teile mit Mittelpunkt, Freitext in Anführung")
    func titelFuerAuswahl() {
        let en = Locale(identifier: "en_US")
        let a = PhoneSuchAuswahl.land("Italy").mitJahr(2019).mitPerson("a").mitFreitext("Strand")
        #expect(PhoneOrtsTexts.beschriftung(fuer: a, namen: ["a": "Anna"], sprache: en) == "Italy · 2019 · Anna · “Strand”")
        let b = PhoneSuchAuswahl.person("x").mitTyp(.video).mitFavoriten(true)
        #expect(PhoneOrtsTexts.beschriftung(fuer: b, namen: [:], sprache: en) == "x · Videos · Favorites")
    }
}
