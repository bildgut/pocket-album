import Foundation
import Testing
@testable import ImmichPhone

@Suite("Offline-Quellen – Ladereihenfolge")
struct OfflineReihenfolgeTests {
    private struct Q { let pinId: String; let kind: OfflinePinKind; let pinnedAt: Date }

    private func frisch() -> OfflineReihenfolge {
        OfflineReihenfolge(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    private func q(_ kind: OfflinePinKind, _ id: String, _ t: TimeInterval) -> Q {
        Q(pinId: OfflinePin.pinId(kind: kind, targetId: id), kind: kind, pinnedAt: Date(timeIntervalSince1970: t))
    }

    private func ids(_ r: OfflineReihenfolge, _ e: [Q]) -> [String] {
        r.sortiert(e, pinId: \.pinId, kind: \.kind, pinnedAt: \.pinnedAt).map(\.pinId)
    }

    @Test func vorgabeOhneSchluessel() {
        let e = [q(.album, "a", 0), q(.person, "p", 1), q(.favoriten, "eigene", 2), q(.zuletzt, "eigene", 3)]
        #expect(ids(frisch(), e) == ["favoriten:eigene", "zuletzt:eigene", "person:p", "album:a"])
    }

    @Test func vorgabeSchreibtNichts() {
        let d = UserDefaults(suiteName: UUID().uuidString)!
        _ = OfflineReihenfolge(defaults: d).sortiert([q(.album, "a", 0)], pinId: \.pinId, kind: \.kind, pinnedAt: \.pinnedAt)
        #expect(d.object(forKey: OfflineReihenfolge.schluessel) == nil)
    }

    @Test func gespeicherteReihenfolgeGilt() {
        let r = frisch()
        r.setze(["album:a", "favoriten:eigene"])
        #expect(ids(r, [q(.favoriten, "eigene", 0), q(.album, "a", 1)]) == ["album:a", "favoriten:eigene"])
    }

    @Test func unbekannteAnsEnde() {
        let r = frisch()
        r.setze(["album:a"])
        let e = [q(.person, "p", 5), q(.album, "a", 0), q(.smartAlbum, "s", 4)]
        #expect(ids(r, e) == ["album:a", "smart:s", "person:p"])
    }

    @Test func verwaisteIdsStoerenNicht() {
        let r = frisch()
        r.setze(["person:weg", "album:a"])
        #expect(ids(r, [q(.album, "a", 0)]) == ["album:a"])
    }

    @Test func verschiebe() {
        let d = UserDefaults(suiteName: UUID().uuidString)!
        let r = OfflineReihenfolge(defaults: d)
        r.verschiebe(["a", "b", "c"], von: IndexSet(integer: 2), nach: 0)
        #expect(d.stringArray(forKey: OfflineReihenfolge.schluessel) == ["c", "a", "b"])
    }
}
