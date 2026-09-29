import Foundation
import Testing
@testable import ImmichPhone

@Suite("Orte: API-Ergänzungen", .serialized)
struct OrteAPITests {

    private let host = "orte-api.test"

    @Test("searchSuggestions reicht country und state durch und verwirft null")
    func vorschlaegeEingeschraenkt() async throws {
        let mitschnitt = OrteMitschnitt()
        OrteMockURLProtocol.registriere(host: host) { request, koerper in
            mitschnitt.merke(request, koerper)
            return (200, #"["Tokyo",null,"Shibuya"]"#.data(using: .utf8)!)
        }
        defer { OrteMockURLProtocol.entferne(host: host) }

        let staedte = try await OrteMockURLProtocol.client(host: host)
            .searchSuggestions(type: "city", country: "Japan", state: "Tōkyō")

        #expect(staedte == ["Tokyo", "Shibuya"])
        let request = try #require(mitschnitt.alle.first?.request)
        #expect(request.url?.path == "/api/search/suggestions")
        #expect(OrteMockURLProtocol.query(request, "type") == "city")
        #expect(OrteMockURLProtocol.query(request, "country") == "Japan")
        #expect(OrteMockURLProtocol.query(request, "state") == "Tōkyō")
    }

    @Test("Ohne country und state bleibt die Anfrage wie bisher")
    func vorschlaegeOhneEinschraenkung() async throws {
        let mitschnitt = OrteMitschnitt()
        OrteMockURLProtocol.registriere(host: host) { request, koerper in
            mitschnitt.merke(request, koerper)
            return (200, #"["Japan"]"#.data(using: .utf8)!)
        }
        defer { OrteMockURLProtocol.entferne(host: host) }

        _ = try await OrteMockURLProtocol.client(host: host).searchSuggestions(type: "country")

        let request = try #require(mitschnitt.alle.first?.request)
        #expect(OrteMockURLProtocol.query(request, "country") == nil)
        #expect(OrteMockURLProtocol.query(request, "state") == nil)
    }

    @Test("searchStatistics schickt den Filter und liest total")
    func statistik() async throws {
        let mitschnitt = OrteMitschnitt()
        OrteMockURLProtocol.registriere(host: host) { request, koerper in
            mitschnitt.merke(request, koerper)
            return (200, #"{"total":12367}"#.data(using: .utf8)!)
        }
        defer { OrteMockURLProtocol.entferne(host: host) }

        var filter = SearchFilter.visibleLibrary(type: nil)
        filter.country = .equals("Japan")
        let total = try await OrteMockURLProtocol.client(host: host).searchStatistics(filter: filter)

        #expect(total == 12367)
        let eintrag = try #require(mitschnitt.alle.first)
        #expect(eintrag.request.url?.path == "/api/search/statistics")
        #expect(eintrag.request.httpMethod == "POST")
        let json = OrteMockURLProtocol.json(eintrag.koerper)
        let gesendet = json["filter"] as? [String: Any]
        #expect((gesendet?["country"] as? [String: Any])?["eq"] as? String == "Japan")
        // Nur `filter` — flache Felder daneben beantwortet der Server mit 400.
        #expect(json.keys.sorted() == ["filter"])
    }

    @Test("searchStatistics wirft bei einem Fehlerstatus")
    func statistikFehler() async throws {
        OrteMockURLProtocol.registriere(host: host) { _, _ in (500, Data()) }
        defer { OrteMockURLProtocol.entferne(host: host) }

        await #expect(throws: APIError.httpError(500)) {
            _ = try await OrteMockURLProtocol.client(host: host)
                .searchStatistics(filter: .visibleLibrary(type: nil))
        }
    }

    @Test("searchAllAssets fordert mit withPeople die Personen an")
    func alleAssetsMitPersonen() async throws {
        let mitschnitt = OrteMitschnitt()
        OrteMockURLProtocol.registriere(host: host) { request, koerper in
            mitschnitt.merke(request, koerper)
            return (200, OrteMockURLProtocol.seiteJSON([
                OrteMockURLProtocol.assetJSON(id: "a1", localDateTime: "2019-04-02T10:00:00.000Z", people: [("p1", "Clara", false)])
            ]))
        }
        defer { OrteMockURLProtocol.entferne(host: host) }

        let assets = try await OrteMockURLProtocol.client(host: host)
            .searchAllAssets(filter: .visibleLibrary(type: nil), withPeople: true)

        #expect(assets.first?.people?.first?.name == "Clara")
        let json = OrteMockURLProtocol.json(try #require(mitschnitt.alle.first?.koerper))
        #expect(json["withPeople"] as? Bool == true)
    }
}
