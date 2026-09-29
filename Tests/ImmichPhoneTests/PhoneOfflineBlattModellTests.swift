import Foundation
import Testing
@testable import ImmichPhone

@Suite("Offline-Blatt: Modell", .serialized)
@MainActor
struct PhoneOfflineBlattModellTests {
    private let host = "offline-blatt.test"
    private let album = Album(
        id: "alb", albumName: "Urlaub", description: nil, createdAt: "", updatedAt: "",
        startDate: nil, endDate: nil, assetCount: 3, albumThumbnailAssetId: nil,
        shared: nil, hasSharedLink: nil, owner: nil)

    private nonisolated static let foto = #"{"id":"f","type":"IMAGE","originalFileName":"f","fileCreatedAt":"2024-01-01T00:00:00.000Z","fileModifiedAt":"2024-01-01T00:00:00.000Z","isFavorite":false,"exifInfo":{"fileSizeInByte":3000000}}"#
    private nonisolated static let video = #"{"id":"v","type":"VIDEO","originalFileName":"v","fileCreatedAt":"2024-01-01T00:00:00.000Z","fileModifiedAt":"2024-01-01T00:00:00.000Z","isFavorite":false,"duration":"00:00:10.000"}"#

    @Test func eintraegeAusAssets() throws {
        let assets = try JSONDecoder().decode([Asset].self, from: Data("[\(Self.foto),\(Self.video)]".utf8))
        #expect(PhoneOfflineBlattModell.eintraege(aus: assets) == [
            .init(istVideo: false, bytes: 3_000_000, sekunden: nil),
            .init(istVideo: true, bytes: nil, sekunden: 10),
        ])
    }

    @Test func zaehlungLaesstNullteileWeg() {
        let fotos = String(localized: "\(3) photos")
        let videos = String(localized: "\(2) videos")
        #expect(PhoneOfflineBlatt.zaehlText(fotos: 3, videos: 0) == fotos)
        #expect(PhoneOfflineBlatt.zaehlText(fotos: 0, videos: 2) == videos)
        #expect(PhoneOfflineBlatt.zaehlText(fotos: 3, videos: 2) == fotos + " · " + videos)
        #expect(PhoneOfflineBlatt.zaehlText(fotos: 0, videos: 0) == String(localized: "\(0) items"))
    }

    @Test func vorDemLadenKeineSchaetzungUndNichtGesperrt() {
        let m = PhoneOfflineBlattModell(album: album, wahl: OfflineWahl(), freierPlatz: 1)
        #expect(m.schaetzung == nil)
        #expect(m.passt)
    }

    @Test func nachDemLadenZaehlenSchaetzenSperren() async {
        OrteMockURLProtocol.registriere(host: host) { _, _ in
            (200, OrteMockURLProtocol.seiteJSON([Self.foto, Self.video]))
        }
        defer { OrteMockURLProtocol.entferne(host: host) }
        let m = PhoneOfflineBlattModell(album: album, wahl: OfflineWahl(), freierPlatz: 4_000_000)

        await m.lade(apiClient: OrteMockURLProtocol.client(host: host))

        #expect(m.laden == .fertig)
        #expect(m.anzahlFotos == 1 && m.anzahlVideos == 1)
        #expect(m.schaetzung == Int64(350_000 + 3_000_000))   // Vorschau + 10 s klein
        #expect(m.passt)
        m.wahl.videos = .original                         // 10 s × 2 MB = 20 MB > 90 % von 4 MB
        #expect(!m.passt)
    }

    @Test func ladefehlerSperrtNicht() async {
        OrteMockURLProtocol.registriere(host: host) { _, _ in (500, Data()) }
        defer { OrteMockURLProtocol.entferne(host: host) }
        let m = PhoneOfflineBlattModell(album: album, wahl: OfflineWahl(), freierPlatz: 1)
        await m.lade(apiClient: OrteMockURLProtocol.client(host: host))
        #expect(m.laden == .fehlgeschlagen)
        #expect(m.schaetzung == nil)
        #expect(m.passt)
    }
}
