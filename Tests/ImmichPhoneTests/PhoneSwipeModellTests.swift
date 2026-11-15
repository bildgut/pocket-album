import Foundation
import SwiftData
import Testing
@testable import ImmichPhone

@Suite("PhoneSwipeModus & Rechte")
struct PhoneSwipeModusTests {

    @Test func nurLeseKeyBlendetAlleModiUndEinstiegAus() {
        let rechte = KeyRechte(gemeldet: ["asset.read", "asset.view"])
        #expect(PhoneSwipeModus.verfuegbareModi(rechte: rechte).isEmpty)
        #expect(!PhoneSwipeModus.istEinstiegSichtbar(rechte: rechte, istOffline: false))
    }

    @Test func nurFavoritRechtBietetNurFavoritenAn() {
        let rechte = KeyRechte(gemeldet: [KeyRechte.favorit])
        #expect(PhoneSwipeModus.verfuegbareModi(rechte: rechte) == [.favoriten])
        #expect(PhoneSwipeModus.istEinstiegSichtbar(rechte: rechte, istOffline: false))
        #expect(!PhoneSwipeModus.istEinstiegSichtbar(rechte: rechte, istOffline: true))
    }

    @Test func nurLoeschRechtBietetNurAussortierenAn() {
        let rechte = KeyRechte(gemeldet: [KeyRechte.loeschen])
        #expect(PhoneSwipeModus.verfuegbareModi(rechte: rechte) == [.aussortieren])
        #expect(PhoneSwipeModus.istEinstiegSichtbar(rechte: rechte, istOffline: false))
    }

    @Test func beideRechteBietenBeideModiAnUndOfflineSperrtEinstieg() {
        let rechte = KeyRechte(gemeldet: [KeyRechte.favorit, KeyRechte.loeschen])
        #expect(PhoneSwipeModus.verfuegbareModi(rechte: rechte) == [.favoriten, .aussortieren])
        #expect(PhoneSwipeModus.istEinstiegSichtbar(rechte: rechte, istOffline: false))
        #expect(!PhoneSwipeModus.istEinstiegSichtbar(rechte: rechte, istOffline: true))
    }
}

@Suite("PhoneSwipe – Suchfilter")
@MainActor
struct PhoneSwipeFilterTests {

    @Test func filterNimmt30TageUndNurStandbilder() throws {
        var kalender = Calendar(identifier: .gregorian)
        kalender.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let jetzt = ISO8601DateFormatter().date(from: "2026-11-14T12:00:00Z")!
        let erwartetBeginn = try #require(ZuletztOffline.beginn(tage: 30, jetzt: jetzt, kalender: kalender))

        let favFilter = try #require(PhoneSwipeModell.suchFilter(modus: .favoriten, jetzt: jetzt, kalender: kalender))
        #expect(favFilter.type == .equals(.image))
        #expect(favFilter.isFavorite == .equals(false))
        #expect(favFilter.takenAt == .onOrAfter(erwartetBeginn))
        #expect(favFilter.trashedAt == .isNull)
        #expect(favFilter.visibility == .oneOf([.timeline]))

        let loeschFilter = try #require(PhoneSwipeModell.suchFilter(modus: .aussortieren, jetzt: jetzt, kalender: kalender))
        #expect(loeschFilter.type == .equals(.image))
        #expect(loeschFilter.isFavorite == nil)
        #expect(loeschFilter.takenAt == .onOrAfter(erwartetBeginn))
    }
}

@Suite("PhoneSwipeGesehenSpeicher")
struct PhoneSwipeGesehenSpeicherTests {

    private func frischerSpeicher() -> (PhoneSwipeGesehenSpeicher, UserDefaults) {
        let suite = "swipe-speicher-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (PhoneSwipeGesehenSpeicher(defaults: defaults), defaults)
    }

    @Test func merktEntferntUndSetztZurueckJeServerUndModus() {
        let (speicher, _) = frischerSpeicher()
        let serverA = URL(string: "https://a.example")!
        let serverB = URL(string: "https://b.example")!
        let jetzt = Date(timeIntervalSince1970: 1_700_000_000)

        speicher.merke(assetId: "1", basis: serverA, modus: .favoriten, jetzt: jetzt)
        speicher.merke(assetId: "2", basis: serverA, modus: .favoriten, jetzt: jetzt)
        speicher.merke(assetId: "3", basis: serverA, modus: .aussortieren, jetzt: jetzt)
        speicher.merke(assetId: "4", basis: serverB, modus: .favoriten, jetzt: jetzt)

        #expect(speicher.geseheneIds(basis: serverA, modus: .favoriten, jetzt: jetzt) == ["1", "2"])
        #expect(speicher.geseheneIds(basis: serverA, modus: .aussortieren, jetzt: jetzt) == ["3"])
        #expect(speicher.geseheneIds(basis: serverB, modus: .favoriten, jetzt: jetzt) == ["4"])

        speicher.entferne(assetId: "1", basis: serverA, modus: .favoriten)
        #expect(speicher.geseheneIds(basis: serverA, modus: .favoriten, jetzt: jetzt) == ["2"])

        speicher.zuruecksetzen(basis: serverA, modus: .favoriten)
        #expect(speicher.geseheneIds(basis: serverA, modus: .favoriten, jetzt: jetzt).isEmpty)
        #expect(speicher.geseheneIds(basis: serverA, modus: .aussortieren, jetzt: jetzt) == ["3"])
    }

    @Test func eintraegeAelterAls35TageVerfallen() {
        let (speicher, _) = frischerSpeicher()
        let server = URL(string: "https://a.example")!
        let alt = Date(timeIntervalSince1970: 1_700_000_000)
        let spaeter = alt.addingTimeInterval(36 * 86_400)

        speicher.merke(assetId: "alt", basis: server, modus: .favoriten, jetzt: alt)
        speicher.merke(assetId: "neu", basis: server, modus: .favoriten, jetzt: spaeter.addingTimeInterval(-10 * 86_400))

        #expect(speicher.geseheneIds(basis: server, modus: .favoriten, jetzt: spaeter) == ["neu"])
    }
}

@Suite("PhoneSwipeModell – Laden, Wischen, Undo & Papierkorb", .serialized)
@MainActor
struct PhoneSwipeModellLaufTests {

    private func assetJSON(
        id: String,
        type: String = "IMAGE",
        isFavorite: Bool = false,
        isArchived: Bool = false,
        isTrashed: Bool = false,
        visibility: String = "timeline",
        city: String? = "Hamburg",
        stackId: String? = nil,
        stackPrimaryAssetId: String? = nil,
        stackCount: Int = 2
    ) -> String {
        let exif = city.map { #","exifInfo":{"city":"\#($0)"}"# } ?? ""
        let stack = stackId.map { idWert in
            let primaryFeld = stackPrimaryAssetId.map { #","primaryAssetId":"\#($0)""# } ?? ""
            return #","stack":{"id":"\#(idWert)","assetCount":\#(stackCount)\#(primaryFeld)}"#
        } ?? ""
        return #"{"id":"\#(id)","type":"\#(type)","originalFileName":"\#(id).jpg","fileCreatedAt":"2026-11-10T10:00:00.000Z","fileModifiedAt":"2026-11-10T10:00:00.000Z","localDateTime":"2026-11-10T11:00:00.000Z","isFavorite":\#(isFavorite),"isArchived":\#(isArchived),"isTrashed":\#(isTrashed),"visibility":"\#(visibility)"\#(exif)\#(stack)}"#
    }

    private func containerMitAssets(_ ids: [String]) throws -> ModelContainer {
        let container = try ModelContainer(
            for: Schema(versionedSchema: ImmichMacMigrationPlan.currentSchema),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let ctx = ModelContext(container)
        let decoder = JSONDecoder()
        for id in ids {
            let asset = try decoder.decode(Asset.self, from: Data(assetJSON(id: id).utf8))
            ctx.insert(CachedAsset(from: asset))
        }
        try ctx.save()
        return container
    }

    private func frischerSpeicher() -> PhoneSwipeGesehenSpeicher {
        PhoneSwipeGesehenSpeicher(defaults: UserDefaults(suiteName: "swipe-modell-\(UUID().uuidString)")!)
    }

    @Test func ladenFiltertVideosPapierkorbArchivHiddenFavoritenUndGesehene() async throws {
        let host = "swipe-laden-\(UUID().uuidString.prefix(8)).test"
        let speicher = frischerSpeicher()
        let client = OrteMockURLProtocol.client(host: host)
        speicher.merke(assetId: "schon-gesehen", basis: client.baseURL, modus: .favoriten)

        let seite1 = OrteMockURLProtocol.seiteJSON([
            assetJSON(id: "foto-1"),
            assetJSON(id: "video-1", type: "VIDEO"),
            assetJSON(id: "trash-1", isTrashed: true),
            assetJSON(id: "archiv-1", isArchived: true),
            assetJSON(id: "hidden-1", visibility: "hidden"),
            assetJSON(id: "fav-1", isFavorite: true),
            assetJSON(id: "schon-gesehen")
        ], nextCursor: "c2")
        let seite2 = OrteMockURLProtocol.seiteJSON([
            assetJSON(id: "foto-2", city: nil)
        ], nextCursor: nil)

        OrteMockURLProtocol.registriere(host: host) { req, body in
            let text = String(decoding: body, as: UTF8.self)
            return (200, text.contains(#""cursor":"c2""#) ? seite2 : seite1)
        }
        defer { OrteMockURLProtocol.entferne(host: host) }

        let modell = PhoneSwipeModell(gesehenSpeicher: speicher)
        await modell.lade(apiClient: client)

        #expect(modell.hatGeladen)
        #expect(modell.fehler == nil)
        #expect(modell.gesamtImZeitraum == 3)
        #expect(modell.stapel.map(\.id) == ["foto-1", "foto-2"])
        #expect(modell.stapel.first?.stadt == "Hamburg")
        #expect(modell.stapel.last?.stadt == nil)
    }

    @Test func favoritRechtswischUndUndoSendenPassendeAPIUndMeldung() async throws {
        let host = "swipe-fav-\(UUID().uuidString.prefix(8)).test"
        let speicher = frischerSpeicher()
        let client = OrteMockURLProtocol.client(host: host)
        let mitschnitt = OrteMitschnitt()
        let seite = OrteMockURLProtocol.seiteJSON([assetJSON(id: "a1"), assetJSON(id: "a2")])

        OrteMockURLProtocol.registriere(host: host) { req, body in
            mitschnitt.merke(req, body)
            if req.url?.path.hasSuffix("/api/search/metadata") == true {
                return (200, seite)
            }
            return (200, Data("{}".utf8))
        }
        defer { OrteMockURLProtocol.entferne(host: host) }

        let container = try containerMitAssets(["a1", "a2"])
        let context = ModelContext(container)

        var meldungen: [(String, Bool)] = []
        let beobachter = NotificationCenter.default.addObserver(
            forName: PhoneFavoritMeldung.name,
            object: nil,
            queue: .main
        ) { note in
            if let paar = PhoneFavoritMeldung.lies(note) {
                meldungen.append(paar)
            }
        }
        defer { NotificationCenter.default.removeObserver(beobachter) }

        let modell = PhoneSwipeModell(gesehenSpeicher: speicher)
        await modell.lade(apiClient: client)

        await modell.wische(.rechts, apiClient: client, context: context)?.value

        #expect(modell.stapel.map(\.id) == ["a2"])
        #expect(modell.verlauf.count == 1)
        #expect(speicher.geseheneIds(basis: client.baseURL, modus: .favoriten) == ["a1"])
        #expect(meldungen.last?.0 == "a1" && meldungen.last?.1 == true)

        let cached1 = try #require(try context.fetch(FetchDescriptor<CachedAsset>()).first { $0.assetId == "a1" })
        #expect(cached1.isFavorite == true)

        let putAufrufe = mitschnitt.alle.filter { $0.request.httpMethod == "PUT" }
        #expect(putAufrufe.count == 1)
        #expect(putAufrufe.first?.request.url?.path == "/api/assets/a1")
        #expect(OrteMockURLProtocol.json(putAufrufe[0].koerper)["isFavorite"] as? Bool == true)

        await modell.rueckgaengig(apiClient: client, context: context)?.value

        #expect(modell.stapel.map(\.id) == ["a1", "a2"])
        #expect(modell.verlauf.isEmpty)
        #expect(speicher.geseheneIds(basis: client.baseURL, modus: .favoriten).isEmpty)
        #expect(meldungen.last?.0 == "a1" && meldungen.last?.1 == false)
        #expect(cached1.isFavorite == false)

        let putNachUndo = mitschnitt.alle.filter { $0.request.httpMethod == "PUT" }
        #expect(putNachUndo.count == 2)
        #expect(OrteMockURLProtocol.json(putNachUndo[1].koerper)["isFavorite"] as? Bool == false)
    }

    @Test func aussortierenKorbUndoVormerkungUndSammelPapierkorb() async throws {
        let host = "swipe-korb-\(UUID().uuidString.prefix(8)).test"
        let speicher = frischerSpeicher()
        let client = OrteMockURLProtocol.client(host: host)
        let mitschnitt = OrteMitschnitt()
        let seite = OrteMockURLProtocol.seiteJSON([
            assetJSON(id: "k1"),
            assetJSON(id: "k2"),
            assetJSON(id: "k3")
        ])

        OrteMockURLProtocol.registriere(host: host) { req, body in
            mitschnitt.merke(req, body)
            if req.url?.path.hasSuffix("/api/search/metadata") == true {
                return (200, seite)
            }
            return (204, Data())
        }
        defer { OrteMockURLProtocol.entferne(host: host) }

        let container = try containerMitAssets(["k1", "k2", "k3"])
        let context = ModelContext(container)

        let modell = PhoneSwipeModell(gesehenSpeicher: speicher)
        await modell.wechseleModus(.aussortieren, apiClient: client)
        #expect(modell.stapel.map(\.id) == ["k1", "k2", "k3"])

        modell.wische(.links, apiClient: client, context: context)
        modell.wische(.links, apiClient: client, context: context)
        modell.wische(.links, apiClient: client, context: context)

        #expect(modell.vorgemerkteKarten.map(\.id) == ["k1", "k2", "k3"])
        #expect(mitschnitt.alle.filter { $0.request.httpMethod == "DELETE" }.isEmpty)

        // Undo holt k3 zurück und entfernt es wieder aus dem Korb
        modell.rueckgaengig(apiClient: client, context: context)
        #expect(modell.stapel.map(\.id) == ["k3"])
        #expect(modell.vorgemerkteKarten.map(\.id) == ["k1", "k2"])

        // k3 behalten, k1 manuell aus dem Korb heben
        modell.wische(.rechts, apiClient: client, context: context)
        modell.hebeVormerkungAuf(assetId: "k1")
        #expect(modell.vorgemerkteKarten.map(\.id) == ["k2"])

        // Moduswechsel behält Korb und filtert vorgemerkte IDs heraus
        await modell.wechseleModus(.favoriten, apiClient: client)
        #expect(modell.vorgemerkteKarten.map(\.id) == ["k2"])
        #expect(modell.stapel.map(\.id) == ["k1", "k3"])

        var geloeschteCallback: [String] = []
        let erfolg = await modell.leereInPapierkorb(
            apiClient: client,
            context: context,
            onGeloescht: { geloeschteCallback = $0 }
        )

        #expect(erfolg)
        #expect(modell.vorgemerkteKarten.isEmpty)
        #expect(geloeschteCallback == ["k2"])

        let deleteAufrufe = mitschnitt.alle.filter { $0.request.httpMethod == "DELETE" }
        #expect(deleteAufrufe.count == 1)
        #expect(deleteAufrufe[0].request.url?.path == "/api/assets")
        let body = OrteMockURLProtocol.json(deleteAufrufe[0].koerper)
        #expect(body["ids"] as? [String] == ["k2"])
        #expect(body["force"] as? Bool == false)

        let cached2 = try #require(try context.fetch(FetchDescriptor<CachedAsset>()).first { $0.assetId == "k2" })
        #expect(cached2.isTrashed == true)
    }

    @Test func korb403MeldetFehlendesRechtUndBehaeltVormerkung() async throws {
        let host = "swipe-403-\(UUID().uuidString.prefix(8)).test"
        let speicher = frischerSpeicher()
        let client = OrteMockURLProtocol.client(host: host)
        let seite = OrteMockURLProtocol.seiteJSON([assetJSON(id: "x1")])

        OrteMockURLProtocol.registriere(host: host) { req, _ in
            if req.url?.path.hasSuffix("/api/search/metadata") == true {
                return (200, seite)
            }
            return (403, Data())
        }
        defer { OrteMockURLProtocol.entferne(host: host) }

        let modell = PhoneSwipeModell(gesehenSpeicher: speicher)
        await modell.wechseleModus(.aussortieren, apiClient: client)
        modell.wische(.links, apiClient: client)
        #expect(modell.vorgemerkteKarten.map(\.id) == ["x1"])

        var abgelehntesRecht: String?
        let erfolg = await modell.leereInPapierkorb(
            apiClient: client,
            onRechtAbgelehnt: { abgelehntesRecht = $0 }
        )

        #expect(!erfolg)
        #expect(abgelehntesRecht == KeyRechte.loeschen)
        #expect(modell.fehler == PhoneSwipeTexts.rechtFehlt)
        #expect(modell.vorgemerkteKarten.map(\.id) == ["x1"])
    }

    @Test func nochmalsDurchsehenLeertGesehenSpeicherUndLaedtNeu() async throws {
        let host = "swipe-nochmal-\(UUID().uuidString.prefix(8)).test"
        let speicher = frischerSpeicher()
        let client = OrteMockURLProtocol.client(host: host)
        let seite = OrteMockURLProtocol.seiteJSON([assetJSON(id: "n1")])

        OrteMockURLProtocol.registriere(host: host) { _, _ in (200, seite) }
        defer { OrteMockURLProtocol.entferne(host: host) }

        let modell = PhoneSwipeModell(gesehenSpeicher: speicher)
        await modell.lade(apiClient: client)
        modell.wische(.links, apiClient: client)
        #expect(modell.stapel.isEmpty)

        await modell.nochmalsDurchsehen(apiClient: client)
        #expect(modell.stapel.map(\.id) == ["n1"])
        #expect(speicher.geseheneIds(basis: client.baseURL, modus: .favoriten).isEmpty)
    }

    nonisolated private func timelineBucketAntwort(
        url: URL,
        novemberMitStack: Data,
        novemberOhneStack: Data
    ) -> (Int, Data) {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let timeBucket = query.first { $0.name == "timeBucket" }?.value
        let withStacked = query.first { $0.name == "withStacked" }?.value == "true"
        if timeBucket == "2026-11-01" {
            return (200, withStacked ? novemberMitStack : novemberOhneStack)
        }
        return (200, Data(#"{"id":[]}"#.utf8))
    }

    @Test func ladenFiltertStapelKinderUeberAssetStackUndTimelineBucket() async throws {
        let host = "swipe-stack-filter-\(UUID().uuidString.prefix(8)).test"
        let speicher = frischerSpeicher()
        let client = OrteMockURLProtocol.client(host: host)
        let jetzt = ISO8601DateFormatter().date(from: "2026-11-14T12:00:00Z")!

        let seite = OrteMockURLProtocol.seiteJSON([
            assetJSON(id: "a1-jpg", stackId: "s-direkt", stackPrimaryAssetId: "a1-jpg"),
            assetJSON(id: "a1-raw", stackId: "s-direkt", stackPrimaryAssetId: "a1-jpg"),
            assetJSON(id: "b1-jpg"),
            assetJSON(id: "b1-raw"),
            assetJSON(id: "solo")
        ])
        let bucketMitStack = Data(#"{"id":["b1-jpg","solo"],"stack":[["s-bucket","2"],null]}"#.utf8)
        let bucketOhneStack = Data(#"{"id":["b1-jpg","b1-raw","solo"]}"#.utf8)

        OrteMockURLProtocol.registriere(host: host) { req, _ in
            if req.url?.path.hasSuffix("/api/search/metadata") == true {
                return (200, seite)
            }
            if let url = req.url, url.path.hasSuffix("/api/timeline/bucket") {
                return timelineBucketAntwort(url: url, novemberMitStack: bucketMitStack, novemberOhneStack: bucketOhneStack)
            }
            return (404, Data())
        }
        defer { OrteMockURLProtocol.entferne(host: host) }

        let modell = PhoneSwipeModell(gesehenSpeicher: speicher)
        await modell.lade(apiClient: client, jetzt: jetzt)

        #expect(modell.stapel.map(\.id) == ["a1-jpg", "b1-jpg", "solo"])
        #expect(modell.gesamtImZeitraum == 3)
        #expect(modell.stapel.first { $0.id == "a1-jpg" }?.istGestapelt == true)
        #expect(modell.stapel.first { $0.id == "b1-jpg" }?.istGestapelt == true)
        #expect(modell.stapel.first { $0.id == "solo" }?.istGestapelt == false)
    }

    @Test func papierkorbLoeschtBeiGestapeltemFotoAuchDieRohdateiImStapel() async throws {
        let host = "swipe-stack-delete-\(UUID().uuidString.prefix(8)).test"
        let speicher = frischerSpeicher()
        let client = OrteMockURLProtocol.client(host: host)
        let mitschnitt = OrteMitschnitt()
        let jetzt = ISO8601DateFormatter().date(from: "2026-11-14T12:00:00Z")!

        let seite = OrteMockURLProtocol.seiteJSON([
            assetJSON(id: "p1-jpg"),
            assetJSON(id: "p1-raw"),
            assetJSON(id: "solo")
        ])
        let bucketMitStack = Data(#"{"id":["p1-jpg","solo"],"stack":[["s-bucket","2"],null]}"#.utf8)
        let bucketOhneStack = Data(#"{"id":["p1-jpg","p1-raw","solo"]}"#.utf8)
        let stackJSON = Data(#"[{"id":"s-bucket","primaryAssetId":"p1-jpg","assets":[\#(assetJSON(id: "p1-jpg")),\#(assetJSON(id: "p1-raw"))]}]"#.utf8)

        OrteMockURLProtocol.registriere(host: host) { req, body in
            mitschnitt.merke(req, body)
            if req.url?.path.hasSuffix("/api/search/metadata") == true {
                return (200, seite)
            }
            if let url = req.url, url.path.hasSuffix("/api/timeline/bucket") {
                return timelineBucketAntwort(url: url, novemberMitStack: bucketMitStack, novemberOhneStack: bucketOhneStack)
            }
            if req.url?.path.hasSuffix("/api/stacks") == true {
                return (200, stackJSON)
            }
            return (204, Data())
        }
        defer { OrteMockURLProtocol.entferne(host: host) }

        let container = try containerMitAssets(["p1-jpg", "p1-raw", "solo"])
        let context = ModelContext(container)

        let modell = PhoneSwipeModell(gesehenSpeicher: speicher)
        await modell.wechseleModus(.aussortieren, apiClient: client, jetzt: jetzt)

        #expect(modell.stapel.map(\.id) == ["p1-jpg", "solo"])

        modell.wische(.links, apiClient: client, context: context)
        modell.wische(.links, apiClient: client, context: context)

        var geloeschteCallback: [String] = []
        let erfolg = await modell.leereInPapierkorb(
            apiClient: client,
            context: context,
            onGeloescht: { geloeschteCallback = $0 }
        )

        #expect(erfolg)
        #expect(geloeschteCallback == ["p1-jpg", "p1-raw", "solo"])

        let stackAufrufe = mitschnitt.alle.filter { $0.request.url?.path.hasSuffix("/api/stacks") == true }
        #expect(stackAufrufe.count == 1)
        #expect(stackAufrufe[0].request.url?.query?.contains("primaryAssetId=p1-jpg") == true)

        let deleteAufrufe = mitschnitt.alle.filter { $0.request.httpMethod == "DELETE" }
        #expect(deleteAufrufe.count == 1)
        let body = OrteMockURLProtocol.json(deleteAufrufe[0].koerper)
        #expect(body["ids"] as? [String] == ["p1-jpg", "p1-raw", "solo"])
        #expect(body["force"] as? Bool == false)

        let alleCached = try context.fetch(FetchDescriptor<CachedAsset>())
        #expect(alleCached.first { $0.assetId == "p1-jpg" }?.isTrashed == true)
        #expect(alleCached.first { $0.assetId == "p1-raw" }?.isTrashed == true)
        #expect(alleCached.first { $0.assetId == "solo" }?.isTrashed == true)
    }
}
