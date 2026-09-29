import Foundation
import Testing
@testable import ImmichPhone

/// Zweite Nachstellung des Gerätebefunds vom 13.09.2026 (Chip gewählt, Raster zeigt
/// weiter die jüngsten Japan-Fotos): diesmal mit Wartezeiten wie am Gerät und mit
/// den Abläufen, die dort nebeneinander laufen — Katalogaufbau im Hintergrund,
/// erste Land-Seite noch unterwegs, Nachladen beim Scrollen.
///
/// Der Server antwortet je nach Filter mit anderen Fotos, jede Anfrage verzögert.
/// Nur Land: `jp-neu` mit Folgeseite `jp-alt`. Jahr 2023: `jp-2023`.
private func verzoegerterServer(mitschnitt: OrteMitschnitt) -> OrteMockURLProtocol.Handler {
    { request, koerper in
        mitschnitt.merke(request, koerper)
        switch request.url?.path {
        case "/api/search/suggestions":
            Thread.sleep(forTimeInterval: 0.3)
            return OrteMockURLProtocol.query(request, "type") == "country"
                ? (200, Data(#"["Japan"]"#.utf8))
                : (200, Data(#"["Kyoto"]"#.utf8))
        case "/api/search/statistics":
            Thread.sleep(forTimeInterval: 0.05)
            return (200, Data(#"{"total":5}"#.utf8))
        case "/api/search/metadata":
            Thread.sleep(forTimeInterval: 0.3)
            let json = OrteMockURLProtocol.json(koerper)
            let filter = json["filter"] as? [String: Any] ?? [:]
            if let jahr = (filter["takenAt"] as? [String: Any])?["gte"] as? String, jahr.hasPrefix("2023") {
                return (200, OrteMockURLProtocol.seiteJSON([OrteMockURLProtocol.assetJSON(id: "jp-2023", localDateTime: "2023-05-02T10:00:00.000Z")]))
            }
            if json["cursor"] as? String == "c1" {
                return (200, OrteMockURLProtocol.seiteJSON([OrteMockURLProtocol.assetJSON(id: "jp-alt", localDateTime: "2024-01-02T10:00:00.000Z")]))
            }
            return (200, OrteMockURLProtocol.seiteJSON([OrteMockURLProtocol.assetJSON(id: "jp-neu", localDateTime: "2025-11-24T08:10:23.000Z")], nextCursor: "c1"))
        default:
            return (404, Data())
        }
    }
}

@Suite("Orte: Chips verengen das Raster auch unter Nebenläufigkeit", .serialized)
@MainActor
struct PhoneOrtsChipFilterNebenlaeufigTests {

    private let host = "orte-chipfilter-nebenlaeufig.test"
    private let jahr2023 = PhoneOrtsChip(id: "2023", titel: "2023", anzahl: 1)

    private func modell(katalogAlter: TimeInterval) throws -> PhoneOrtsModell {
        let ordner = FileManager.default.temporaryDirectory.appending(path: "orte-chipfilter-nl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true)
        let speicher = PhoneOrtsKatalogSpeicher(datei: ordner.appending(path: "orte_katalog.json"))
        try speicher.speichern(PhoneOrtsKatalog(
            basis: "https://\(host)",
            laender: [PhoneOrtsLand(name: "Japan", anzahl: 5, zuletzt: "2025-11-24T08:10:23.000Z", titelbildId: "jp-neu", staedte: ["Kyoto"], regionen: [])],
            aufgebautAm: Date().addingTimeInterval(-katalogAlter)
        ))
        return PhoneOrtsModell(speicher: speicher)
    }

    /// Wartet höchstens 8 s darauf, dass `bedingung` wahr wird.
    private func warteBis(_ bedingung: () -> Bool) async {
        for _ in 0..<400 where !bedingung() {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func metadataAnfragen(_ mitschnitt: OrteMitschnitt) -> Int {
        mitschnitt.alle.filter { $0.request.url?.path == "/api/search/metadata" }.count
    }

    @Test("Chip während eines Katalogaufbaus im Hintergrund")
    func chipWaehrendKatalogaufbau() async throws {
        let mitschnitt = OrteMitschnitt()
        OrteMockURLProtocol.registriere(host: host, verzoegerterServer(mitschnitt: mitschnitt))
        defer { OrteMockURLProtocol.entferne(host: host) }
        let client = OrteMockURLProtocol.client(host: host)
        let modell = try modell(katalogAlter: 3600)

        // Wie `.task(id:)` der Ansicht: `erscheint` startet einen Aufbau, weil der
        // Katalog älter als 15 Minuten ist — die Ansicht wartet darauf nicht.
        let erscheinen = Task { await modell.erscheint(apiClient: client, offline: false) }
        await warteBis { modell.baut }

        await modell.waehle(.land("Japan"), apiClient: client)
        await modell.tippeJahr(jahr2023, apiClient: client)
        await erscheinen.value
        await warteBis { !modell.baut && !modell.feed.laedt }

        #expect(modell.auswahl.jahr == 2023)
        #expect(modell.feed.auswahl.jahr == 2023)
        #expect(modell.feed.eintraege.map(\.id) == ["jp-2023"])
    }

    @Test("Chip, während die erste Land-Seite noch lädt")
    func chipWaehrendErsterSeite() async throws {
        let mitschnitt = OrteMitschnitt()
        OrteMockURLProtocol.registriere(host: host, verzoegerterServer(mitschnitt: mitschnitt))
        defer { OrteMockURLProtocol.entferne(host: host) }
        let client = OrteMockURLProtocol.client(host: host)
        let modell = try modell(katalogAlter: 0)
        await modell.erscheint(apiClient: client, offline: false)

        let land = Task { await modell.waehle(.land("Japan"), apiClient: client) }
        await warteBis { modell.feed.laedt }
        await modell.tippeJahr(jahr2023, apiClient: client)
        await land.value
        await warteBis { !modell.feed.laedt }

        #expect(modell.feed.auswahl.jahr == 2023)
        #expect(modell.feed.eintraege.map(\.id) == ["jp-2023"])
    }

    @Test("Chip, während das Raster weitere Land-Seiten nachlädt")
    func chipWaehrendNachladen() async throws {
        let mitschnitt = OrteMitschnitt()
        OrteMockURLProtocol.registriere(host: host, verzoegerterServer(mitschnitt: mitschnitt))
        defer { OrteMockURLProtocol.entferne(host: host) }
        let client = OrteMockURLProtocol.client(host: host)
        let modell = try modell(katalogAlter: 0)
        await modell.erscheint(apiClient: client, offline: false)

        await modell.waehle(.land("Japan"), apiClient: client)
        #expect(modell.feed.eintraege.map(\.id) == ["jp-neu"])

        // Wie `.onAppear` einer Kachel am Rasterende.
        let vorher = metadataAnfragen(mitschnitt)
        let nachladen = Task { await modell.feed.ladeWeitere(apiClient: client) }
        await warteBis { metadataAnfragen(mitschnitt) > vorher }
        await modell.tippeJahr(jahr2023, apiClient: client)
        await nachladen.value
        await warteBis { !modell.feed.laedt }

        #expect(modell.feed.auswahl.jahr == 2023)
        #expect(modell.feed.eintraege.map(\.id) == ["jp-2023"])
    }
}
