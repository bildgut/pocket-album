import Foundation
import SwiftData
import Testing
@testable import ImmichPhone

@Suite("Offline-Cache: Fassungen", .serialized)
@MainActor
struct OfflineCacheFassungTests {
    private let host = "offline-fassung.test"

    private func monat() -> String { "test-\(UUID().uuidString.prefix(8))" }

    @Test func vorschauKommtVomThumbnailEndpunkt() async throws {
        let mitschnitt = OrteMitschnitt()
        OrteMockURLProtocol.registriere(host: host) { req, body in
            mitschnitt.merke(req, body); return (200, Data("BILD".utf8))
        }
        defer { OrteMockURLProtocol.entferne(host: host) }
        let id = UUID().uuidString, m = monat()

        let pfad = try await LocalFileCacheManager.downloadToCache(
            assetId: id, monthKey: m, fassung: .vorschau, apiClient: OrteMockURLProtocol.client(host: host))

        #expect(pfad == "\(m)/\(id).vorschau.jpg")   // Mock sendet keinen Content-Type
        let url = try #require(LocalFileCacheManager.localFileURL(forPath: pfad))
        #expect(try Data(contentsOf: url) == Data("BILD".utf8))
        let anfrage = try #require(mitschnitt.alle.first?.request)
        #expect(anfrage.url?.path.hasSuffix("/\(id)/thumbnail") == true)
        #expect(OrteMockURLProtocol.query(anfrage, "size") == "preview")
        #expect(anfrage.value(forHTTPHeaderField: "x-api-key") == "test")
    }

    @Test func kleineFassungKommtVomPlaybackEndpunkt() async throws {
        let mitschnitt = OrteMitschnitt()
        OrteMockURLProtocol.registriere(host: host) { req, body in
            mitschnitt.merke(req, body); return (200, Data("FILM".utf8))
        }
        defer { OrteMockURLProtocol.entferne(host: host) }
        let id = UUID().uuidString, m = monat()

        let pfad = try await LocalFileCacheManager.downloadToCache(
            assetId: id, monthKey: m, fassung: .klein, apiClient: OrteMockURLProtocol.client(host: host))

        #expect(pfad == "\(m)/\(id).klein.mp4")
        #expect(mitschnitt.alle.first?.request.url?.path.hasSuffix("/\(id)/video/playback") == true)
    }

    @Test func fehlerLaesstKeineTmpDateiLiegen() async throws {
        OrteMockURLProtocol.registriere(host: host) { _, _ in (500, Data()) }
        defer { OrteMockURLProtocol.entferne(host: host) }
        let id = UUID().uuidString, m = monat()

        await #expect(throws: (any Error).self) {
            _ = try await LocalFileCacheManager.downloadToCache(
                assetId: id, monthKey: m, fassung: .vorschau, apiClient: OrteMockURLProtocol.client(host: host))
        }
        let ordner = LocalFileCacheManager.cacheDirectory.appending(path: m)
        let reste = (try? FileManager.default.contentsOfDirectory(atPath: ordner.path)) ?? []
        #expect(reste.isEmpty)
    }

    @Test func freigebenRaeumtAlleFassungenAberKeineFremden() async throws {
        let id = UUID().uuidString, m = monat()
        let ordner = LocalFileCacheManager.cacheDirectory.appending(path: m)
        try FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true)
        for name in ["\(id).vorschau.jpg", "\(id).klein.mp4", "\(id).heic", "\(id)0.heic"] {
            try Data("x".utf8).write(to: ordner.appending(path: name))
        }
        let container = try ModelContainer(
            for: Schema(versionedSchema: ImmichMacMigrationPlan.currentSchema),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))

        await LocalFileCacheManager.shared.evict(ids: [id], container: container)

        let rest = try FileManager.default.contentsOfDirectory(atPath: ordner.path)
        #expect(rest == ["\(id)0.heic"])
    }
}
