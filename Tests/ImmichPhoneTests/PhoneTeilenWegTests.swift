import Foundation
import Testing
@testable import ImmichPhone

@Suite("Teilen: welche Datei")
struct PhoneTeilenWegTests {
    private let original = URL(fileURLWithPath: "/c/2024-01/a.heic")
    private let vorschau = URL(fileURLWithPath: "/c/2024-01/a.vorschau.jpg")
    private let klein = URL(fileURLWithPath: "/c/2024-01/a.klein.mp4")

    @Test func lokalesOriginalGehtVor() {
        #expect(PhoneTeilenWeg.bestimme(lokal: original, hatServer: true) == .lokal(original))
        #expect(PhoneTeilenWeg.bestimme(lokal: original, hatServer: false) == .lokal(original))
    }

    @Test func vorschauMitServerHoltOriginalMitVorschauAlsErsatz() {
        #expect(PhoneTeilenWeg.bestimme(lokal: vorschau, hatServer: true) == .server(ersatz: vorschau))
        #expect(PhoneTeilenWeg.bestimme(lokal: klein, hatServer: true) == .server(ersatz: klein))
    }

    @Test func vorschauOhneServerTeiltVorschau() {
        #expect(PhoneTeilenWeg.bestimme(lokal: vorschau, hatServer: false) == .lokal(vorschau))
    }

    @Test func nichtsLokal() {
        #expect(PhoneTeilenWeg.bestimme(lokal: nil, hatServer: true) == .server(ersatz: nil))
        #expect(PhoneTeilenWeg.bestimme(lokal: nil, hatServer: false) == .nichts)
    }
}
