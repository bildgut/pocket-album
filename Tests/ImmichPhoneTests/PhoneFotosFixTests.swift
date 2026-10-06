import Foundation
import Testing
@testable import ImmichPhone

/// Jahr aus `filter.takenAt.gte` der Zählabfrage.
private func gezaehltesJahr(_ koerper: Data) -> String? {
    let filter = OrteMockURLProtocol.json(koerper)["filter"] as? [String: Any] ?? [:]
    return ((filter["takenAt"] as? [String: Any])?["gte"] as? String).map { String($0.prefix(4)) }
}

private func eintrag(_ id: String) -> PhoneAlbumGridEintrag {
    PhoneAlbumGridEintrag(id: id)
}

// MARK: - Befund 1: Einzelbild über die Asset-ID

@Suite("Einzelbild: Seiten über die Asset-ID")
struct PhoneEinzelbildSeitenTests {

    @Test("Neu sortierte Liste: Die Seiten folgen, das gezeigte Foto bleibt dasselbe")
    func umsortiert() {
        let alt = [eintrag("a"), eintrag("b"), eintrag("c")]
        // Nachladen sortiert einen neuen Tag **vor** die bisherigen: Index 1 wäre jetzt "a".
        let neu = [eintrag("x"), eintrag("a"), eintrag("b"), eintrag("c")]
        let seiten = PhoneEinzelbildSeiten.abgleich(alt: alt, neu: neu, aktuell: "b")
        #expect(seiten.map(\.id) == ["x", "a", "b", "c"])
        #expect(seiten.first { $0.id == "b" }?.id == "b")
    }

    @Test("Verschwindet das gezeigte Foto aus der Liste, bleibt der alte Stand")
    func aktuellesVerschwindet() {
        let alt = [eintrag("a"), eintrag("b")]
        let seiten = PhoneEinzelbildSeiten.abgleich(alt: alt, neu: [eintrag("a")], aktuell: "b")
        #expect(seiten.map(\.id) == ["a", "b"])
    }
}

// MARK: - Befund 2 und 3: Feed

@Suite("PhonePhotoFeed: Gruppierungsrennen und Favoriten", .serialized)
@MainActor
struct PhonePhotoFeedFixTests {
    private static let host = "feed-fix.test"

    private func registriere() {
        OrteMockURLProtocol.registriere(host: Self.host) { _, _ in
            (200, OrteMockURLProtocol.seiteJSON([
                OrteMockURLProtocol.assetJSON(id: "p1", localDateTime: "2026-07-02T10:00:00.000Z"),
                OrteMockURLProtocol.assetJSON(id: "p2", localDateTime: "2026-07-01T10:00:00.000Z"),
            ]))
        }
    }

    @Test("Eine ältere Gruppierung überschreibt das Löschen nicht mehr")
    func rennen() async {
        registriere()
        defer { OrteMockURLProtocol.entferne(host: Self.host) }
        let feed = PhonePhotoFeed()
        var erstes = true
        // Während die Gruppierung von `ladeWeitere` noch läuft, wird p1 gelöscht —
        // dessen Gruppierung ist fertig, bevor die ältere ankommt.
        feed.vorUebernahmeHaken = { [feed] in
            guard erstes else { return }
            erstes = false
            await feed.entferne(assetId: "p1")
        }
        await feed.ladeVonVorne(apiClient: OrteMockURLProtocol.client(host: Self.host))
        #expect(feed.eintraege.map(\.id) == ["p2"])
    }

    @Test("Stern entfernt in einem Feed „nur Favoriten“: Die Kachel verschwindet")
    func favoritenListeEntfernt() async {
        registriere()
        defer { OrteMockURLProtocol.entferne(host: Self.host) }
        let feed = PhonePhotoFeed()
        await feed.setzeAuswahl(PhoneSuchAuswahl.leer.mitFavoriten(true), apiClient: OrteMockURLProtocol.client(host: Self.host))
        await feed.wendeFavoritAn(assetId: "p1", ist: false)
        #expect(feed.eintraege.map(\.id) == ["p2"])
        // Setzen fügt nichts blind hinzu.
        await feed.wendeFavoritAn(assetId: "p1", ist: true)
        #expect(feed.eintraege.map(\.id) == ["p2"])
    }

    @Test("Die app-weite Meldung erreicht auch einen fremden Feed")
    func meldungErreichtAlleFeeds() async throws {
        registriere()
        defer { OrteMockURLProtocol.entferne(host: Self.host) }
        let fotos = PhonePhotoFeed()
        await fotos.ladeVonVorne(apiClient: OrteMockURLProtocol.client(host: Self.host))
        PhoneFavoritMeldung.melde(assetId: "p2", ist: true)
        for _ in 0..<100 where fotos.eintraege.first(where: { $0.id == "p2" })?.isFavorite != true {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(fotos.eintraege.first { $0.id == "p2" }?.isFavorite == true)
        #expect(fotos.eintraege.count == 2)
    }
}

// MARK: - Befund 4: Katalog ohne asset.statistics

@Suite("Ortskatalog ohne Zählrecht", .serialized)
struct PhoneOrtsKatalogOhneStatistikTests {
    private let host = "orte-ohne-statistik.test"

    private func handler() -> OrteMockURLProtocol.Handler {
        { request, koerper in
            switch request.url?.path {
            case "/api/search/suggestions":
                let typ = OrteMockURLProtocol.query(request, "type")
                let country = OrteMockURLProtocol.query(request, "country")
                if typ == "country" && country == nil { return (200, Data(#"["Japan","Austria"]"#.utf8)) }
                return (200, Data("[]".utf8))
            case "/api/search/statistics":
                return (403, Data())
            case "/api/search/metadata":
                let filter = OrteMockURLProtocol.json(koerper)["filter"] as? [String: Any] ?? [:]
                let land = (filter["country"] as? [String: Any])?["eq"] as? String
                return land == "Japan"
                    ? (200, OrteMockURLProtocol.seiteJSON([OrteMockURLProtocol.assetJSON(id: "jp-1", localDateTime: "2025-11-24T08:10:23.000Z")]))
                    : (200, OrteMockURLProtocol.seiteJSON([]))
            default: return (404, Data())
            }
        }
    }

    @Test("403 auf die Zählung: Land bleibt mit Titelbild, ohne Zahl; Katalog gilt als fertig")
    func ohneRecht() async throws {
        OrteMockURLProtocol.registriere(host: host, handler())
        defer { OrteMockURLProtocol.entferne(host: host) }
        let jetzt = Date(timeIntervalSince1970: 1_800_000_000)
        let e = try await PhoneOrtsKatalogAufbau.aufbauenMitMeldung(
            apiClient: OrteMockURLProtocol.client(host: host), vorher: nil, jetzt: jetzt
        )
        let japan = try #require(e.katalog.land("Japan"))
        #expect(japan.anzahl == nil)
        #expect(japan.titelbildId == "jp-1")
        #expect(e.katalog.land("Austria") == nil)
        #expect(e.katalog.aufgebautAm == jetzt)
        #expect(e.statistikAbgelehnt)
        #expect(PhoneOrtsTexts.landUntertitel(japan, sprache: Locale(identifier: "en_US")).contains("2025"))
    }

    @Test("Bekannt fehlendes Recht: keine Zählabfrage, kein 403")
    func rechtBekanntFehlend() async throws {
        let mitschnitt = OrteMitschnitt()
        let innen = handler()
        OrteMockURLProtocol.registriere(host: host) { r, k in mitschnitt.merke(r, k); return innen(r, k) }
        defer { OrteMockURLProtocol.entferne(host: host) }
        let e = try await PhoneOrtsKatalogAufbau.aufbauenMitMeldung(
            apiClient: OrteMockURLProtocol.client(host: host), vorher: nil, statistikErlaubt: false
        )
        #expect(!e.statistikAbgelehnt)
        #expect(!mitschnitt.alle.contains { $0.request.url?.path == "/api/search/statistics" })
    }
}

// MARK: - Befund 5: Jahresleiste

@Suite("Jahresleiste nur mit Fotos", .serialized)
struct PhoneJahresZaehlungTests {
    private let host = "jahre.test"

    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OrteMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    @Test("Monate werden zu Jahren, leere fallen weg")
    func ausMonaten() {
        let jahre = PhoneJahresZaehlung.jahre(ausMonaten: [
            ("2024-05-01T00:00:00.000Z", 3), ("2024-01-01T00:00:00.000Z", 1),
            ("2021-03-01T00:00:00.000Z", 0), ("2019-12-01T00:00:00.000Z", 7),
        ])
        #expect(jahre == [2024, 2019])
    }

    @Test("Mit Zählrecht: Jahre ohne Fotos fehlen")
    func mitStatistik() async {
        OrteMockURLProtocol.registriere(host: host) { request, koerper in
            guard request.url?.path == "/api/search/statistics" else { return (404, Data()) }
            let jahr = gezaehltesJahr(koerper)
            let n = (jahr == "2020" || jahr == "2022") ? 5 : 0
            return (200, Data(#"{"total":\#(n)}"#.utf8))
        }
        defer { OrteMockURLProtocol.entferne(host: host) }
        let e = await PhoneJahresZaehlung.jahre(
            aeltestes: "2020-02-01T00:00:00.000Z", juengstes: "2022-08-01T00:00:00.000Z",
            statistikErlaubt: true, apiClient: OrteMockURLProtocol.client(host: host)
        )
        #expect(e.jahre == [2022, 2020])
        #expect(!e.statistikAbgelehnt)
    }

    @Test("403 auf die Zählung: Zeitleiste liefert die Jahre, das Recht wird gemeldet")
    func rueckfallZeitleiste() async {
        OrteMockURLProtocol.registriere(host: host) { request, _ in
            switch request.url?.path {
            case "/api/search/statistics": return (403, Data())
            case "/api/timeline/buckets":
                return (200, Data(#"[{"timeBucket":"2022-01-01T00:00:00.000Z","count":2},{"timeBucket":"2020-06-01T00:00:00.000Z","count":1}]"#.utf8))
            default: return (404, Data())
            }
        }
        defer { OrteMockURLProtocol.entferne(host: host) }
        let e = await PhoneJahresZaehlung.jahre(
            aeltestes: "2020-02-01T00:00:00.000Z", juengstes: "2022-08-01T00:00:00.000Z",
            statistikErlaubt: true, apiClient: OrteMockURLProtocol.client(host: host), session: session()
        )
        #expect(e.jahre == [2022, 2020])
        #expect(e.statistikAbgelehnt)
    }

    @Test("Eine einzelne gescheiterte Zählung lässt die Facetten-Reihe stehen")
    func teilausfallFacetten() async {
        // parallelZaehlen ist privat; geprüft über die öffentliche Jahreszählung:
        // ein 500 für 2021 streicht nur dieses Jahr nicht weg.
        OrteMockURLProtocol.registriere(host: host) { request, koerper in
            let jahr = gezaehltesJahr(koerper)
            if jahr == "2021" { return (500, Data()) }
            return (200, Data(#"{"total":\#(jahr == "2020" ? 3 : 0)}"#.utf8))
        }
        defer { OrteMockURLProtocol.entferne(host: host) }
        let e = await PhoneJahresZaehlung.jahre(
            aeltestes: "2020-02-01T00:00:00.000Z", juengstes: "2021-08-01T00:00:00.000Z",
            statistikErlaubt: true, apiClient: OrteMockURLProtocol.client(host: host)
        )
        #expect(e.jahre == [2021, 2020])
    }
}

// MARK: - Befund 10: Tagestitel zwischengespeichert

@Suite("Tagestitel-Zwischenspeicher")
struct PhotoFeedTitelCacheTests {
    @Test("Sprachen werden getrennt zwischengespeichert")
    func sprachenGetrennt() {
        let de = PhotoFeedGrouping.titel(fuerTagesschluessel: "2026-09-05", sprache: Locale(identifier: "de_DE"))
        let en = PhotoFeedGrouping.titel(fuerTagesschluessel: "2026-09-05", sprache: Locale(identifier: "en_US"))
        #expect(de.contains("Samstag"))
        #expect(en.contains("Saturday"))
        #expect(PhotoFeedGrouping.titel(fuerTagesschluessel: "2026-09-05", sprache: Locale(identifier: "de_DE")) == de)
    }
}
