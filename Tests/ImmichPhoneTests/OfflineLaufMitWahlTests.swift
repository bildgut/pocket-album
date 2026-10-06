import Foundation
import SwiftData
import Testing
@testable import ImmichPhone

/// Ganzer Lauf gegen einen Mock-Server. Eigene Lader-Instanz ohne Netzüberwachung,
/// damit der Test die Netzlage setzt und nicht der Simulator.
@Suite("Offline-Lauf mit Wahl", .serialized)
@MainActor
struct OfflineLaufMitWahlTests {
    private let host = "offline-lauf.test"
    private let albumId = "alb"
    private var pinId: String { OfflinePin.pinId(kind: .album, targetId: albumId) }

    private func assetJSON(_ id: String, video: Bool, datum: String) -> String {
        #"{"id":"\#(id)","type":"\#(video ? "VIDEO" : "IMAGE")","originalFileName":"\#(id).x","fileCreatedAt":"\#(datum)T10:00:00.000Z","fileModifiedAt":"\#(datum)T10:00:00.000Z","isFavorite":false}"#
    }

    /// Registriert Album und Dateiendpunkte; zeichnet Dateianfragen auf. Die
    /// Asset-IDs tragen eine Zufallskennung, damit Dateien früherer Läufe im
    /// geteilten Cache-Ordner nicht als vorhanden gelten.
    private func server(fotos: Int, videos: Int, verzoegerung: TimeInterval = 0,
                        beiErsterDatei: (@Sendable () -> Void)? = nil) -> OrteMitschnitt {
        let mitschnitt = OrteMitschnitt()
        let lauf = UUID().uuidString.prefix(8)
        let assets = (0..<fotos).map { assetJSON("f\($0)-\(lauf)", video: false, datum: "2024-01-\(String(format: "%02d", $0 % 28 + 1))") }
            + (0..<videos).map { assetJSON("v\($0)-\(lauf)", video: true, datum: "2024-02-01") }
        let album = #"{"id":"\#(albumId)","albumName":"Urlaub","assetCount":\#(assets.count),"assets":[\#(assets.joined(separator: ","))]}"#
        let erste = ErsteDatei(beiErsterDatei)
        OrteMockURLProtocol.registriere(host: host, verzoegerung: verzoegerung) { req, body in
            let pfad = req.url?.path ?? ""
            if pfad.hasSuffix("/api/albums/\(albumId)") { return (200, Data(album.utf8)) }
            mitschnitt.merke(req, body)
            erste.melde()
            return (200, Data("DATEI".utf8))
        }
        return mitschnitt
    }

    private func container() throws -> ModelContainer {
        let c = try ModelContainer(
            for: Schema(versionedSchema: ImmichMacMigrationPlan.currentSchema),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(c)
        ctx.insert(OfflinePin(kind: .album, targetId: albumId, displayName: "Urlaub"))
        try ctx.save()
        return c
    }

    private func lader(wahl: OfflineWahl?, teuer: Bool) async -> OfflineDownloadManager {
        let m = OfflineDownloadManager(ueberwacheNetz: false)
        if let wahl { await m.setzeWahlQuelle { _ in wahl } }
        await m.updateMeteredStatus(teuer)
        return m
    }

    private func pin(_ c: ModelContainer) throws -> OfflinePin {
        try #require(try ModelContext(c).fetch(FetchDescriptor<OfflinePin>()).first)
    }

    @Test func vorschauOhneVideosLaedtNurThumbnailsUndIstVollstaendig() async throws {
        let mitschnitt = server(fotos: 3, videos: 2)
        defer { OrteMockURLProtocol.entferne(host: host); OfflineSyncProgress.shared.wartetAufWLAN.removeAll() }
        let c = try container()
        let m = await lader(wahl: OfflineWahl(fotos: .vorschau, videos: .keine, mobilfunk: false), teuer: false)

        await m.syncOfflineAlbums(container: c, apiClient: OrteMockURLProtocol.client(host: host), force: true)

        let pfade = mitschnitt.alle.compactMap { $0.request.url?.path }
        #expect(pfade.count == 3)
        #expect(pfade.allSatisfy { $0.hasSuffix("/thumbnail") })
        let geladen = try ModelContext(c).fetch(FetchDescriptor<CachedAsset>()).compactMap(\.localFilePath)
        #expect(geladen.count == 3)
        #expect(geladen.allSatisfy { OfflineFassung.aus(pfad: $0) == .vorschau })
        #expect(try pin(c).lastCompletedAt != nil)
    }

    @Test func nurVideosMitWahlKeineIstSofortVollstaendig() async throws {
        let mitschnitt = server(fotos: 0, videos: 3)
        defer { OrteMockURLProtocol.entferne(host: host) }
        let c = try container()
        let m = await lader(wahl: OfflineWahl(fotos: .vorschau, videos: .keine, mobilfunk: false), teuer: false)

        await m.syncOfflineAlbums(container: c, apiClient: OrteMockURLProtocol.client(host: host), force: true)

        #expect(mitschnitt.alle.isEmpty)
        #expect(try pin(c).lastCompletedAt != nil)
    }

    @Test func teuresNetzOhneFreigabeWartetAufWLAN() async throws {
        let mitschnitt = server(fotos: 3, videos: 0)
        defer { OrteMockURLProtocol.entferne(host: host); OfflineSyncProgress.shared.wartetAufWLAN.removeAll() }
        let c = try container()
        let m = await lader(wahl: OfflineWahl(), teuer: true)

        await m.syncOfflineAlbums(container: c, apiClient: OrteMockURLProtocol.client(host: host), force: true)

        #expect(mitschnitt.alle.isEmpty)
        #expect(OfflineSyncProgress.shared.wartetAufWLAN.contains(pinId))
        #expect(try pin(c).lastCompletedAt == nil)
        #expect(try pin(c).lastError == nil)
    }

    @Test func teuresNetzMitFreigabeLaedtUndLoeschtWartezustand() async throws {
        let mitschnitt = server(fotos: 3, videos: 0)
        defer { OrteMockURLProtocol.entferne(host: host); OfflineSyncProgress.shared.wartetAufWLAN.removeAll() }
        OfflineSyncProgress.shared.wartetAufWLAN.insert(pinId)
        let c = try container()
        let m = await lader(wahl: OfflineWahl(fotos: .vorschau, videos: .klein, mobilfunk: true), teuer: true)

        await m.syncOfflineAlbums(container: c, apiClient: OrteMockURLProtocol.client(host: host), force: true)

        #expect(mitschnitt.alle.count == 3)
        #expect(!OfflineSyncProgress.shared.wartetAufWLAN.contains(pinId))
    }

    @Test func netzWirdMittenImLaufTeuerKeineNeueDatei() async throws {
        let m = OfflineDownloadManager(ueberwacheNetz: false)
        await m.setzeWahlQuelle { _ in OfflineWahl() }
        // Die erste Antwort hält an, bis der Lader das teure Netz kennt — früher
        // eine Verzögerung von 0,3 s, in der ein `Task` laufen *sollte*; unter Last
        // ist das nicht garantiert. Blockiert wird nur der Ladefaden des Mocks.
        let mitschnitt = server(fotos: 10, videos: 0) {
            let fertig = DispatchSemaphore(value: 0)
            Task { await m.updateMeteredStatus(true); fertig.signal() }
            fertig.wait()
        }
        defer { OrteMockURLProtocol.entferne(host: host); OfflineSyncProgress.shared.wartetAufWLAN.removeAll() }
        let c = try container()

        await m.syncOfflineAlbums(container: c, apiClient: OrteMockURLProtocol.client(host: host), force: true)

        // Die ersten drei liefen schon (Fenster = 3), danach keine neue.
        #expect(mitschnitt.alle.count == 3)
        #expect(OfflineSyncProgress.shared.wartetAufWLAN.contains(pinId))
        #expect(try pin(c).lastCompletedAt == nil)
    }

    @Test func aufwertenLoeschtDieVorschaudatei() async throws {
        _ = server(fotos: 1, videos: 0)
        defer { OrteMockURLProtocol.entferne(host: host) }
        let c = try container()
        let client = OrteMockURLProtocol.client(host: host)
        await (await lader(wahl: OfflineWahl(), teuer: false)).syncOfflineAlbums(container: c, apiClient: client, force: true)
        let vorschau = try #require(try ModelContext(c).fetch(FetchDescriptor<CachedAsset>()).first?.localFilePath)
        let vorschauURL = try #require(LocalFileCacheManager.localFileURL(forPath: vorschau))

        let original = OfflineWahl(fotos: .original, videos: .original, mobilfunk: false)
        await (await lader(wahl: original, teuer: false)).syncOfflineAlbums(container: c, apiClient: client, force: true)

        let neu = try #require(try ModelContext(c).fetch(FetchDescriptor<CachedAsset>()).first?.localFilePath)
        #expect(OfflineFassung.aus(pfad: neu) == .original)
        #expect(!FileManager.default.fileExists(atPath: vorschauURL.path))
    }

    @Test func ohneWahlQuelleWieBisher() async throws {
        let mitschnitt = server(fotos: 2, videos: 1)
        defer { OrteMockURLProtocol.entferne(host: host) }
        let c = try container()

        // Teures Netz: Lauf endet vor dem Start, wie bisher.
        await (await lader(wahl: nil, teuer: true)).syncOfflineAlbums(
            container: c, apiClient: OrteMockURLProtocol.client(host: host), force: true)
        #expect(mitschnitt.alle.isEmpty)

        // Günstiges Netz: alle drei als Original, auch das Video.
        await (await lader(wahl: nil, teuer: false)).syncOfflineAlbums(
            container: c, apiClient: OrteMockURLProtocol.client(host: host), force: true)
        let pfade = mitschnitt.alle.compactMap { $0.request.url?.path }
        #expect(pfade.count == 3)
        #expect(pfade.allSatisfy { $0.hasSuffix("/original") })
    }
}

/// Ruft den Rückruf genau einmal — bei der ersten Dateianfrage.
private final class ErsteDatei: @unchecked Sendable {
    private let lock = NSLock()
    private var rueckruf: (@Sendable () -> Void)?
    init(_ rueckruf: (@Sendable () -> Void)?) { self.rueckruf = rueckruf }
    func melde() {
        lock.lock(); let r = rueckruf; rueckruf = nil; lock.unlock()
        r?()
    }
}
