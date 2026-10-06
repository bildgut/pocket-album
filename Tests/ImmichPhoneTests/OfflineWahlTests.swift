import Foundation
import Testing
@testable import ImmichPhone

@Suite("Offline-Wahl: Fassung, Ziel, Schätzung")
struct OfflineWahlTests {

    // MARK: Fassung im Dateinamen

    @Test func fassungAusPfad() {
        #expect(OfflineFassung.aus(pfad: "2024-01/abc.heic") == .original)
        #expect(OfflineFassung.aus(pfad: "2024-01/abc") == .original)
        #expect(OfflineFassung.aus(pfad: "2024-01/abc.vorschau.jpg") == .vorschau)
        #expect(OfflineFassung.aus(pfad: "2024-01/abc.klein.mp4") == .klein)
        // Unbekannter Zusatz: lieber Original annehmen als raten.
        #expect(OfflineFassung.aus(pfad: "2024-01/abc.foo.jpg") == .original)
    }

    @Test func dateinameJeFassung() {
        #expect(OfflineFassung.original.dateiname(assetId: "a1", endung: "heic") == "a1.heic")
        #expect(OfflineFassung.original.dateiname(assetId: "a1", endung: "") == "a1")
        #expect(OfflineFassung.vorschau.dateiname(assetId: "a1", endung: "jpg") == "a1.vorschau.jpg")
        #expect(OfflineFassung.klein.dateiname(assetId: "a1", endung: "mp4") == "a1.klein.mp4")
    }

    @Test func dateiGehoertZumAsset() {
        #expect(OfflineFassung.gehoert(dateiname: "a1.heic", zu: "a1"))
        #expect(OfflineFassung.gehoert(dateiname: "a1.vorschau.jpg", zu: "a1"))
        #expect(OfflineFassung.gehoert(dateiname: "a1.klein.mp4", zu: "a1"))
        #expect(OfflineFassung.gehoert(dateiname: "a1", zu: "a1"))
        #expect(!OfflineFassung.gehoert(dateiname: "a10.heic", zu: "a1"))
        #expect(!OfflineFassung.gehoert(dateiname: "xa1.heic", zu: "a1"))
    }

    @Test func endungAusContentType() {
        #expect(OfflineFassung.endung(contentType: "image/jpeg") == "jpg")
        #expect(OfflineFassung.endung(contentType: "image/webp") == "webp")
        #expect(OfflineFassung.endung(contentType: "image/webp; charset=binary") == "webp")
        #expect(OfflineFassung.endung(contentType: "IMAGE/WEBP") == "webp")
        #expect(OfflineFassung.endung(contentType: nil) == "jpg")
        #expect(OfflineFassung.endung(contentType: "application/octet-stream") == "jpg")
    }

    // MARK: Ziel und „reicht“

    @Test func standardIstVorschauUndKlein() {
        let w = OfflineWahl()
        #expect(w.fotos == .vorschau && w.videos == .klein && w.mobilfunk == false)
        #expect(w.ziel(istVideo: false) == .vorschau)
        #expect(w.ziel(istVideo: true) == .klein)
    }

    @Test func videosKeineHabenKeinZiel() {
        let w = OfflineWahl(fotos: .original, videos: .keine, mobilfunk: false)
        #expect(w.ziel(istVideo: true) == nil)
        #expect(w.ziel(istVideo: false) == .original)
        #expect(w.reicht(.klein, istVideo: true))   // nichts gewünscht ⇒ alles reicht
    }

    @Test func originalReichtImmerVorschauNichtFuerOriginal() {
        let vorschau = OfflineWahl()
        #expect(vorschau.reicht(.original, istVideo: false))
        #expect(vorschau.reicht(.vorschau, istVideo: false))
        let original = OfflineWahl(fotos: .original, videos: .original, mobilfunk: false)
        #expect(!original.reicht(.vorschau, istVideo: false))
        #expect(!original.reicht(.klein, istVideo: true))
        #expect(original.reicht(.original, istVideo: true))
    }

    @Test func wahlUeberlebtJSON() throws {
        let w = OfflineWahl(fotos: .original, videos: .keine, mobilfunk: true)
        let zurueck = try JSONDecoder().decode(OfflineWahl.self, from: JSONEncoder().encode(w))
        #expect(zurueck == w)
    }

    // MARK: Schätzung

    private typealias E = OfflineSchaetzung.Eintrag

    @Test func fotosJeWahl() {
        let fotos = [E(istVideo: false, bytes: 3_000_000, sekunden: nil),
                     E(istVideo: false, bytes: nil, sekunden: nil)]
        #expect(OfflineSchaetzung.bytes(fotos, wahl: OfflineWahl()) == 700_000)
        let original = OfflineWahl(fotos: .original, videos: .klein, mobilfunk: false)
        #expect(OfflineSchaetzung.bytes(fotos, wahl: original) == 7_000_000)   // 3 MB + 4 MB Ersatz
    }

    @Test func videosJeWahl() {
        let videos = [E(istVideo: true, bytes: 50_000_000, sekunden: 10),
                      E(istVideo: true, bytes: nil, sekunden: 20),
                      E(istVideo: true, bytes: nil, sekunden: nil)]
        // 10 s × 0,3 MB + 20 s × 0,3 MB + 15 MB Ersatz
        #expect(OfflineSchaetzung.bytes(videos, wahl: OfflineWahl()) == 3_000_000 + 6_000_000 + 15_000_000)
        let original = OfflineWahl(fotos: .vorschau, videos: .original, mobilfunk: false)
        // 50 MB + 20 s × 2 MB + 100 MB Ersatz
        #expect(OfflineSchaetzung.bytes(videos, wahl: original) == 50_000_000 + 40_000_000 + 100_000_000)
        let keine = OfflineWahl(fotos: .vorschau, videos: .keine, mobilfunk: false)
        #expect(OfflineSchaetzung.bytes(videos, wahl: keine) == 0)
    }

    @Test func unsinnigeLaufzeitZaehltAlsFehlend() {
        let v = [E(istVideo: true, bytes: nil, sekunden: .nan), E(istVideo: true, bytes: nil, sekunden: -3)]
        #expect(OfflineSchaetzung.bytes(v, wahl: OfflineWahl()) == 30_000_000)
    }

    @Test func passtBeiNeunzigProzent() {
        #expect(OfflineSchaetzung.passt(bytes: 900, frei: 1_000))
        #expect(!OfflineSchaetzung.passt(bytes: 901, frei: 1_000))
        #expect(OfflineSchaetzung.passt(bytes: 5_000_000_000, frei: nil))
    }
}
