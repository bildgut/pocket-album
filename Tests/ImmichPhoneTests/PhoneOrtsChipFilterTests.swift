import Foundation
import Testing
@testable import ImmichPhone

/// Nachstellung des Gerätebefunds vom 13.09.2026: Japan gewählt, dann ein Chip
/// (Jahr, Stadt, Person) — das Raster zeigte weiter die jüngsten Japan-Fotos statt
/// der verengten Auswahl.
///
/// Der Server antwortet je nach Filter mit einem anderen Foto. Damit sagt die Liste
/// im Feed eindeutig, mit welchem Filter zuletzt geladen wurde.
private func filterAbhaengigerServer(mitschnitt: OrteMitschnitt) -> OrteMockURLProtocol.Handler {
    { request, koerper in
        mitschnitt.merke(request, koerper)
        switch request.url?.path {
        case "/api/search/statistics":
            return (200, Data(#"{"total":5}"#.utf8))
        case "/api/search/metadata":
            let filter = OrteMockURLProtocol.json(koerper)["filter"] as? [String: Any] ?? [:]
            let asset: String
            if let jahr = (filter["takenAt"] as? [String: Any])?["gte"] as? String, jahr.hasPrefix("2023") {
                asset = OrteMockURLProtocol.assetJSON(id: "jp-2023", localDateTime: "2023-05-02T10:00:00.000Z")
            } else if (filter["city"] as? [String: Any])?["eq"] as? String == "Kyoto" {
                asset = OrteMockURLProtocol.assetJSON(id: "jp-kyoto", localDateTime: "2019-04-02T10:00:00.000Z")
            } else if filter["personIds"] != nil {
                asset = OrteMockURLProtocol.assetJSON(id: "jp-person", localDateTime: "2017-03-01T10:00:00.000Z")
            } else {
                asset = OrteMockURLProtocol.assetJSON(id: "jp-neu", localDateTime: "2025-11-24T08:10:23.000Z")
            }
            return (200, OrteMockURLProtocol.seiteJSON([asset]))
        default:
            return (200, Data("[]".utf8))
        }
    }
}

@Suite("Orte: Chips verengen das Raster", .serialized)
@MainActor
struct PhoneOrtsChipFilterTests {

    private let host = "orte-chipfilter.test"

    private func modellMitFrischemKatalog() throws -> PhoneOrtsModell {
        let ordner = FileManager.default.temporaryDirectory.appending(path: "orte-chipfilter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true)
        let speicher = PhoneOrtsKatalogSpeicher(datei: ordner.appending(path: "orte_katalog.json"))
        try speicher.speichern(PhoneOrtsKatalog(
            basis: "https://\(host)",
            laender: [PhoneOrtsLand(name: "Japan", anzahl: 5, zuletzt: "2025-11-24T08:10:23.000Z", titelbildId: "jp-neu", staedte: ["Kyoto"], regionen: [])],
            aufgebautAm: Date()
        ))
        return PhoneOrtsModell(speicher: speicher)
    }

    private func letzteFeedFilter(_ mitschnitt: OrteMitschnitt) -> [String: Any] {
        let feedAnfragen = mitschnitt.alle.filter {
            $0.request.url?.path == "/api/search/metadata"
                && (OrteMockURLProtocol.json($0.koerper)["orderBy"] as? [String: Any])?["field"] as? String == "fileCreatedAt"
        }
        return OrteMockURLProtocol.json(feedAnfragen.last?.koerper ?? Data())["filter"] as? [String: Any] ?? [:]
    }

    @Test("Jahres-Chip lädt das Raster mit dem Jahr neu")
    func jahresChip() async throws {
        let mitschnitt = OrteMitschnitt()
        OrteMockURLProtocol.registriere(host: host, filterAbhaengigerServer(mitschnitt: mitschnitt))
        defer { OrteMockURLProtocol.entferne(host: host) }
        let client = OrteMockURLProtocol.client(host: host)
        let modell = try modellMitFrischemKatalog()
        await modell.erscheint(apiClient: client, offline: false)

        await modell.waehle(.land("Japan"), apiClient: client)
        #expect(modell.feed.eintraege.map(\.id) == ["jp-neu"])

        await modell.tippeJahr(PhoneOrtsChip(id: "2023", titel: "2023", anzahl: 1), apiClient: client)
        #expect(modell.auswahl.jahr == 2023)
        #expect(modell.feed.auswahl.jahr == 2023)
        #expect(letzteFeedFilter(mitschnitt)["takenAt"] != nil)
        #expect(modell.feed.eintraege.map(\.id) == ["jp-2023"])
    }

    @Test("Stadt-Chip lädt das Raster mit der Stadt neu")
    func stadtChip() async throws {
        let mitschnitt = OrteMitschnitt()
        OrteMockURLProtocol.registriere(host: host, filterAbhaengigerServer(mitschnitt: mitschnitt))
        defer { OrteMockURLProtocol.entferne(host: host) }
        let client = OrteMockURLProtocol.client(host: host)
        let modell = try modellMitFrischemKatalog()
        await modell.erscheint(apiClient: client, offline: false)

        await modell.waehle(.land("Japan"), apiClient: client)
        await modell.tippeStadt(PhoneOrtsChip(id: "Kyoto", titel: "Kyoto", anzahl: 1), apiClient: client)
        #expect(modell.feed.auswahl.stadt == "Kyoto")
        #expect(modell.feed.eintraege.map(\.id) == ["jp-kyoto"])
    }

    @Test("Personen-Chip lädt das Raster mit der Person neu")
    func personenChip() async throws {
        let mitschnitt = OrteMitschnitt()
        OrteMockURLProtocol.registriere(host: host, filterAbhaengigerServer(mitschnitt: mitschnitt))
        defer { OrteMockURLProtocol.entferne(host: host) }
        let client = OrteMockURLProtocol.client(host: host)
        let modell = try modellMitFrischemKatalog()
        await modell.erscheint(apiClient: client, offline: false)

        await modell.waehle(.land("Japan"), apiClient: client)
        await modell.tippePerson(PhoneOrtsChip(id: "p1", titel: "Clara", anzahl: 1), apiClient: client)
        #expect(modell.feed.auswahl.personen == ["p1"])
        #expect(modell.feed.eintraege.map(\.id) == ["jp-person"])
    }
}
