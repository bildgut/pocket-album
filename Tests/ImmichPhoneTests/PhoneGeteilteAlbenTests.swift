import Foundation
import Testing
@testable import ImmichPhone

/// Suche in geteilten Alben: Filterform, wann sie greift, und Orte aus fremden Fotos.
///
/// Kein Test hier setzt ``PhoneGeteilteAlben`` — die Liste ist prozessweit, und andere
/// Suiten laufen parallel mit der leeren Vorgabe. Die Album-IDs gehen ausdrücklich hinein.
@Suite("Geteilte Alben in der Suche")
struct PhoneGeteilteAlbenTests {

    private func json(_ filter: SearchFilter) throws -> [String: Any] {
        let daten = try JSONEncoder().encode(filter)
        return try #require(try JSONSerialization.jsonObject(with: daten) as? [String: Any])
    }

    // MARK: - SearchFilter.mitGeteiltenAlben

    @Test("Vereinigung: trashedAt wandert in beide Zweige, der zweite trägt die Alben")
    func filterForm() throws {
        var basis = SearchFilter.visibleLibrary(type: nil)
        basis.country = .equals("Japan")
        let f = try json(basis.mitGeteiltenAlben(["alb-1", "alb-2"]))

        // Oben bleibt, was für beide Zweige gilt — nur trashedAt nicht (ein Zweig darf nicht leer sein).
        #expect(f["trashedAt"] == nil)
        #expect((f["country"] as? [String: Any])?["eq"] as? String == "Japan")
        #expect(f["visibility"] != nil)

        let zweige = try #require(f["or"] as? [[String: Any]])
        #expect(zweige.count == 2)
        // Beide Zweige schließen den Papierkorb aus: {"eq": null}.
        for zweig in zweige {
            let papierkorb = try #require(zweig["trashedAt"] as? [String: Any])
            #expect(papierkorb["eq"] is NSNull)
        }
        #expect(zweige[0]["albumIds"] == nil)
        let alben = try #require(zweige[1]["albumIds"] as? [String: Any])
        #expect(alben["any"] as? [String] == ["alb-1", "alb-2"])
    }

    @Test("Ohne geteilte Alben bleibt der Filter unverändert")
    func ohneAlben() {
        let basis = SearchFilter.visibleLibrary(type: .image)
        #expect(basis.mitGeteiltenAlben([]) == basis)
    }

    @Test("Ein vorhandenes or wird nicht verschachtelt")
    func vorhandenesOr() {
        var basis = SearchFilter.visibleLibrary(type: nil)
        var zweig = SearchFilter()
        zweig.isFavorite = .equals(true)
        basis.or = [zweig, zweig]
        #expect(basis.mitGeteiltenAlben(["alb-1"]) == basis)
    }

    // MARK: - PhoneSuchAuswahl

    @Test("Fotos-Reiter (leere Auswahl) bleibt die eigene Zeitleiste")
    func fotosReiter() {
        let f = PhoneSuchAuswahl.leer.searchFilter(type: .image, geteilteAlben: ["alb-1"])
        #expect(f == SearchFilter.visibleLibrary(type: .image))
    }

    @Test("Jede Entdecken-Auswahl sucht auch in geteilten Alben", arguments: [
        PhoneSuchAuswahl.land("Japan"),
        PhoneSuchAuswahl.jahr(2019),
        PhoneSuchAuswahl.stadt("Tokyo", in: "Japan"),
        PhoneSuchAuswahl.leer.mitFreitext("tower"),
    ])
    func entdecken(_ auswahl: PhoneSuchAuswahl) {
        let f = auswahl.searchFilter(geteilteAlben: ["alb-1"])
        #expect(f.or?.count == 2)
        #expect(f.or?.last?.albumIds == .anyOf(["alb-1"]))
        // Ohne geteilte Alben genau der bisherige Filter.
        #expect(auswahl.searchFilter(geteilteAlben: []).or == nil)
    }

    @Test("Favoriten bleiben die eigenen — der Stern gehört dem Eigentümer des Fotos")
    func favoriten() {
        let f = PhoneSuchAuswahl.land("Japan").mitFavoriten(true).searchFilter(geteilteAlben: ["alb-1"])
        #expect(f.or == nil)
        #expect(f.isFavorite == .equals(true))
    }

    // MARK: - PhoneGeteilteOrte

    private func asset(_ id: String, land: String?, stadt: String?, region: String?) throws -> Asset {
        func feld(_ name: String, _ wert: String?) -> String {
            wert.map { #""\#(name)":"\#($0)""# } ?? #""\#(name)":null"#
        }
        let exif = "{\(feld("country", land)),\(feld("city", stadt)),\(feld("state", region))}"
        let text = OrteMockURLProtocol.assetJSON(id: id, localDateTime: "2019-05-01T10:00:00.000Z")
            .replacingOccurrences(of: #""people":[]"#, with: #""people":[],"exifInfo":\#(exif)"#)
        return try JSONDecoder().decode(Asset.self, from: Data(text.utf8))
    }

    @Test("Orte aus fremden Fotos: je Land Städte und Regionen, ohne Leere und Dubletten")
    func orteAusFotos() throws {
        let orte = PhoneGeteilteOrte.aus([
            try asset("a", land: "Japan", stadt: "Tokyo", region: "Kantō"),
            try asset("b", land: "Japan", stadt: "Kyoto", region: nil),
            try asset("c", land: "Japan", stadt: "Tokyo", region: "Kantō"),
            try asset("d", land: "Qatar", stadt: " ", region: nil),
            try asset("e", land: nil, stadt: "Nirgendwo", region: nil),
        ])
        #expect(orte.keys.sorted() == ["Japan", "Qatar"])
        #expect(orte["Japan"] == PhoneGeteilteOrte.Land(staedte: ["Kyoto", "Tokyo"], regionen: ["Kantō"]))
        #expect(orte["Qatar"] == PhoneGeteilteOrte.Land(staedte: [], regionen: []))
    }

    @Test("Eigene Namen behalten ihre Reihenfolge, neue kommen dahinter")
    func vereint() {
        #expect(PhoneGeteilteOrte.vereint(["Tokyo", "Osaka"], ["Kyoto", "Tokyo"]) == ["Tokyo", "Osaka", "Kyoto"])
    }

    // MARK: - Ortskatalog

    @Test("Alte Katalogdatei ohne geteilte Alben lässt sich lesen und gilt als passend zu keinem")
    func alterKatalog() throws {
        let alt = #"{"version":1,"basis":"https://x","laender":[],"staedteAnzahlen":{}}"#
        let k = try JSONDecoder().decode(PhoneOrtsKatalog.self, from: Data(alt.utf8))
        #expect(k.passt(zuGeteiltenAlben: []))
        #expect(!k.passt(zuGeteiltenAlben: ["alb-1"]))
    }
}

/// Ein Konto ohne eigene Orte, aber mit einem geteilten Album voller Japan-Fotos.
@Suite("Ortskatalog mit geteilten Alben", .serialized)
struct PhoneOrtsKatalogGeteiltTests {

    private let host = "orte-geteilt.test"

    private func server(_ mitschnitt: OrteMitschnitt) -> OrteMockURLProtocol.Handler {
        { request, koerper in
            mitschnitt.merke(request, koerper)
            let filter = OrteMockURLProtocol.json(koerper)["filter"] as? [String: Any] ?? [:]
            let land = (filter["country"] as? [String: Any])?["eq"] as? String
            switch request.url?.path {
            case "/api/search/suggestions":
                // Die Vorschlagsliste kennt nur die eigene Bibliothek: hier leer.
                return (200, Data("[]".utf8))
            case "/api/search/statistics":
                return (200, Data(#"{"total":\#(land == "Japan" ? 38 : 0)}"#.utf8))
            case "/api/search/metadata":
                if land == "Japan" {
                    return (200, OrteMockURLProtocol.seiteJSON([OrteMockURLProtocol.assetJSON(
                        id: "jp-neu", localDateTime: "2019-06-01T10:00:00.000Z")]))
                }
                // Der Sammellauf über die geteilten Alben (ohne Land).
                let exif = { (id: String, stadt: String) in
                    OrteMockURLProtocol.assetJSON(id: id, localDateTime: "2019-05-01T10:00:00.000Z")
                        .replacingOccurrences(of: #""people":[]"#,
                                              with: #""people":[],"exifInfo":{"country":"Japan","city":"\#(stadt)","state":"Kantō"}"#)
                }
                return (200, OrteMockURLProtocol.seiteJSON([exif("a", "Tokyo"), exif("b", "Osaka")]))
            default:
                return (404, Data())
            }
        }
    }

    @Test("Ein Land nur aus geteilten Alben erscheint mit Städten, Zahl und Titelbild")
    func landAusGeteiltemAlbum() async throws {
        let mitschnitt = OrteMitschnitt()
        OrteMockURLProtocol.registriere(host: host, server(mitschnitt))
        defer { OrteMockURLProtocol.entferne(host: host) }

        let k = try await PhoneOrtsKatalogAufbau.aufbauen(
            apiClient: OrteMockURLProtocol.client(host: host), vorher: nil,
            jetzt: Date(timeIntervalSince1970: 1_800_000_000), geteilteAlben: ["alb-1"]
        )

        let japan = try #require(k.land("Japan"))
        #expect(japan.staedte == ["Osaka", "Tokyo"])
        #expect(japan.regionen == ["Kantō"])
        #expect(japan.anzahl == 38)
        #expect(japan.titelbildId == "jp-neu")
        #expect(k.geteilteAlben == ["alb-1"])
        #expect(k.aufgebautAm != nil)

        // Der Sammellauf fragt nur die geteilten Alben ab, mit Ortsangaben.
        let sammellauf = try #require(mitschnitt.alle.first {
            $0.request.url?.path == "/api/search/metadata"
                && (OrteMockURLProtocol.json($0.koerper)["withExif"] as? Bool) == true
        })
        let filter = OrteMockURLProtocol.json(sammellauf.koerper)["filter"] as? [String: Any]
        #expect((filter?["albumIds"] as? [String: Any])?["any"] as? [String] == ["alb-1"])

        // Die Zählung des Landes vereint eigene Bibliothek und geteilte Alben.
        let zaehlung = try #require(mitschnitt.alle.first { $0.request.url?.path == "/api/search/statistics" })
        let zaehlFilter = OrteMockURLProtocol.json(zaehlung.koerper)["filter"] as? [String: Any]
        #expect((zaehlFilter?["or"] as? [Any])?.count == 2)
    }

    @Test("Scheitert der Sammellauf, gilt der Katalog als unvollständig")
    func sammellaufScheitert() async throws {
        OrteMockURLProtocol.registriere(host: host) { request, koerper in
            let json = OrteMockURLProtocol.json(koerper)
            if request.url?.path == "/api/search/metadata", json["withExif"] as? Bool == true { return (500, Data()) }
            if request.url?.path == "/api/search/suggestions" { return (200, Data(#"["Greece"]"#.utf8)) }
            if request.url?.path == "/api/search/statistics" { return (200, Data(#"{"total":3}"#.utf8)) }
            return (200, OrteMockURLProtocol.seiteJSON([OrteMockURLProtocol.assetJSON(id: "gr", localDateTime: "2020-01-01T00:00:00.000Z")]))
        }
        defer { OrteMockURLProtocol.entferne(host: host) }

        let k = try await PhoneOrtsKatalogAufbau.aufbauen(
            apiClient: OrteMockURLProtocol.client(host: host), vorher: nil, geteilteAlben: ["alb-1"]
        )
        #expect(k.land("Greece") != nil)
        #expect(k.aufgebautAm == nil)
    }
}
