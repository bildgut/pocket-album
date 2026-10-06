import Foundation
import Testing
@testable import ImmichPhone

@Suite("Offline-Wahl: Speicher")
struct OfflineWahlSpeicherTests {
    private func speicher() -> OfflineWahlSpeicher {
        OfflineWahlSpeicher(defaults: UserDefaults(suiteName: "OfflineWahlSpeicherTests-\(UUID().uuidString)")!)
    }

    @Test func ohneEintragNilUndStandardAlsLetzte() {
        let s = speicher()
        #expect(s.wahl(fuer: "album:a") == nil)
        #expect(s.letzte == OfflineWahl())
    }

    @Test func merktJeVermerkUndAlsLetzte() {
        let s = speicher()
        let a = OfflineWahl(fotos: .original, videos: .keine, mobilfunk: true)
        let b = OfflineWahl(fotos: .vorschau, videos: .original, mobilfunk: false)
        s.setze(a, fuer: "album:a")
        s.setze(b, fuer: "album:b")
        #expect(s.wahl(fuer: "album:a") == a)
        #expect(s.wahl(fuer: "album:b") == b)
        #expect(s.letzte == b)
    }

    @Test func entfernenLoeschtNurDiesenVermerkUndNichtDieLetzte() {
        let s = speicher()
        let a = OfflineWahl(fotos: .original, videos: .keine, mobilfunk: true)
        s.setze(a, fuer: "album:a")
        s.setze(OfflineWahl(), fuer: "album:b")
        s.entferne(pinId: "album:b")
        #expect(s.wahl(fuer: "album:b") == nil)
        #expect(s.wahl(fuer: "album:a") == a)
        #expect(s.letzte == OfflineWahl())   // die letzte Wahl bleibt Vorgabe
    }

    @Test func kaputtesJSONGiltAlsLeer() {
        let defaults = UserDefaults(suiteName: "OfflineWahlSpeicherTests-\(UUID().uuidString)")!
        defaults.set(Data("kein json".utf8), forKey: OfflineWahlSpeicher.schluessel)
        let s = OfflineWahlSpeicher(defaults: defaults)
        #expect(s.wahl(fuer: "album:a") == nil)
        s.setze(OfflineWahl(), fuer: "album:a")
        #expect(s.wahl(fuer: "album:a") == OfflineWahl())
    }
}
