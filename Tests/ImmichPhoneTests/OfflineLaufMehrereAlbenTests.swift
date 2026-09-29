import Foundation
import SwiftData
import Testing
@testable import ImmichPhone

/// Läufe über **mehrere** Vermerke mit unterschiedlicher Wahl — Befunde aus der
/// Abschlussprüfung: Ein Album darf einem anderen das Original nicht wegnehmen,
/// „Jetzt laden“ gilt nur für das eine Album, und ein Album ohne Arbeit wird fertig,
/// auch wenn ein anderes wartet.
@Suite("Offline-Lauf: mehrere Alben", .serialized)
@MainActor
struct OfflineLaufMehrereAlbenTests {
    private let host = "offline-mehrere.test"

    private func assetJSON(_ id: String, video: Bool = false) -> String {
        #"{"id":"\#(id)","type":"\#(video ? "VIDEO" : "IMAGE")","originalFileName":"\#(id).x","fileCreatedAt":"2024-01-01T10:00:00.000Z","fileModifiedAt":"2024-01-01T10:00:00.000Z","isFavorite":false}"#
    }

    /// `alben`: Album-ID → Assets (als JSON). Zeichnet Dateianfragen auf.
    private func server(_ alben: [String: [String]]) -> OrteMitschnitt {
        let mitschnitt = OrteMitschnitt()
        let antworten = alben.mapValues { assets in
            #"{"id":"x","albumName":"x","assetCount":\#(assets.count),"assets":[\#(assets.joined(separator: ","))]}"#
        }
        OrteMockURLProtocol.registriere(host: host) { req, body in
            let pfad = req.url?.path ?? ""
            for (id, json) in antworten where pfad.hasSuffix("/api/albums/\(id)") {
                return (200, Data(json.utf8))
            }
            mitschnitt.merke(req, body)
            return (200, Data("DATEI".utf8))
        }
        return mitschnitt
    }

    /// Vermerke in dieser Reihenfolge (`pinnedAt` aufsteigend = Laufreihenfolge).
    private func container(_ albumIds: [String]) throws -> ModelContainer {
        let c = try ModelContainer(
            for: Schema(versionedSchema: ImmichMacMigrationPlan.currentSchema),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(c)
        for (i, id) in albumIds.enumerated() {
            let pin = OfflinePin(kind: .album, targetId: id, displayName: id)
            pin.pinnedAt = Date(timeIntervalSince1970: TimeInterval(1_000 + i))
            ctx.insert(pin)
        }
        try ctx.save()
        return c
    }

    private func lader(_ wahlen: [String: OfflineWahl], teuer: Bool) async -> OfflineDownloadManager {
        let m = OfflineDownloadManager(ueberwacheNetz: false)
        await m.setzeWahlQuelle { pinId in wahlen[pinId] }
        await m.updateMeteredStatus(teuer)
        return m
    }

    private func pinId(_ album: String) -> String { OfflinePin.pinId(kind: .album, targetId: album) }

    private func pin(_ album: String, in c: ModelContainer) throws -> OfflinePin {
        let id = pinId(album)
        return try #require(try ModelContext(c).fetch(FetchDescriptor<OfflinePin>(predicate: #Predicate { $0.pinId == id })).first)
    }

    private func pfad(_ assetId: String, in c: ModelContainer) throws -> String {
        try #require(try ModelContext(c).fetch(FetchDescriptor<CachedAsset>(predicate: #Predicate { $0.assetId == assetId })).first?.localFilePath)
    }

    @Test(arguments: [true, false])
    func originalWirdNieDurchVorschauErsetzt(originalAlbumZuerst: Bool) async throws {
        let x = "x-\(UUID().uuidString.prefix(8))"
        _ = server(["orig": [assetJSON(x)], "vor": [assetJSON(x)]])
        defer { OrteMockURLProtocol.entferne(host: host) }
        let c = try container(originalAlbumZuerst ? ["orig", "vor"] : ["vor", "orig"])
        let m = await lader([
            pinId("orig"): OfflineWahl(fotos: .original, videos: .klein, mobilfunk: false),
            pinId("vor"): OfflineWahl(),
        ], teuer: false)

        await m.syncOfflineAlbums(container: c, apiClient: OrteMockURLProtocol.client(host: host), force: true)

        let gespeichert = try pfad(x, in: c)
        #expect(OfflineFassung.aus(pfad: gespeichert) == .original)
        #expect(LocalFileCacheManager.localFileURL(forPath: gespeichert) != nil)
    }

    @Test func jetztLadenGibtNurDiesesAlbumFuerMobilfunkFrei() async throws {
        let a = "a-\(UUID().uuidString.prefix(8))", b = "b-\(UUID().uuidString.prefix(8))"
        let mitschnitt = server(["alb-a": [assetJSON(a)], "alb-b": [assetJSON(b)]])
        defer { OrteMockURLProtocol.entferne(host: host); OfflineSyncProgress.shared.wartetAufWLAN.removeAll() }
        let c = try container(["alb-a", "alb-b"])
        let m = await lader([pinId("alb-a"): OfflineWahl(), pinId("alb-b"): OfflineWahl()], teuer: true)

        await m.syncOfflineAlbums(container: c, apiClient: OrteMockURLProtocol.client(host: host),
                                  force: true, mobilfunkFreigabe: [pinId("alb-a")])

        let pfade = mitschnitt.alle.compactMap { $0.request.url?.path }
        #expect(pfade.count == 1)
        #expect(pfade.first?.contains(a) == true)
        #expect(OfflineSyncProgress.shared.wartetAufWLAN == [pinId("alb-b")])
    }

    @Test func albumOhneArbeitWirdFertigAuchWennEinAnderesWartet() async throws {
        let f = "f-\(UUID().uuidString.prefix(8))", v = "v-\(UUID().uuidString.prefix(8))"
        _ = server(["wartet": [assetJSON(f)], "nurvideo": [assetJSON(v, video: true)]])
        defer { OrteMockURLProtocol.entferne(host: host); OfflineSyncProgress.shared.wartetAufWLAN.removeAll() }
        let c = try container(["wartet", "nurvideo"])
        let m = await lader([
            pinId("wartet"): OfflineWahl(),
            pinId("nurvideo"): OfflineWahl(fotos: .vorschau, videos: .keine, mobilfunk: false),
        ], teuer: true)

        await m.syncOfflineAlbums(container: c, apiClient: OrteMockURLProtocol.client(host: host), force: true)

        #expect(try pin("wartet", in: c).lastCompletedAt == nil)
        #expect(try pin("nurvideo", in: c).lastCompletedAt != nil)
    }
}
