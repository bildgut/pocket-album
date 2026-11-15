import Foundation
import Testing
@testable import ImmichPhone

/// Gerätebefund 26.10.2026: Offline sah man nur im Fotos-Reiter, unten stand
/// überall „Vorbereitung…“, und Kacheln der Offline-Fotos blieben leer.
@Suite("Offline-Leiste und Offline-Thumbnails")
struct PhoneOfflineLeisteTests {

    @Test("Offline schlägt den Ladebalken")
    func offlineSchlaegtLaden() {
        #expect(PhoneStatusLeiste.art(istOffline: true, laeuft: true) == .offline)
        #expect(PhoneStatusLeiste.art(istOffline: true, laeuft: false) == .offline)
    }

    @Test("Online: Ladebalken nur bei laufendem Download")
    func onlineNurBeimLaden() {
        #expect(PhoneStatusLeiste.art(istOffline: false, laeuft: true) == .laden)
        #expect(PhoneStatusLeiste.art(istOffline: false, laeuft: false) == .keine)
    }

    @Test("Thumbnail-URLs: je Foto einmal, in der Reihenfolge der Vermerke")
    func urlsEntdoppelt() {
        let basis = URL(string: "https://server.test/api/assets/")!
        let urls = PhoneOfflineThumbnailWaermer.urls(assetIds: [["a", "b"], ["b", "c"], []]) {
            basis.appending(path: $0)
        }
        #expect(urls.map(\.lastPathComponent) == ["a", "b", "c"])
    }

    @Test("Thumbnail-URL ist die der Rasterkachel (gleicher Cache-Schlüssel)")
    func urlWieKachel() {
        let client = ImmichAPIClient(baseURL: URL(string: "https://server.test")!, apiKey: "k")
        let urls = PhoneOfflineThumbnailWaermer.urls(assetIds: [["x"]]) {
            client.thumbnailURL(assetId: $0, size: .thumbnail)
        }
        #expect(urls == [client.thumbnailURL(assetId: "x", size: .thumbnail)])
    }
}

/// Gerätebefund 26.10.2026: Offline verschwand die Favoriten-Kachel, obwohl die
/// Favoriten als Offline-Quelle auf dem iPhone lagen.
@Suite("Favoriten-Kachel offline")
struct PhoneFavoritenKachelSichtbarTests {

    @Test("Online ohne Suche: sichtbar, auch ohne Offline-Vermerk")
    func online() {
        #expect(PhoneFavoritenKachel.sichtbar(suchtext: "", istOffline: false, hatClient: true, offlineGespeichert: false))
    }

    @Test("Offline mit gespeicherten Favoriten: sichtbar")
    func offlineGespeichert() {
        #expect(PhoneFavoritenKachel.sichtbar(suchtext: "", istOffline: true, hatClient: true, offlineGespeichert: true))
    }

    @Test("Offline ohne Vermerk: ausgeblendet")
    func offlineOhneVermerk() {
        #expect(!PhoneFavoritenKachel.sichtbar(suchtext: "", istOffline: true, hatClient: true, offlineGespeichert: false))
    }

    @Test("Mit Suchbegriff oder ohne Client: ausgeblendet")
    func sucheOderOhneClient() {
        #expect(!PhoneFavoritenKachel.sichtbar(suchtext: "Urlaub", istOffline: false, hatClient: true, offlineGespeichert: true))
        #expect(!PhoneFavoritenKachel.sichtbar(suchtext: "", istOffline: false, hatClient: false, offlineGespeichert: true))
    }
}

/// Offline gespeicherte Personen waren in „Entdecken“ ohne Netz gesperrt.
@Suite("Offline gespeicherte Personen")
@MainActor
struct PhoneOfflinePersonenTests {

    @Test("Nur Personen-Vermerke, nach Namen sortiert, mit Anzahl")
    func eintraege() {
        let pins = [
            OfflinePin(kind: .person, targetId: "p2", displayName: "Mia", assetIds: ["a", "b"]),
            OfflinePin(kind: .album, targetId: "alb", displayName: "Urlaub", assetIds: ["c"]),
            OfflinePin(kind: .person, targetId: "p1", displayName: "Lena", assetIds: ["d"]),
        ]
        let eintraege = PhoneOfflinePersonen.eintraege(aus: pins)
        #expect(eintraege == [
            .init(id: "p1", name: "Lena", anzahl: 1),
            .init(id: "p2", name: "Mia", anzahl: 2),
        ])
    }
}
