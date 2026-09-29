import Foundation
import Testing
@testable import ImmichPhone

/// Ein kleiner Server mit drei Ländern: Japan (Städte, Region, Fotos), Greece
/// (Fotos, keine Städte) und Austria (nur archivierte Fotos → Anzahl 0).
private func server(
    statistikFehlerFuer: Set<String> = [],
    laenderlisteFehler: Bool = false,
    mitschnitt: OrteMitschnitt = OrteMitschnitt()
) -> OrteMockURLProtocol.Handler {
    { request, koerper in
        mitschnitt.merke(request, koerper)
        let json = OrteMockURLProtocol.json(koerper)
        let filter = json["filter"] as? [String: Any] ?? [:]
        let land = (filter["country"] as? [String: Any])?["eq"] as? String

        switch request.url?.path {
        case "/api/search/suggestions":
            let typ = OrteMockURLProtocol.query(request, "type")
            let country = OrteMockURLProtocol.query(request, "country")
            switch (typ, country) {
            case ("country", nil):
                return laenderlisteFehler ? (500, Data()) : (200, Data(#"["Japan","Greece","Austria"]"#.utf8))
            case ("city", "Japan"): return (200, Data(#"["Tokyo","Kyoto"]"#.utf8))
            case ("state", "Japan"): return (200, Data(#"["Kantō"]"#.utf8))
            default: return (200, Data("[]".utf8))
            }
        case "/api/search/statistics":
            guard let land, !statistikFehlerFuer.contains(land) else { return (500, Data()) }
            let total = ["Japan": 12367, "Greece": 452, "Austria": 0][land] ?? 0
            return (200, Data(#"{"total":\#(total)}"#.utf8))
        case "/api/search/metadata":
            switch land {
            case "Japan":
                return (200, OrteMockURLProtocol.seiteJSON([OrteMockURLProtocol.assetJSON(id: "jp-1", localDateTime: "2025-11-24T08:10:23.000Z")]))
            case "Greece":
                return (200, OrteMockURLProtocol.seiteJSON([OrteMockURLProtocol.assetJSON(id: "gr-1", localDateTime: "2026-06-29T12:00:00.000Z")]))
            default:
                return (200, OrteMockURLProtocol.seiteJSON([]))
            }
        default:
            return (404, Data())
        }
    }
}

@Suite("PhoneOrtsKatalogAufbau", .serialized)
struct PhoneOrtsKatalogAufbauTests {

    private let host = "orte-aufbau.test"
    private let jetzt = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Vollständiger Lauf: Anzahl, Städte, Regionen, Titelbild und frischer Zeitstempel")
    func vollstaendig() async throws {
        OrteMockURLProtocol.registriere(host: host, server())
        defer { OrteMockURLProtocol.entferne(host: host) }

        let k = try await PhoneOrtsKatalogAufbau.aufbauen(
            apiClient: OrteMockURLProtocol.client(host: host), vorher: nil, jetzt: jetzt
        )

        let japan = try #require(k.land("Japan"))
        #expect(japan.anzahl == 12367)
        #expect(japan.staedte == ["Tokyo", "Kyoto"])
        #expect(japan.regionen == ["Kantō"])
        #expect(japan.titelbildId == "jp-1")
        #expect(japan.zuletzt == "2025-11-24T08:10:23.000Z")
        #expect(k.aufgebautAm == jetzt)
        #expect(k.basis == "https://\(host)")
        #expect(k.nachZuletzt.map(\.name) == ["Greece", "Japan"])
    }

    @Test("Die Sondierung fragt das jüngste Foto nach Ortszeit ab, eine Seite groß")
    func sondierung() async throws {
        let mitschnitt = OrteMitschnitt()
        OrteMockURLProtocol.registriere(host: host, server(mitschnitt: mitschnitt))
        defer { OrteMockURLProtocol.entferne(host: host) }

        _ = try await PhoneOrtsKatalogAufbau.aufbauen(apiClient: OrteMockURLProtocol.client(host: host), vorher: nil, jetzt: jetzt)

        let metadata = mitschnitt.alle.filter { $0.request.url?.path == "/api/search/metadata" }
        #expect(metadata.count == 3)
        let json = OrteMockURLProtocol.json(try #require(metadata.first?.koerper))
        #expect(json["size"] as? Int == 1)
        #expect((json["orderBy"] as? [String: Any])?["field"] as? String == "localDateTime")
        #expect((json["orderBy"] as? [String: Any])?["direction"] as? String == "desc")
    }

    @Test("Länder ohne sichtbare Fotos fallen heraus")
    func ohneFotos() async throws {
        OrteMockURLProtocol.registriere(host: host, server())
        defer { OrteMockURLProtocol.entferne(host: host) }

        let k = try await PhoneOrtsKatalogAufbau.aufbauen(apiClient: OrteMockURLProtocol.client(host: host), vorher: nil, jetzt: jetzt)
        #expect(k.land("Austria") == nil)
    }

    @Test("Teilausfall: kein Zeitstempel, der vorige Stand des Landes bleibt")
    func teilausfallMitVorher() async throws {
        OrteMockURLProtocol.registriere(host: host, server(statistikFehlerFuer: ["Greece"]))
        defer { OrteMockURLProtocol.entferne(host: host) }

        let alt = PhoneOrtsLand(name: "Greece", anzahl: 400, zuletzt: "2025-06-01T10:00:00.000Z", titelbildId: "gr-alt", staedte: ["Chania"], regionen: [])
        let vorher = PhoneOrtsKatalog(basis: "https://\(host)", laender: [alt], aufgebautAm: jetzt.addingTimeInterval(-3600))

        let k = try await PhoneOrtsKatalogAufbau.aufbauen(apiClient: OrteMockURLProtocol.client(host: host), vorher: vorher, jetzt: jetzt)

        #expect(k.aufgebautAm == nil)
        #expect(k.land("Greece") == alt)
        #expect(k.land("Japan")?.anzahl == 12367)
    }

    @Test("Teilausfall ohne vorigen Stand: Platzhalter ohne Datum")
    func teilausfallOhneVorher() async throws {
        OrteMockURLProtocol.registriere(host: host, server(statistikFehlerFuer: ["Greece"]))
        defer { OrteMockURLProtocol.entferne(host: host) }

        let k = try await PhoneOrtsKatalogAufbau.aufbauen(apiClient: OrteMockURLProtocol.client(host: host), vorher: nil, jetzt: jetzt)

        let greece = try #require(k.land("Greece"))
        #expect(greece.zuletzt == nil)
        #expect(k.nachZuletzt.last?.name == "Greece")
    }

    @Test("Gezählte Städte überleben den Lauf")
    func staedteAnzahlenBleiben() async throws {
        OrteMockURLProtocol.registriere(host: host, server())
        defer { OrteMockURLProtocol.entferne(host: host) }

        var vorher = PhoneOrtsKatalog(basis: "https://\(host)", laender: [])
        vorher.staedteAnzahlen["Japan"] = [PhoneOrtsChip(id: "Kyoto", titel: "Kyoto", anzahl: 758)]

        let k = try await PhoneOrtsKatalogAufbau.aufbauen(apiClient: OrteMockURLProtocol.client(host: host), vorher: vorher, jetzt: jetzt)
        #expect(k.staedteAnzahlen == vorher.staedteAnzahlen)
    }

    @Test("Scheitert die Länderliste, wirft der Lauf")
    func laenderlisteScheitert() async {
        OrteMockURLProtocol.registriere(host: host, server(laenderlisteFehler: true))
        defer { OrteMockURLProtocol.entferne(host: host) }

        await #expect(throws: APIError.httpError(500)) {
            _ = try await PhoneOrtsKatalogAufbau.aufbauen(apiClient: OrteMockURLProtocol.client(host: host), vorher: nil, jetzt: jetzt)
        }
    }
}
