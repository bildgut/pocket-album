import Foundation
import Testing
@testable import ImmichPhone

@Suite("Offline-Quellen – Suchfilter")
struct OfflineQuellenFilterTests {
    @Test func favoritenFilter() {
        var erwartet = SearchFilter.visibleLibrary(type: nil)
        erwartet.isFavorite = .equals(true)
        #expect(OfflineQuellenFilter.filter(kind: .favoriten, targetId: "eigene") == erwartet)
    }

    @Test func personFilter() {
        var erwartet = SearchFilter.visibleLibrary(type: nil)
        erwartet.personIds = .anyOf(["p1"])
        #expect(OfflineQuellenFilter.filter(kind: .person, targetId: "p1") == erwartet)
    }

    @Test func albumHatKeinenFilter() {
        #expect(OfflineQuellenFilter.filter(kind: .album, targetId: "a") == nil)
        #expect(OfflineQuellenFilter.filter(kind: .smartAlbum, targetId: "s") == nil)
        #expect(OfflineQuellenFilter.filter(kind: .zuletzt, targetId: "eigene") == nil)
    }

    @Test func pinIds() {
        #expect(OfflinePin.pinId(kind: .person, targetId: "p1") == "person:p1")
        #expect(OfflinePin.pinId(kind: .favoriten, targetId: OfflineQuellenFilter.favoritenTargetId) == "favoriten:eigene")
    }
}
