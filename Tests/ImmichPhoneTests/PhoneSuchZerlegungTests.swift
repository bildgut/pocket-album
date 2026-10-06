import Foundation
import Testing
@testable import ImmichPhone

@Suite("PhoneSuchZerlegung")
struct PhoneSuchZerlegungTests {
    private func person(_ id: String, _ name: String, _ n: Int = 10) -> Person {
        Person(id: id, name: name, birthDate: nil, thumbnailPath: nil, isHidden: false, isFavorite: false, assetCount: n)
    }
    private var orte: PhoneOrtsKatalog {
        PhoneOrtsKatalog(basis: "https://x", laender: [
            PhoneOrtsLand(name: "Italy", anzahl: 500, zuletzt: nil, titelbildId: nil, staedte: ["Rome", "Florence"], regionen: []),
            PhoneOrtsLand(name: "Germany", anzahl: 900, zuletzt: nil, titelbildId: nil, staedte: ["Berlin"], regionen: []),
        ], aufgebautAm: nil)
    }
    private var katalog: SearchCatalog {
        PhoneSuchZerlegung.katalog(personen: [person("a", "Anna"), person("t", "Tom")], orte: orte)
    }

    @Test("„Anna 2019“ → Person und Jahr, kein Freitext")
    func annaJahr() {
        let e = PhoneSuchZerlegung.zerlege("Anna 2019", katalog: katalog)
        #expect(e.auswahl.personen == ["a"])
        #expect(e.auswahl.jahr == 2019)
        #expect(e.auswahl.freitext.isEmpty)
        #expect(e.personenNamen == ["a": "Anna"])
    }

    @Test("Deutscher Ländername und Zeitraum")
    func landZeitraum() {
        let e = PhoneSuchZerlegung.zerlege("Italien letzten Sommer", katalog: katalog)
        #expect(e.auswahl.land == "Italy")
        #expect(e.auswahl.zeitraum != nil)
    }

    @Test("Unbekanntes Wort wird Freitext")
    func freitext() {
        let e = PhoneSuchZerlegung.zerlege("Strand", katalog: katalog)
        #expect(e.auswahl.freitext == "Strand")
        #expect(e.auswahl.personen.isEmpty && e.auswahl.land == nil)
    }

    @Test("Stadt ohne Land")
    func stadt() {
        #expect(PhoneSuchZerlegung.zerlege("Rome", katalog: katalog).auswahl.stadt == "Rome")
    }

    @Test("Nur Füllwörter ergeben eine leere Auswahl")
    func fuellwoerter() {
        #expect(PhoneSuchZerlegung.zerlege("meine Fotos", katalog: katalog).auswahl.istLeer)
    }

    @Test("Zwei Personen gleichen Namens: kein Absturz, höchstens eine")
    func doppelteNamen() {
        let k = PhoneSuchZerlegung.katalog(personen: [person("a1", "Anna", 50), person("a2", "Anna", 3)], orte: nil)
        #expect(PhoneSuchZerlegung.zerlege("Anna", katalog: k).auswahl.personen.count <= 1)
    }

    @Test("Favoriten und Videos")
    func typUndFavorit() {
        let e = PhoneSuchZerlegung.zerlege("Videos Favoriten", katalog: katalog)
        #expect(e.auswahl.typ == .video)
        #expect(e.auswahl.nurFavoriten)
    }

    @Test("Versteckte und unbenannte Personen stehen nicht im Katalog")
    func katalogPersonen() {
        let versteckt = Person(id: "v", name: "Vera", birthDate: nil, thumbnailPath: nil, isHidden: true, isFavorite: false, assetCount: 5)
        let k = PhoneSuchZerlegung.katalog(personen: [versteckt, person("u", "")], orte: nil)
        #expect(k.people.isEmpty)
    }
}
