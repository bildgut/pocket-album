import Foundation
import Testing
@testable import ImmichPhone

@Suite("Offline-Quellen – dasselbe Foto nur einmal laden")
struct OfflineEntdoppelnTests {
    private func p(_ id: String, _ f: OfflineFassung) -> OfflineLadeposten {
        OfflineLadeposten(assetId: id, monthKey: "2024-01", fassung: f)
    }

    private func ids(_ l: [[OfflineLadeposten]]) -> [[String]] { l.map { $0.map(\.assetId) } }

    @Test func gleicheFassungNurEinmal() {
        let r = OfflineDownloadManager.entdoppelt([
            ([p("a", .vorschau)], false),
            ([p("a", .vorschau), p("b", .vorschau)], false),
        ])
        #expect(ids(r) == [["a"], ["b"]])
    }

    /// Review-Befund: Vorschau oben, Original unten lud beides — die Vorschau
    /// wurde danach verworfen. Jetzt lädt nur die bessere Fassung.
    @Test func besseresSpaeterVerdraengtFrueheres() {
        let r = OfflineDownloadManager.entdoppelt([
            ([p("a", .vorschau)], false),
            ([p("a", .original)], false),
        ])
        #expect(ids(r) == [[], ["a"]])
    }

    /// Eine spätere reine WLAN-Quelle verdrängt die Vorschau einer Mobilfunk-Quelle
    /// nicht — unterwegs lüde sonst gar nichts.
    @Test func wlanOriginalVerdraengtMobilfunkVorschauNicht() {
        let r = OfflineDownloadManager.entdoppelt([
            ([p("a", .vorschau)], true),
            ([p("a", .original)], false),
        ])
        #expect(ids(r) == [["a"], ["a"]])
    }

    @Test func schlechteresSpaeterFaellt() {
        let r = OfflineDownloadManager.entdoppelt([
            ([p("a", .original)], false),
            ([p("a", .vorschau)], false),
        ])
        #expect(ids(r) == [["a"], []])
    }

    @Test func reihenfolgeInnerhalbErhalten() {
        let r = OfflineDownloadManager.entdoppelt([
            ([p("c", .vorschau), p("a", .vorschau), p("b", .vorschau)], false),
        ])
        #expect(ids(r) == [["c", "a", "b"]])
    }

    /// Wartet die frühere Quelle auf WLAN, darf die spätere mit Mobilfunk-Freigabe
    /// das Foto nicht verlieren.
    @Test func nurWlanDecktMobilfunkNichtAb() {
        let r = OfflineDownloadManager.entdoppelt([
            ([p("a", .vorschau)], false),
            ([p("a", .vorschau)], true),
        ])
        #expect(ids(r) == [["a"], ["a"]])
    }
}
