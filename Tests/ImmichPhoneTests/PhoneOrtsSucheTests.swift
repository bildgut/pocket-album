import Foundation
import Testing
@testable import ImmichPhone

// Der Katalog dieses Servers führt 771 Städte, darunter „Agía Galíni" und
// „Hyōgo". Ohne Akzent-Normalisierung findet man sie auf einer deutschen
// Tastatur nie — daher die ersten Tests.

private func katalog(_ laender: [PhoneOrtsLand]) -> PhoneOrtsKatalog {
    PhoneOrtsKatalog(basis: "https://immich.example", laender: laender)
}

private func land(_ name: String, staedte: [String] = [], regionen: [String] = []) -> PhoneOrtsLand {
    PhoneOrtsLand(name: name, anzahl: 1, zuletzt: nil, titelbildId: nil, staedte: staedte, regionen: regionen)
}

@Suite("PhoneOrtsSuche")
struct PhoneOrtsSucheTests {

    private let k = katalog([
        land("Japan", staedte: ["Tokyo", "Osaka", "Higashiosaka"], regionen: ["Hyōgo", "Kanagawa"]),
        land("Greece", staedte: ["Agía Galíni"]),
        land("Luxembourg", staedte: ["Luxembourg"]),
    ])

    @Test("Leere Eingabe und reine Leerzeichen ergeben keine Treffer")
    func leer() {
        #expect(PhoneOrtsSuche.treffer("", in: k).isEmpty)
        #expect(PhoneOrtsSuche.treffer("   ", in: k).isEmpty)
    }

    @Test("Ohne Katalog keine Treffer")
    func ohneKatalog() {
        #expect(PhoneOrtsSuche.treffer("tok", in: nil).isEmpty)
    }

    @Test("„tok\" findet Tokyo als Stadt in Japan")
    func tokyo() {
        let t = PhoneOrtsSuche.treffer("tok", in: k)
        #expect(t.first == PhoneOrtsTreffer(art: .stadt, name: "Tokyo", land: "Japan"))
    }

    @Test("Akzente und Makrons spielen keine Rolle")
    func akzente() {
        #expect(PhoneOrtsSuche.treffer("agia galini", in: k).map(\.name) == ["Agía Galíni"])
        #expect(PhoneOrtsSuche.treffer("HYOGO", in: k).map(\.name) == ["Hyōgo"])
    }

    @Test("Regionen sind eine eigene Trefferart")
    func region() {
        let t = PhoneOrtsSuche.treffer("kanag", in: k)
        #expect(t == [PhoneOrtsTreffer(art: .region, name: "Kanagawa", land: "Japan")])
    }

    @Test("Wortanfang vor Teiltreffer")
    func wortanfang() {
        #expect(PhoneOrtsSuche.treffer("osaka", in: k).map(\.name) == ["Osaka", "Higashiosaka"])
    }

    @Test("Bei gleichem Anfang: Land vor Stadt")
    func landVorStadt() {
        let t = PhoneOrtsSuche.treffer("lux", in: k)
        #expect(t.map(\.art) == [.land, .stadt])
    }

    @Test("Dieselbe Stadt in zwei Ländern ergibt zwei Treffer mit eigener ID")
    func gleicherName() {
        let doppelt = katalog([land("France", staedte: ["Paris"]), land("United States of America", staedte: ["Paris"])])
        let t = PhoneOrtsSuche.treffer("paris", in: doppelt)
        #expect(t.count == 2)
        #expect(Set(t.map(\.id)).count == 2)
    }

    @Test("Ein Treffer wird zur passenden Auswahl")
    func auswahl() {
        #expect(PhoneOrtsTreffer(art: .land, name: "Japan", land: "Japan").auswahl == .land("Japan"))
        #expect(PhoneOrtsTreffer(art: .stadt, name: "Tokyo", land: "Japan").auswahl == .stadt("Tokyo", in: "Japan"))
        #expect(PhoneOrtsTreffer(art: .region, name: "Kanagawa", land: "Japan").auswahl == .region("Kanagawa", in: "Japan"))
    }

    @Test("Höchstens maxTreffer Ergebnisse")
    func obergrenze() {
        let viele = katalog([land("Germany", staedte: (1...40).map { "Stadt \($0)" })])
        #expect(PhoneOrtsSuche.treffer("stadt", in: viele).count == PhoneOrtsSuche.maxTreffer)
    }
}
