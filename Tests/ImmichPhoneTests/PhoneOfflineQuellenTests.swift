import Foundation
import Testing
@testable import ImmichPhone

@Suite("Offline-Seite – Zeilen")
struct PhoneOfflineQuellenTests {
    private func quelle(_ kind: OfflinePinKind, _ target: String, _ name: String, _ t: TimeInterval,
                        fotos: OfflineWahl.Fotos = .vorschau, erwartet: Int = 0, bytes: Int64 = 0) -> PhoneOfflineQuelle {
        PhoneOfflineQuelle(
            id: OfflinePin.pinId(kind: kind, targetId: target), kind: kind, targetId: target,
            pinnedAt: Date(timeIntervalSince1970: t),
            eintrag: PhoneStorageSummary.Eintrag(name: name, vorhanden: erwartet, erwartet: erwartet, bytes: bytes),
            wahl: OfflineWahl(fotos: fotos, videos: .keine, mobilfunk: false))
    }

    @Test func zeilenFolgenReihenfolge() {
        let r = OfflineReihenfolge(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        r.setze(["person:p", "album:a"])
        let q = [quelle(.album, "a", "Urlaub", 0), quelle(.favoriten, "eigene", "Favorites", 1), quelle(.person, "p", "Mia", 2)]
        #expect(PhoneOfflineQuellen.geordnet(q, reihenfolge: r).map(\.id) == ["person:p", "album:a", "favoriten:eigene"])
    }

    @Test func untertitelNachWahl() {
        #expect(quelle(.favoriten, "eigene", "F", 0, fotos: .vorschau, erwartet: 812, bytes: 1_500).untertitel == "Preview · 1,5 KB")
        #expect(quelle(.album, "a", "U", 0, fotos: .original, bytes: 0).untertitel == "Original · 0 B")
    }

    @Test func zuletztTitelAusStufe() {
        let d = UserDefaults(suiteName: UUID().uuidString)!
        ZuletztOffline.setzeTage(7, defaults: d)
        #expect(quelle(.zuletzt, "eigene", "alt", 0).titel(tage: ZuletztOffline.tage(defaults: d)) == PhoneZuletztStand.titel(tage: 7))
        #expect(quelle(.person, "p", "Mia", 0).titel(tage: 7) == "Mia")
    }

    @Test func hinzufuegbar() {
        #expect(PhoneOfflineQuellen.hinzufuegbar(vorhanden: [], darfPersonen: true) == [.favoriten, .zuletzt, .person])
        #expect(PhoneOfflineQuellen.hinzufuegbar(vorhanden: [.favoriten, .person], darfPersonen: true) == [.zuletzt, .person])
        #expect(PhoneOfflineQuellen.hinzufuegbar(vorhanden: [], darfPersonen: false) == [.favoriten, .zuletzt])
    }

    @Test func zusammenfassung() {
        let q = [quelle(.album, "a", "U", 0, bytes: 4_200_000_000), quelle(.person, "p", "M", 1)]
        #expect(PhoneOfflineQuellen.zusammenfassung(q) == "2 sources · 4,2 GB")
        #expect(PhoneOfflineQuellen.zusammenfassung([]) == "Off")
        #expect(PhoneOfflineQuellen.zusammenfassung([quelle(.person, "p", "M", 1)]) == "1 source · 0 B")
    }

    @Test func personenRechtFehltNurBeiBerechtigungsfehler() {
        #expect(!PhoneOfflineQuellen.darfPersonen(nach: APIError.apiKeyLacksPermission("person.read")))
        #expect(PhoneOfflineQuellen.darfPersonen(nach: APIError.serverFehler(503)))
        #expect(PhoneOfflineQuellen.darfPersonen(nach: URLError(.timedOut)))
    }
}
