import Foundation
import Testing
@testable import ImmichPhone

@Suite("Entdecken: Modell-Rechnungen")
struct PhoneEntdeckenRechnungTests {
    private func p(_ id: String, _ name: String, _ n: Int?, versteckt: Bool = false) -> Person {
        Person(id: id, name: name, birthDate: nil, thumbnailPath: nil, isHidden: versteckt, isFavorite: false, assetCount: n)
    }

    @Test("Top-Personen: benannt, sichtbar, nach Anzahl, höchstens 12")
    func topPersonen() {
        let alle = [p("a", "Anna", 5), p("b", "", 99), p("c", "Carl", 50), p("d", "Dora", 70, versteckt: true)]
            + (1...20).map { p("x\($0)", "X\($0)", 1) }
        let top = PhoneOrtsModell.topPersonen(alle)
        #expect(top.count == 12)
        #expect(top.prefix(2).map(\.id) == ["c", "a"])
        #expect(!top.contains { $0.id == "b" || $0.id == "d" })
    }

    @Test("Jahre von jüngstem bis ältestem Foto, absteigend")
    func jahre() {
        #expect(PhoneOrtsModell.jahre(aeltestes: "2021-03-01T00:00:00.000Z", juengstes: "2024-01-02T00:00:00.000Z") == [2024, 2023, 2022, 2021])
        #expect(PhoneOrtsModell.jahre(aeltestes: nil, juengstes: nil).isEmpty)
    }
}

@Suite("Entdecken: Modell", .serialized)
@MainActor
struct PhoneEntdeckenModellTests {
    private nonisolated static let host = "entdecken-modell.test"

    private func speicher() -> PhoneOrtsKatalogSpeicher {
        PhoneOrtsKatalogSpeicher(datei: FileManager.default.temporaryDirectory.appending(path: "entdecken-\(UUID().uuidString).json"))
    }

    private func registriere(_ mitschnitt: OrteMitschnitt = OrteMitschnitt(), host: String = Self.host) {
        OrteMockURLProtocol.registriere(host: host) { r, k in
            mitschnitt.merke(r, k)
            if r.url?.path == "/api/people" {
                return (200, Data(#"{"total":2,"people":[{"id":"a","name":"Anna","isHidden":false,"assetCount":40},{"id":"t","name":"Tom","isHidden":false,"assetCount":9}],"hasNextPage":false}"#.utf8))
            }
            if r.url?.path == "/api/search/statistics" { return (200, Data(#"{"total":3}"#.utf8)) }
            let richtung = (OrteMockURLProtocol.json(k)["orderBy"] as? [String: Any])?["direction"] as? String
            let jahr = richtung == "asc" ? "2019" : "2026"
            return (200, OrteMockURLProtocol.seiteJSON([OrteMockURLProtocol.assetJSON(id: "e\(jahr)", localDateTime: "\(jahr)-05-01T10:00:00.000Z")]))
        }
    }

    @Test("Einstiege: Personen und Jahresspanne")
    func einstiege() async {
        registriere()
        defer { OrteMockURLProtocol.entferne(host: Self.host) }
        let m = PhoneOrtsModell(speicher: speicher())
        await m.ladeEinstiege(apiClient: OrteMockURLProtocol.client(host: Self.host), personenErlaubt: true)
        #expect(m.personen.map(\.id) == ["a", "t"])
        #expect(m.jahre.first == 2026 && m.jahre.last == 2019)
    }

    @Test("Ohne person.read keine Personen-Abfrage")
    func ohneRecht() async {
        let mitschnitt = OrteMitschnitt()
        registriere(mitschnitt)
        defer { OrteMockURLProtocol.entferne(host: Self.host) }
        let m = PhoneOrtsModell(speicher: speicher())
        await m.ladeEinstiege(apiClient: OrteMockURLProtocol.client(host: Self.host), personenErlaubt: false)
        #expect(m.personen.isEmpty)
        #expect(!mitschnitt.alle.contains { $0.request.url?.path == "/api/people" })
    }

    @Test("Textsuche setzt die Auswahl; nur Person, ohne Land")
    func suche() async {
        registriere()
        defer { OrteMockURLProtocol.entferne(host: Self.host) }
        let client = OrteMockURLProtocol.client(host: Self.host)
        let m = PhoneOrtsModell(speicher: speicher())
        await m.ladeEinstiege(apiClient: client, personenErlaubt: true)
        await m.suche("Anna", apiClient: client)
        #expect(m.auswahl.personen == ["a"])
        #expect(m.auswahl.land == nil)
        #expect(m.personenNamen["a"] == "Anna")
    }

    @Test("Mit Freitext keine Facetten-Zählung (sie kennte den Text nicht)")
    func freitextOhneFacetten() async throws {
        // Eigener Host: Zählungen aus vorigen Tests laufen im Hintergrund weiter
        // und landeten sonst in diesem Mitschnitt.
        let host = "entdecken-freitext.test"
        let mitschnitt = OrteMitschnitt()
        registriere(mitschnitt, host: host)
        defer { OrteMockURLProtocol.entferne(host: host) }
        let m = PhoneOrtsModell(speicher: speicher())
        await m.waehle(PhoneSuchAuswahl.leer.mitFreitext("Strand"), apiClient: OrteMockURLProtocol.client(host: host))
        try await Task.sleep(for: .milliseconds(200))
        #expect(!mitschnitt.alle.contains { $0.request.url?.path == "/api/search/statistics" })
        #expect(m.facetten.treffer == nil)
    }

    @Test("Leeren vergisst Personen, Jahre und Zuletzt gesucht")
    func leeren() async {
        registriere()
        defer { OrteMockURLProtocol.entferne(host: Self.host) }
        let client = OrteMockURLProtocol.client(host: Self.host)
        let m = PhoneOrtsModell(speicher: speicher())
        await m.ladeEinstiege(apiClient: client, personenErlaubt: true)
        await m.waehle(.jahr(2020), apiClient: client)
        m.merkeZuletzt(titel: "2020", basis: client.baseURL.absoluteString)
        #expect(!m.zuletzt.isEmpty)
        m.leere()
        #expect(m.personen.isEmpty && m.jahre.isEmpty && m.zuletzt.isEmpty)
        #expect(PhoneZuletztGesucht.lade(basis: client.baseURL.absoluteString).isEmpty)
    }
}

@Suite("Entdecken: Befunde der Abschlussprüfung", .serialized)
@MainActor
struct PhoneEntdeckenBefundTests {
    private func speicher() -> PhoneOrtsKatalogSpeicher {
        PhoneOrtsKatalogSpeicher(datei: FileManager.default.temporaryDirectory.appending(path: "entdecken-b-\(UUID().uuidString).json"))
    }

    private func registriere(host: String, verzoegerung: TimeInterval = 0) {
        OrteMockURLProtocol.registriere(host: host, verzoegerung: verzoegerung) { r, _ in
            if r.url?.path == "/api/people" {
                // Echte Form: Immich liefert kein assetCount.
                return (200, Data(#"{"total":2,"people":[{"id":"a","name":"Anna","isHidden":false},{"id":"t","name":"Tom","isHidden":false}],"hasNextPage":false}"#.utf8))
            }
            if r.url?.path == "/api/search/statistics" { return (200, Data(#"{"total":3}"#.utf8)) }
            return (200, OrteMockURLProtocol.seiteJSON([OrteMockURLProtocol.assetJSON(id: "e", localDateTime: "2020-05-01T10:00:00.000Z")]))
        }
    }

    @Test("Ohne assetCount bleibt die Reihenfolge des Servers")
    func serverReihenfolge() {
        let p = { (id: String, name: String) in
            Person(id: id, name: name, birthDate: nil, thumbnailPath: nil, isHidden: false, isFavorite: false, assetCount: nil)
        }
        #expect(PhoneOrtsModell.topPersonen([p("z", "Zed"), p("a", "Anna"), p("m", "Mia")]).map(\.id) == ["z", "a", "m"])
    }

    @Test("Eine Suche wartet auf die noch ladenden Personen")
    func sucheWartet() async {
        let host = "entdecken-befund-warten.test"
        registriere(host: host, verzoegerung: 0.3)
        defer { OrteMockURLProtocol.entferne(host: host) }
        let client = OrteMockURLProtocol.client(host: host)
        let m = PhoneOrtsModell(speicher: speicher())
        let laden = Task { await m.ladeEinstiege(apiClient: client, personenErlaubt: true) }
        while !m.laedtEinstiege { await Task.yield() }
        await m.suche("Anna 2019", apiClient: client)
        #expect(m.auswahl.personen == ["a"])
        #expect(m.auswahl.freitext.isEmpty)
        await laden.value
    }

    @Test("Abmelden während des Ladens: nichts vom alten Konto kommt zurück")
    func leerenWaehrendLaden() async {
        let host = "entdecken-befund-leeren.test"
        registriere(host: host, verzoegerung: 0.3)
        defer { OrteMockURLProtocol.entferne(host: host) }
        let m = PhoneOrtsModell(speicher: speicher())
        let laden = Task { await m.ladeEinstiege(apiClient: OrteMockURLProtocol.client(host: host), personenErlaubt: true) }
        while !m.laedtEinstiege { await Task.yield() }
        m.leere()
        await laden.value
        #expect(m.personen.isEmpty && m.allePersonen.isEmpty && m.jahre.isEmpty)
    }
}

@Suite("PhoneSuchAuswahl: Jahr und Zeitraum schließen sich aus")
struct PhoneSuchAuswahlJahrZeitraumTests {
    @Test("Jahr verdrängt Zeitraum und umgekehrt")
    func exklusiv() {
        let z = PhoneSuchAuswahl.Zeitraum(von: Date(timeIntervalSince1970: 0), bis: nil, label: "seit 1970")
        let a = PhoneSuchAuswahl.leer.mitZeitraum(z).mitJahr(2019)
        #expect(a.jahr == 2019 && a.zeitraum == nil)
        let b = PhoneSuchAuswahl.jahr(2019).mitZeitraum(z)
        #expect(b.jahr == nil && b.zeitraum == z)
    }
}
