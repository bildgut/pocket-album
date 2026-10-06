import Foundation
import SwiftData
import Testing
@testable import ImmichPhone

/// Befunde aus dem Review der Offline-Läufe am Telefon: Aufträge während eines
/// Laufs gehen nicht verloren, wartende Alben laden weiter, sobald WLAN kommt,
/// ein auf dem Server gelöschtes Album wird erkannt, Freigeben und Abbrechen
/// hinterlassen keine Marken.
@Suite("Offline-Lauf: nachholen, vormerken, freigeben", .serialized)
@MainActor
struct OfflineLaufNachholenTests {
    private let host = "offline-nachholen.test"

    private func assetJSON(_ id: String) -> String {
        #"{"id":"\#(id)","type":"IMAGE","originalFileName":"\#(id).x","fileCreatedAt":"2024-01-01T10:00:00.000Z","fileModifiedAt":"2024-01-01T10:00:00.000Z","isFavorite":false}"#
    }

    /// `alben`: Album-ID → Asset-IDs. Unbekannte Alben antworten wie Immich mit 400
    /// und Fehler-JSON; `listen` steuert, ob die Albenlisten antworten.
    @discardableResult
    private func server(_ alben: [String: [String]], listenOK: Bool = true,
                        verzoegerung: TimeInterval = 0) -> OrteMitschnitt {
        let mitschnitt = OrteMitschnitt()
        let antworten = alben.mapValues { ids in
            #"{"id":"x","albumName":"x","assetCount":\#(ids.count),"assets":[\#(ids.map(assetJSON).joined(separator: ","))]}"#
        }
        OrteMockURLProtocol.registriere(host: host, verzoegerung: verzoegerung) { req, body in
            let pfad = req.url?.path ?? ""
            if pfad.hasSuffix("/api/albums") {
                return listenOK ? (200, Data("[]".utf8)) : (500, Data(#"{"message":"boom","statusCode":500}"#.utf8))
            }
            if pfad.contains("/api/albums/") {
                for (id, json) in antworten where pfad.hasSuffix("/api/albums/\(id)") {
                    return (200, Data(json.utf8))
                }
                return (400, Data(#"{"message":"Not found or no album.read access","statusCode":400}"#.utf8))
            }
            mitschnitt.merke(req, body)
            return (200, Data("DATEI".utf8))
        }
        return mitschnitt
    }

    private func container(_ albumIds: [String]) throws -> ModelContainer {
        let c = try ModelContainer(
            for: Schema(versionedSchema: ImmichMacMigrationPlan.currentSchema),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        for id in albumIds { try fuegeHinzu(id, in: c) }
        return c
    }

    private func fuegeHinzu(_ album: String, in c: ModelContainer) throws {
        let ctx = ModelContext(c)
        ctx.insert(OfflinePin(kind: .album, targetId: album, displayName: album))
        try ctx.save()
    }

    private func lader(teuer: Bool?, wahlen: [String: OfflineWahl] = [:]) async -> OfflineDownloadManager {
        let m = OfflineDownloadManager(ueberwacheNetz: false)
        await m.setzeWahlQuelle { wahlen[$0] ?? OfflineWahl() }
        if let teuer { await m.updateMeteredStatus(teuer) }
        return m
    }

    private func pinId(_ album: String) -> String { OfflinePin.pinId(kind: .album, targetId: album) }

    private func pin(_ album: String, in c: ModelContainer) throws -> OfflinePin? {
        let id = pinId(album)
        return try ModelContext(c).fetch(FetchDescriptor<OfflinePin>(predicate: #Predicate { $0.pinId == id })).first
    }

    private func hatDatei(_ assetId: String, in c: ModelContainer) throws -> Bool {
        let a = try ModelContext(c).fetch(FetchDescriptor<CachedAsset>(predicate: #Predicate { $0.assetId == assetId })).first
        return LocalFileCacheManager.localFileURL(forPath: a?.localFilePath) != nil
    }

    private func warteBis(_ bedingung: () async throws -> Bool) async throws {
        for _ in 0..<200 {
            if try await bedingung() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("Bedingung nicht erreicht")
    }

    private func aufraeumen() {
        OrteMockURLProtocol.entferne(host: host)
        OfflineSyncProgress.shared.wartetAufWLAN.removeAll()
        OfflineSyncProgress.shared.freigegeben.removeAll()
    }

    // MARK: - Befund 1

    @Test func auftragWaehrendLaufWirdNachgeschoben() async throws {
        let a = "a-\(UUID().uuidString.prefix(8))", b = "b-\(UUID().uuidString.prefix(8))"
        server(["alb-a": [a], "alb-b": [b]], verzoegerung: 0.2)
        defer { aufraeumen() }
        let c = try container(["alb-a"])
        let m = await lader(teuer: false)
        let client = OrteMockURLProtocol.client(host: host)

        let erster = Task { await m.syncOfflineAlbums(container: c, apiClient: client, force: true) }
        try await warteBis { await m.laeuft }
        // Zweites Album während des Laufs — früher verworfen.
        try fuegeHinzu("alb-b", in: c)
        await m.syncOfflineAlbums(container: c, apiClient: client, force: true)
        await erster.value
        await m.warteAufEnde()

        #expect(try hatDatei(a, in: c))
        #expect(try hatDatei(b, in: c))
        #expect(await m.laeuft == false)
    }

    @Test func wlanZurueckLaedtWartendesWeiter() async throws {
        let a = "a-\(UUID().uuidString.prefix(8))"
        server(["alb-a": [a]])
        defer { aufraeumen() }
        let c = try container(["alb-a"])
        let m = await lader(teuer: true)
        let client = OrteMockURLProtocol.client(host: host)

        await m.nachholen(container: c, apiClient: client)
        try await warteBis { OfflineSyncProgress.shared.wartetAufWLAN.contains(pinId("alb-a")) }
        await m.warteAufEnde()
        #expect(try hatDatei(a, in: c) == false)

        await m.updateMeteredStatus(false)
        try await warteBis { try hatDatei(a, in: c) }
        await m.warteAufEnde()
        #expect(!OfflineSyncProgress.shared.wartetAufWLAN.contains(pinId("alb-a")))
    }

    @Test func nachholenWartetAufErstenPfadRueckruf() async throws {
        let a = "a-\(UUID().uuidString.prefix(8))"
        let mitschnitt = server(["alb-a": [a]])
        defer { aufraeumen() }
        let c = try container(["alb-a"])
        let m = await lader(teuer: nil)   // Netzlage noch unbekannt

        await m.nachholen(container: c, apiClient: OrteMockURLProtocol.client(host: host))
        try await Task.sleep(for: .milliseconds(200))
        #expect(mitschnitt.alle.isEmpty)
        #expect(await m.laeuft == false)

        await m.updateMeteredStatus(false)
        try await warteBis { try hatDatei(a, in: c) }
        await m.warteAufEnde()
    }

    @Test func unvollstaendigeVermerkeErkennen() throws {
        let c = try container(["neu", "fertig", "abgerissen"])
        let ctx = ModelContext(c)
        let alle = OfflinePinStore.allPins(in: ctx)
        #expect(OfflineDownloadManager.hatUnvollstaendigeVermerke(in: ctx))
        for p in alle { p.lastResolvedAt = Date(timeIntervalSince1970: 100); p.lastCompletedAt = Date(timeIntervalSince1970: 200) }
        try ctx.save()
        #expect(!OfflineDownloadManager.hatUnvollstaendigeVermerke(in: ctx))
        // App mitten im Laden beendet: neu aufgelöst, danach nie fertig.
        alle.first { $0.targetId == "abgerissen" }?.lastResolvedAt = Date(timeIntervalSince1970: 300)
        try ctx.save()
        #expect(OfflineDownloadManager.hatUnvollstaendigeVermerke(in: ctx))
    }

    // MARK: - Befund 3 / 5

    @Test func abbrechenUndWartenStehtDanach() async throws {
        let ids = (0..<8).map { "z\($0)-\(UUID().uuidString.prefix(6))" }
        let mitschnitt = server(["alb-a": ids], verzoegerung: 0.15)
        defer { aufraeumen() }
        let c = try container(["alb-a"])
        let m = await lader(teuer: false)

        let lauf = Task { await m.syncOfflineAlbums(container: c, apiClient: OrteMockURLProtocol.client(host: host), force: true) }
        try await warteBis { !mitschnitt.alle.isEmpty }
        await m.abbrechenUndWarten()
        #expect(await m.laeuft == false)
        let danach = mitschnitt.alle.count
        await lauf.value
        #expect(danach < ids.count)
        #expect(mitschnitt.alle.count == danach)
        // Abbruch ist weder Fehler noch „fertig“.
        #expect(try pin("alb-a", in: c)?.lastError == nil)
        #expect(try pin("alb-a", in: c)?.lastCompletedAt == nil)
    }

    @Test func freigebenImLaufStopptDiesesAlbum() async throws {
        let ids = (0..<8).map { "f\($0)-\(UUID().uuidString.prefix(6))" }
        let mitschnitt = server(["alb-a": ids], verzoegerung: 0.15)
        defer { aufraeumen() }
        let c = try container(["alb-a"])
        let m = await lader(teuer: false)

        let lauf = Task { await m.syncOfflineAlbums(container: c, apiClient: OrteMockURLProtocol.client(host: host), force: true) }
        try await warteBis { !mitschnitt.alle.isEmpty }
        let ctx = ModelContext(c)
        OfflinePinStore.unpin(kind: .album, targetId: "alb-a", in: ctx)
        try ctx.save()
        await m.verwirf(pinId: pinId("alb-a"))
        await lauf.value

        #expect(mitschnitt.alle.count < ids.count)
        #expect(try pin("alb-a", in: c) == nil)
    }

    @Test func freigegebenesAlbumBekommtKeineWlanMarke() async throws {
        server(["alb-a": ["x-\(UUID().uuidString.prefix(6))"]])
        defer { aufraeumen() }
        let c = try container(["alb-a"])
        let m = await lader(teuer: true)
        OfflineSyncProgress.shared.markiereFreigegeben(pinId("alb-a"))

        await m.syncOfflineAlbums(container: c, apiClient: OrteMockURLProtocol.client(host: host), force: true)
        #expect(!OfflineSyncProgress.shared.wartetAufWLAN.contains(pinId("alb-a")))

        OfflineSyncProgress.shared.markiereGepinnt(pinId("alb-a"))
        await m.syncOfflineAlbums(container: c, apiClient: OrteMockURLProtocol.client(host: host), force: true)
        #expect(OfflineSyncProgress.shared.wartetAufWLAN.contains(pinId("alb-a")))
    }

    @Test func abbruchEntferntMarkenNichtErreichterAlben() async throws {
        let ids = (0..<6).map { "m\($0)-\(UUID().uuidString.prefix(6))" }
        let mitschnitt = server(["alb-a": ids, "alb-b": ["b-\(UUID().uuidString.prefix(6))"]], verzoegerung: 0.15)
        defer { aufraeumen() }
        let c = try container(["alb-a", "alb-b"])
        // A darf über Mobilfunk und lädt langsam, B wartet auf WLAN (Marke von früher).
        let m = await lader(teuer: true, wahlen: [pinId("alb-a"): OfflineWahl(fotos: .vorschau, videos: .klein, mobilfunk: true)])
        OfflineSyncProgress.shared.wartetAufWLAN.insert(pinId("alb-b"))

        let lauf = Task { await m.syncOfflineAlbums(container: c, apiClient: OrteMockURLProtocol.client(host: host), force: true) }
        try await warteBis { !mitschnitt.alle.isEmpty }
        await m.abbrechenUndWarten()
        await lauf.value
        #expect(!OfflineSyncProgress.shared.wartetAufWLAN.contains(pinId("alb-b")))
    }

    // MARK: - Befund 4

    @Test func geloeschtesAlbumWirdErkannt() async throws {
        let mitschnitt = server([:])
        defer { aufraeumen() }
        let c = try container(["weg"])
        let m = await lader(teuer: false)

        await m.syncOfflineAlbums(container: c, apiClient: OrteMockURLProtocol.client(host: host), force: true)

        #expect(try pin("weg", in: c)?.lastError == OfflineDownloadManager.albumWegText)
        #expect(mitschnitt.alle.isEmpty)
    }

    @Test func netzfehlerIstNichtGeloescht() async throws {
        server([:], listenOK: false)
        defer { aufraeumen() }
        let c = try container(["vielleicht"])
        let m = await lader(teuer: false)

        await m.syncOfflineAlbums(container: c, apiClient: OrteMockURLProtocol.client(host: host), force: true)

        let fehler = try pin("vielleicht", in: c)?.lastError
        #expect(fehler != nil)
        #expect(fehler != OfflineDownloadManager.albumWegText)
    }

    // MARK: - Befund 6

    @Test func fortschrittIstEnglischInEnglischerOberflaeche() {
        let p = OfflineSyncProgress.shared
        guard !p.isActive else { return }   // ein echter Lauf — nicht stören
        defer { p.isActive = false; p.total = 0; p.completed = 0; p.failed = 0; p.currentPinName = "" }
        p.isActive = true
        #expect(p.labelText == "Preparing…")
        p.total = 36; p.completed = 2; p.currentPinName = "Urlaub"; p.failed = 1
        #expect(p.labelText == "2/36 files · Urlaub · 1 failed")
        #expect(OfflineDownloadManager.downloadFehlerText(fehler: 3, von: 36) == "3 of 36 files couldn't be downloaded.")
    }
}
