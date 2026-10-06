import Foundation
import Testing
@testable import ImmichPhone

private func asset(_ id: String, personen: [(id: String, name: String, hidden: Bool)]) -> Asset {
    Asset(
        id: id, type: .image, originalFileName: "\(id).jpg",
        fileCreatedAt: "2019-04-02T10:00:00.000Z", fileModifiedAt: "2019-04-02T10:00:00.000Z",
        isFavorite: false,
        people: personen.map {
            Person(id: $0.id, name: $0.name, birthDate: nil, thumbnailPath: nil, isHidden: $0.hidden, isFavorite: nil, assetCount: nil)
        }
    )
}

@Suite("PhoneOrtsFacettenRechnung")
struct PhoneOrtsFacettenRechnungTests {

    @Test("Personen automatisch nur unter 2 000 Treffern")
    func schwelle() {
        #expect(PhoneOrtsFacettenRechnung.personenAutomatisch(treffer: 1_999))
        #expect(!PhoneOrtsFacettenRechnung.personenAutomatisch(treffer: 2_000))
    }

    @Test("Größenschätzung aus 1,39 MB je 1 000 Assets, mindestens 1 MB")
    func megabyte() {
        #expect(PhoneOrtsFacettenRechnung.geschaetzteMegabyte(treffer: 12_367) == 17)
        #expect(PhoneOrtsFacettenRechnung.geschaetzteMegabyte(treffer: 50_056) == 70)
        #expect(PhoneOrtsFacettenRechnung.geschaetzteMegabyte(treffer: 251) == 1)
    }

    @Test("Unbenannte und versteckte Personen fallen heraus")
    func unbenannteRaus() {
        let chips = PhoneOrtsFacettenRechnung.personen(aus: [
            asset("a1", personen: [("p1", "Clara", false), ("p2", "", false), ("p3", "Versteckt", true)]),
        ])
        #expect(chips.map(\.id) == ["p1"])
    }

    @Test("Zwei Gesichter derselben Person auf einem Foto zählen einmal")
    func doppeltesGesicht() {
        let chips = PhoneOrtsFacettenRechnung.personen(aus: [
            asset("a1", personen: [("p1", "Clara", false), ("p1", "Clara", false)]),
        ])
        #expect(chips.first?.anzahl == 1)
    }

    @Test("Personen nach Anzahl, bei Gleichstand nach Name")
    func personenSortierung() {
        let chips = PhoneOrtsFacettenRechnung.personen(aus: [
            asset("a1", personen: [("p1", "Clara", false), ("p3", "Ben", false)]),
            asset("a2", personen: [("p3", "Ben", false), ("p2", "Anna", false)]),
        ])
        #expect(chips.map(\.titel) == ["Ben", "Anna", "Clara"])
        #expect(chips.map(\.anzahl) == [2, 1, 1])
    }

    @Test("Kandidatenjahre sind um je ein Jahr erweitert und absteigend")
    func kandidatenjahre() {
        let jahre = PhoneOrtsFacettenRechnung.kandidatenjahre(
            juengstes: "2019-12-31T23:00:00.000Z", aeltestes: "2017-03-01T10:00:00.000Z"
        )
        #expect(jahre == [2020, 2019, 2018, 2017, 2016])
    }

    @Test("Ohne Grenzfotos keine Kandidatenjahre")
    func keineJahre() {
        #expect(PhoneOrtsFacettenRechnung.kandidatenjahre(juengstes: nil, aeltestes: "2017-01-01").isEmpty)
        #expect(PhoneOrtsFacettenRechnung.kandidatenjahre(juengstes: "2016-01-01", aeltestes: "2017-01-01").isEmpty)
    }

    @Test("Jahres-Chips ohne leere Jahre, absteigend")
    func jahresChips() {
        let chips = PhoneOrtsFacettenRechnung.jahresChips([2017: 2882, 2018: 0, 2023: 3277, 2020: 1])
        #expect(chips.map(\.titel) == ["2023", "2020", "2017"])
        #expect(chips.first?.anzahl == 3277)
    }

    @Test("Stadt-Chips ohne leere Städte, nach Anzahl, bei Gleichstand nach Name")
    func stadtChips() {
        let chips = PhoneOrtsFacettenRechnung.stadtChips(["Osaka": 614, "Kyoto": 758, "Aso": 0, "Kobe": 614])
        #expect(chips.map(\.id) == ["Kyoto", "Kobe", "Osaka"])
    }
}

/// Server für die Japan-Auswahl. Ohne Stadt und Jahr im Filter antwortet er mit
/// `treffer`. Sonst multipliziert er einen Stadtanteil (Tokyo 4, Kyoto 1, keine
/// Stadt 5) mit einem Jahresanteil (2019: 10, 2023: 3, andere Jahre 0, kein Jahr 1).
/// Das Produkt hält beide Dimensionen unterscheidbar — auch wenn eine Zählung
/// Stadt **und** Jahr trägt, wie bei gewählter Stadt die Jahreszählung. Zwei Assets
/// mit Personen bedienen den Durchlauf.
private func facettenServer(treffer: Int, mitschnitt: OrteMitschnitt) -> OrteMockURLProtocol.Handler {
    { request, koerper in
        mitschnitt.merke(request, koerper)
        let json = OrteMockURLProtocol.json(koerper)
        let filter = json["filter"] as? [String: Any] ?? [:]
        switch request.url?.path {
        case "/api/search/statistics":
            let stadt = (filter["city"] as? [String: Any])?["eq"] as? String
            let von = (filter["takenAt"] as? [String: Any])?["gte"] as? String
            if stadt == nil && von == nil {
                return (200, Data(#"{"total":\#(treffer)}"#.utf8))
            }
            let stadtAnteil = stadt.map { $0 == "Tokyo" ? 4 : 1 } ?? 5
            let jahrAnteil = von.map { $0.hasPrefix("2019") ? 10 : ($0.hasPrefix("2023") ? 3 : 0) } ?? 1
            return (200, Data(#"{"total":\#(stadtAnteil * jahrAnteil)}"#.utf8))
        case "/api/search/metadata":
            if json["withPeople"] as? Bool == true {
                return (200, OrteMockURLProtocol.seiteJSON([
                    OrteMockURLProtocol.assetJSON(id: "a1", localDateTime: "2019-04-02T10:00:00.000Z", people: [("p1", "Clara", false), ("p2", "", false)]),
                    OrteMockURLProtocol.assetJSON(id: "a2", localDateTime: "2023-05-02T10:00:00.000Z", people: [("p1", "Clara", false), ("p3", "Ben", false)]),
                ]))
            }
            let richtung = (json["orderBy"] as? [String: Any])?["direction"] as? String
            let zeit = richtung == "asc" ? "2019-04-02T10:00:00.000Z" : "2023-05-02T10:00:00.000Z"
            return (200, OrteMockURLProtocol.seiteJSON([OrteMockURLProtocol.assetJSON(id: "grenze-\(richtung ?? "")", localDateTime: zeit)]))
        default:
            return (404, Data())
        }
    }
}

@Suite("PhoneOrtsFacetten", .serialized)
@MainActor
struct PhoneOrtsFacettenTests {

    private let host = "orte-facetten.test"
    private let japan = PhoneOrtsLand(name: "Japan", anzahl: 251, zuletzt: nil, titelbildId: nil, staedte: ["Tokyo", "Kyoto"], regionen: [])

    @Test("Unter der Schwelle kommen alle drei Reihen")
    func alleDreiReihen() async {
        let mitschnitt = OrteMitschnitt()
        OrteMockURLProtocol.registriere(host: host, facettenServer(treffer: 251, mitschnitt: mitschnitt))
        defer { OrteMockURLProtocol.entferne(host: host) }

        let facetten = PhoneOrtsFacetten()
        await facetten.laden(fuer: .land("Japan"), katalogLand: japan, gespeicherteStaedte: nil, apiClient: OrteMockURLProtocol.client(host: host))

        #expect(facetten.treffer == 251)
        #expect(facetten.staedte.map(\.id) == ["Tokyo", "Kyoto"])
        #expect(facetten.jahre.map(\.titel) == ["2023", "2019"])
        #expect(facetten.personen == .bereit([
            PhoneOrtsChip(id: "p1", titel: "Clara", anzahl: 2),
            PhoneOrtsChip(id: "p3", titel: "Ben", anzahl: 1),
        ]))
        #expect(!facetten.staedteLaden)
        #expect(!facetten.jahreLaden)
    }

    @Test("Über der Schwelle: Knopf statt Durchlauf, keine Personenanfrage")
    func ueberSchwelle() async {
        let mitschnitt = OrteMitschnitt()
        OrteMockURLProtocol.registriere(host: host, facettenServer(treffer: 5_000, mitschnitt: mitschnitt))
        defer { OrteMockURLProtocol.entferne(host: host) }

        let facetten = PhoneOrtsFacetten()
        await facetten.laden(fuer: .land("Japan"), katalogLand: japan, gespeicherteStaedte: nil, apiClient: OrteMockURLProtocol.client(host: host))

        #expect(facetten.personen == .aufAnfrage(megabyte: 7))
        let personenAnfragen = mitschnitt.alle.filter { OrteMockURLProtocol.json($0.koerper)["withPeople"] as? Bool == true }
        #expect(personenAnfragen.isEmpty)
    }

    @Test("Auf Tippen ermittelt, danach aus dem Zwischenspeicher")
    func aufTippenUndCache() async {
        let mitschnitt = OrteMitschnitt()
        OrteMockURLProtocol.registriere(host: host, facettenServer(treffer: 5_000, mitschnitt: mitschnitt))
        defer { OrteMockURLProtocol.entferne(host: host) }

        let client = OrteMockURLProtocol.client(host: host)
        let facetten = PhoneOrtsFacetten()
        await facetten.personenErmitteln(fuer: .land("Japan"), apiClient: client)
        await facetten.laden(fuer: .land("Japan"), katalogLand: japan, gespeicherteStaedte: nil, apiClient: client)

        guard case .bereit(let chips) = facetten.personen else {
            Issue.record("Erwartet .bereit, war \(facetten.personen)")
            return
        }
        #expect(chips.map(\.titel) == ["Clara", "Ben"])
        let personenAnfragen = mitschnitt.alle.filter { OrteMockURLProtocol.json($0.koerper)["withPeople"] as? Bool == true }
        #expect(personenAnfragen.count == 1)
    }

    @Test("Städte werden ohne die gewählte Stadt gezählt, Jahre ohne das gewählte Jahr")
    func eigeneDimensionAusgenommen() async {
        let mitschnitt = OrteMitschnitt()
        OrteMockURLProtocol.registriere(host: host, facettenServer(treffer: 251, mitschnitt: mitschnitt))
        defer { OrteMockURLProtocol.entferne(host: host) }

        let facetten = PhoneOrtsFacetten()
        await facetten.laden(
            fuer: PhoneSuchAuswahl.stadt("Tokyo", in: "Japan").mitJahr(2019),
            katalogLand: japan, gespeicherteStaedte: nil,
            apiClient: OrteMockURLProtocol.client(host: host)
        )

        // Beide Städte bleiben sichtbar, obwohl Tokyo gewählt ist (Tokyo 4×10, Kyoto 1×10),
        // und beide Jahre, obwohl 2019 gewählt ist (Tokyo: 2019 4×10, 2023 4×3).
        #expect(facetten.staedte.map(\.id) == ["Tokyo", "Kyoto"])
        #expect(facetten.staedte.map(\.anzahl) == [40, 10])
        #expect(facetten.jahre.map(\.titel) == ["2023", "2019"])
        #expect(facetten.jahre.map(\.anzahl) == [12, 40])
        #expect(facetten.treffer == 40)
        let stadtZaehlungen = mitschnitt.alle
            .map { OrteMockURLProtocol.json($0.koerper)["filter"] as? [String: Any] ?? [:] }
            .filter { $0["city"] != nil && $0["takenAt"] != nil }
        // Die Städtezählung trägt das Jahr (2019), aber jeweils die gezählte Stadt.
        #expect(stadtZaehlungen.count >= 2)
    }

    @Test("Rückgabe der gezählten Städte nur bei reiner Landesauswahl")
    func rueckgabeNurLand() async {
        OrteMockURLProtocol.registriere(host: host, facettenServer(treffer: 251, mitschnitt: OrteMitschnitt()))
        defer { OrteMockURLProtocol.entferne(host: host) }

        let client = OrteMockURLProtocol.client(host: host)
        let facetten = PhoneOrtsFacetten()
        let nurLand = await facetten.laden(fuer: .land("Japan"), katalogLand: japan, gespeicherteStaedte: nil, apiClient: client)
        #expect(nurLand?.map(\.id) == ["Tokyo", "Kyoto"])

        let mitJahr = await facetten.laden(fuer: PhoneSuchAuswahl.land("Japan").mitJahr(2019), katalogLand: japan, gespeicherteStaedte: nil, apiClient: client)
        #expect(mitJahr == nil)
    }

    @Test("Gespeicherte Städte stehen sofort da und bleiben, wenn die Zählung scheitert")
    func gespeicherteStaedte() async {
        OrteMockURLProtocol.registriere(host: host) { request, _ in
            request.url?.path == "/api/search/statistics" ? (500, Data()) : (200, OrteMockURLProtocol.seiteJSON([]))
        }
        defer { OrteMockURLProtocol.entferne(host: host) }

        let gespeichert = [PhoneOrtsChip(id: "Kyoto", titel: "Kyoto", anzahl: 758)]
        let facetten = PhoneOrtsFacetten()
        await facetten.laden(fuer: .land("Japan"), katalogLand: japan, gespeicherteStaedte: gespeichert, apiClient: OrteMockURLProtocol.client(host: host))

        #expect(facetten.staedte == gespeichert)
        #expect(facetten.treffer == nil)
        #expect(facetten.personen == .fehler(PhoneOrtsFacetten.trefferFehlerText))
    }

    @Test("leere() räumt alle Reihen")
    func leeren() {
        let facetten = PhoneOrtsFacetten()
        facetten.leere()
        #expect(facetten.treffer == nil)
        #expect(facetten.staedte.isEmpty)
        #expect(facetten.jahre.isEmpty)
        #expect(facetten.personen == .keine)
    }

    @Test("vergiss() leert Reihen und Personen-Zwischenspeicher, vergissPersonen() nur den Zwischenspeicher")
    func vergiss() async {
        let mitschnitt = OrteMitschnitt()
        OrteMockURLProtocol.registriere(host: host, facettenServer(treffer: 5_000, mitschnitt: mitschnitt))
        defer { OrteMockURLProtocol.entferne(host: host) }
        let client = OrteMockURLProtocol.client(host: host)
        let personenAnfragen = {
            mitschnitt.alle.filter { OrteMockURLProtocol.json($0.koerper)["withPeople"] as? Bool == true }.count
        }

        let facetten = PhoneOrtsFacetten()
        await facetten.personenErmitteln(fuer: .land("Japan"), apiClient: client)
        #expect(personenAnfragen() == 1)

        facetten.vergiss()
        #expect(facetten.personen == .keine)
        await facetten.personenErmitteln(fuer: .land("Japan"), apiClient: client)
        #expect(personenAnfragen() == 2)

        facetten.vergissPersonen()
        guard case .bereit = facetten.personen else {
            Issue.record("vergissPersonen() darf die sichtbare Reihe nicht leeren, war \(facetten.personen)")
            return
        }
        await facetten.personenErmitteln(fuer: .land("Japan"), apiClient: client)
        #expect(personenAnfragen() == 3)
    }
}

/// Ein Server, der jede Antwort erst nach ~0,5 s liefert — genug Zeit, den
/// laufenden `Task` mittendrin abzubrechen, bevor die Anfrage zurückkommt.
private func traegerServer() -> OrteMockURLProtocol.Handler {
    { request, _ in
        Thread.sleep(forTimeInterval: 0.5)
        switch request.url?.path {
        case "/api/search/statistics":
            return (200, Data(#"{"total":251}"#.utf8))
        default:
            return (200, OrteMockURLProtocol.seiteJSON([]))
        }
    }
}

/// Ein Abbruch ist kein Fehler: `PhoneOrtsModell.waehle` bricht einen laufenden
/// `Task` ab, sobald die Auswahl wechselt — die veröffentlichten Reihen dürfen
/// dabei weder eine Fehlermeldung zeigen noch geleerte Werte, die eine neue
/// Auswahl gleich wieder überschreibt. Eigener Host, eigene Suite: Die
/// künstliche Verzögerung soll die `.serialized`-Suite oben nicht verlangsamen.
@Suite("PhoneOrtsFacetten Abbruch", .serialized)
@MainActor
struct PhoneOrtsFacettenAbbruchTests {

    private let host = "orte-facetten-abbruch.test"
    private let japan = PhoneOrtsLand(name: "Japan", anzahl: 251, zuletzt: nil, titelbildId: nil, staedte: ["Tokyo", "Kyoto"], regionen: [])

    @Test("Ein mittendrin abgebrochener laden()-Lauf zeigt keinen Fehler")
    func abgebrochenesLadenZeigtKeinenFehler() async {
        OrteMockURLProtocol.registriere(host: host, traegerServer())
        defer { OrteMockURLProtocol.entferne(host: host) }

        let facetten = PhoneOrtsFacetten()
        let client = OrteMockURLProtocol.client(host: host)
        let lauf = Task {
            await facetten.laden(fuer: .land("Japan"), katalogLand: japan, gespeicherteStaedte: nil, apiClient: client)
        }
        // Der Server braucht 0,5 s je Antwort — nach 50 ms ist die Zählung sicher
        // noch unterwegs, wenn der Abbruch dazwischenfunkt.
        try? await Task.sleep(nanoseconds: 50_000_000)
        lauf.cancel()
        _ = await lauf.value

        // Kein Fehler, insbesondere nicht der Trefferfehlertext — der stünde für
        // eine gescheiterte Zählung, nicht für einen gewollten Abbruch.
        #expect(facetten.personen != .fehler(PhoneOrtsFacetten.trefferFehlerText))
        if case .fehler(let text) = facetten.personen {
            Issue.record("Ein Abbruch darf keinen Fehler zeigen, war .fehler(\(text))")
        }
    }

    @Test("Ein mittendrin abgebrochener personenErmitteln()-Lauf endet nicht in .fehler")
    func abgebrochenePersonenErmittlungZeigtKeinenFehler() async {
        OrteMockURLProtocol.registriere(host: host, traegerServer())
        defer { OrteMockURLProtocol.entferne(host: host) }

        let facetten = PhoneOrtsFacetten()
        let client = OrteMockURLProtocol.client(host: host)
        let lauf = Task {
            await facetten.personenErmitteln(fuer: .land("Japan"), apiClient: client)
        }
        // `searchAllAssets` prüft `Task.isCancelled` nur vor der Seite, nicht
        // während der Anfrage — der Abbruch muss also mitten in der 0,5-s-Anfrage
        // liegen, um genau den `URLError(.cancelled)`-Pfad zu treffen.
        try? await Task.sleep(nanoseconds: 50_000_000)
        lauf.cancel()
        await lauf.value

        if case .fehler(let text) = facetten.personen {
            Issue.record("Ein Abbruch darf keinen Fehler zeigen, war .fehler(\(text))")
        }
    }
}
