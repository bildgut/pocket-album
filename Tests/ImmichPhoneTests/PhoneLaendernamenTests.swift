import Foundation
import Testing
@testable import ImmichPhone

// Immich liefert Ländernamen englisch, teils in der amtlichen Langform. Der Reiter
// zeigt sie deutsch, filtert aber weiter mit dem Servernamen — der ist der Wert, den
// `SearchFilter.country` erwartet. Die Namen unten sind die 25 Länder dieses Servers
// (13.09.2026); die vier Ausnahmen kennt Apples englische Liste unter anderem Namen.

@Suite("PhoneLaendernamen")
struct PhoneLaendernamenTests {

    @Test("Übliche englische Namen werden deutsch")
    func uebliche() {
        #expect(Laendernamen.anzeigename(fuer: "Greece") == "Griechenland")
        #expect(Laendernamen.anzeigename(fuer: "Germany") == "Deutschland")
        #expect(Laendernamen.anzeigename(fuer: "Austria") == "Österreich")
        #expect(Laendernamen.anzeigename(fuer: "Türkiye") == "Türkei")
        #expect(Laendernamen.anzeigename(fuer: "South Korea") == "Südkorea")
    }

    @Test("Immichs Langformen, die Apple anders nennt, werden ebenfalls deutsch")
    func ausnahmen() {
        #expect(Laendernamen.anzeigename(fuer: "Islamic Republic of Iran") == "Iran")
        #expect(Laendernamen.anzeigename(fuer: "Czech Republic") == "Tschechien")
        #expect(Laendernamen.anzeigename(fuer: "United States of America") == "Vereinigte Staaten")
        #expect(Laendernamen.anzeigename(fuer: "Bosnia and Herzegovina") == "Bosnien und Herzegowina")
    }

    @Test("Jeder der 25 Servernamen bekommt eine deutsche Form")
    func alleLaenderDiesesServers() {
        let servernamen = [
            "Austria", "Bosnia and Herzegovina", "Croatia", "Czech Republic", "Denmark", "Finland",
            "Germany", "Greece", "Hungary", "Ireland", "Islamic Republic of Iran", "Italy", "Japan",
            "Netherlands", "Poland", "Portugal", "Qatar", "South Korea", "Spain", "Sweden",
            "Switzerland", "Türkiye", "United Arab Emirates", "United Kingdom", "United States of America",
        ]
        for name in servernamen {
            #expect(Laendernamen.regionCode(fuer: name) != nil, "kein Ländercode für \(name)")
        }
    }

    @Test("Unbekannte Namen bleiben unverändert stehen")
    func unbekannt() {
        #expect(Laendernamen.anzeigename(fuer: "Atlantis") == "Atlantis")
        #expect(Laendernamen.anzeigename(fuer: "") == "")
    }

    @Test("Groß-/Kleinschreibung und Akzente des Servernamens spielen keine Rolle")
    func normalisiert() {
        #expect(Laendernamen.anzeigename(fuer: "greece") == "Griechenland")
        #expect(Laendernamen.anzeigename(fuer: "Turkiye") == "Türkei")
    }
}

@Suite("PhoneOrtsSuche mit deutschen Ländernamen")
struct PhoneOrtsSucheDeutschTests {

    private let katalog = PhoneOrtsKatalog(
        basis: "https://immich.example",
        laender: [
            PhoneOrtsLand(name: "Greece", anzahl: 1, zuletzt: nil, titelbildId: nil, staedte: ["Chania"], regionen: []),
            PhoneOrtsLand(name: "Czech Republic", anzahl: 1, zuletzt: nil, titelbildId: nil, staedte: ["Prague"], regionen: []),
        ]
    )

    @Test("Der deutsche Name findet das Land, der Treffer trägt den Servernamen")
    func deutscherName() {
        let treffer = PhoneOrtsSuche.treffer("grie", in: katalog, sprache: Locale(identifier: "de_DE"))
        #expect(treffer.first == PhoneOrtsTreffer(art: .land, name: "Greece", land: "Greece"))
        #expect(treffer.first?.auswahl == .land("Greece"))
    }

    @Test("Auch eine Ausnahme wie „Tschechien“ wird gefunden")
    func ausnahmeGefunden() {
        #expect(PhoneOrtsSuche.treffer("tschech", in: katalog, sprache: Locale(identifier: "de_DE")).map(\.name) == ["Czech Republic"])
    }

    @Test("Der englische Servername findet das Land weiterhin")
    func englischWeiterhin() {
        #expect(PhoneOrtsSuche.treffer("greec", in: katalog).map(\.name) == ["Greece"])
    }

    @Test("Ein deutscher Ländername findet nicht die Städte des Landes")
    func keineStaedteUeberLandname() {
        #expect(PhoneOrtsSuche.treffer("griechen", in: katalog, sprache: Locale(identifier: "de_DE")).map(\.art) == [.land])
    }
}
