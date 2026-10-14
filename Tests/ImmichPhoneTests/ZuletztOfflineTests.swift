import Foundation
import SwiftData
import Testing
@testable import ImmichPhone

@Suite("Letzte Tage offline – Zeitfenster")
struct ZuletztFensterTests {
    private var berlin: Calendar {
        var k = Calendar(identifier: .gregorian)
        k.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return k
    }

    private func datum(_ text: String) -> Date {
        let f = ISO8601DateFormatter()
        return f.date(from: text)!
    }

    @Test func ausLiefertKeinFenster() {
        #expect(ZuletztOffline.beginn(tage: 0, jetzt: .now, kalender: berlin) == nil)
        #expect(ZuletztOffline.filter(tage: 0, jetzt: .now, kalender: berlin) == nil)
    }

    @Test func dreiTageSindHeuteUndDieZweiDavor() {
        // 14.10.2026 15:00 Berliner Zeit (= 13:00 UTC)
        let jetzt = datum("2026-10-14T13:00:00Z")
        let beginn = ZuletztOffline.beginn(tage: 3, jetzt: jetzt, kalender: berlin)
        // 12.10.2026 00:00 Berlin = 11.10. 22:00 UTC (Sommerzeit)
        #expect(beginn == datum("2026-10-11T22:00:00Z"))
    }

    @Test func einTagIstNurHeute() {
        let jetzt = datum("2026-10-14T13:00:00Z")
        #expect(ZuletztOffline.beginn(tage: 1, jetzt: jetzt, kalender: berlin) == datum("2026-10-13T22:00:00Z"))
    }

    @Test func ueberDieSommerzeitgrenzeBleibtEsMitternacht() {
        // 27.10.2026 ist nach dem Wechsel auf Winterzeit (25.10.)
        let jetzt = datum("2026-10-27T10:00:00Z")
        let beginn = ZuletztOffline.beginn(tage: 7, jetzt: jetzt, kalender: berlin)
        // 21.10.2026 00:00 Berlin, noch Sommerzeit = 20.10. 22:00 UTC
        #expect(beginn == datum("2026-10-20T22:00:00Z"))
    }

    @Test func filterIstEigeneBibliothekAbBeginn() throws {
        let jetzt = datum("2026-10-14T13:00:00Z")
        let filter = try #require(ZuletztOffline.filter(tage: 3, jetzt: jetzt, kalender: berlin))
        var erwartet = SearchFilter.visibleLibrary(type: nil)
        erwartet.takenAt = .onOrAfter(datum("2026-10-11T22:00:00Z"))
        #expect(filter == erwartet)
        #expect(filter.albumIds == nil)
        #expect(filter.or == nil)
    }

    @Test func stufenUndVorgabe() {
        #expect(ZuletztOffline.stufen == [0, 3, 7, 14, 30])
        #expect(ZuletztOffline.vorgabeWahl == OfflineWahl(fotos: .vorschau, videos: .keine, mobilfunk: false))
    }

    @Test func pinIdIstFest() {
        #expect(ZuletztOffline.pinId == "zuletzt:eigene")
        #expect(OfflinePinKind(rawValue: "zuletzt") == .zuletzt)
    }

    @Test func tageWerdenGemerktUndUnbekannteVerworfen() {
        let defaults = UserDefaults(suiteName: "zuletzt-\(UUID().uuidString)")!
        #expect(ZuletztOffline.tage(defaults: defaults) == 0)
        ZuletztOffline.setzeTage(7, defaults: defaults)
        #expect(ZuletztOffline.tage(defaults: defaults) == 7)
        defaults.set(5, forKey: ZuletztOffline.schluessel)
        #expect(ZuletztOffline.tage(defaults: defaults) == 0)
    }
}

/// Ganzer Lauf gegen einen Mock-Server: Auflösung über die Suche, Download,
/// Erhalt bei Fehlern.
@Suite("Letzte Tage offline – Lauf", .serialized)
@MainActor
struct ZuletztOfflineLaufTests {
    private let host = "zuletzt-lauf.test"

    private func assetJSON(_ id: String, video: Bool = false) -> String {
        #"{"id":"\#(id)","type":"\#(video ? "VIDEO" : "IMAGE")","originalFileName":"\#(id).x","fileCreatedAt":"2026-10-13T10:00:00.000Z","fileModifiedAt":"2026-10-13T10:00:00.000Z","isFavorite":false}"#
    }

    private func seite(_ ids: [String], weiter: String?, videos: Set<String> = []) -> String {
        let cursor = weiter.map { #""\#($0)""# } ?? "null"
        return #"{"assets":{"items":[\#(ids.map { assetJSON($0, video: videos.contains($0)) }.joined(separator: ","))],"total":\#(ids.count),"count":\#(ids.count),"nextCursor":\#(cursor)}}"#
    }

    private func container() throws -> ModelContainer {
        let c = try ModelContainer(
            for: Schema(versionedSchema: ImmichMacMigrationPlan.currentSchema),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(c)
        ctx.insert(OfflinePin(kind: .zuletzt, targetId: ZuletztOffline.targetId, displayName: "Letzte Tage"))
        try ctx.save()
        return c
    }

    private func pin(_ c: ModelContainer) throws -> OfflinePin {
        try #require(try ModelContext(c).fetch(FetchDescriptor<OfflinePin>()).first)
    }

    @Test func loestUeberDieSucheAufUndBlaettert() async throws {
        let lauf = UUID().uuidString.prefix(8)
        let a = "a-\(lauf)", b = "b-\(lauf)", c3 = "c-\(lauf)"
        let mitschnitt = OrteMitschnitt()
        let ersteSeite = seite([a, b], weiter: SearchCursor.forOffset(2))
        let zweiteSeite = seite([c3], weiter: nil)
        OrteMockURLProtocol.registriere(host: host) { req, body in
            mitschnitt.merke(req, body)
            if req.url?.path.hasSuffix("/api/search/metadata") == true {
                let text = String(decoding: body, as: UTF8.self)
                return (200, Data((text.contains("cursor") ? zweiteSeite : ersteSeite).utf8))
            }
            return (200, Data("DATEI".utf8))
        }
        defer { OrteMockURLProtocol.entferne(host: host); AppEnvironment.defaults.removeObject(forKey: ZuletztOffline.schluessel) }
        ZuletztOffline.setzeTage(7, defaults: AppEnvironment.defaults)

        let c = try container()
        let m = OfflineDownloadManager(ueberwacheNetz: false)
        await m.setzeWahlQuelle { _ in ZuletztOffline.vorgabeWahl }
        await m.updateMeteredStatus(false)
        await m.syncOfflineAlbums(container: c, apiClient: OrteMockURLProtocol.client(host: host), force: true)

        #expect(Set(try pin(c).assetIds) == [a, b, c3])
        let suche = mitschnitt.alle.filter { $0.request.url?.path.hasSuffix("/api/search/metadata") == true }
        #expect(suche.count == 2)
        let koerper = String(decoding: suche.first?.koerper ?? Data(), as: UTF8.self)
        #expect(koerper.contains("takenAt"))
        #expect(!koerper.contains("albumIds"))
        let dateien = mitschnitt.alle.filter { $0.request.url?.path.hasSuffix("/thumbnail") == true }
        #expect(dateien.count == 3)
        #expect(try pin(c).lastCompletedAt != nil)
    }

    /// Gerätebefund 14.10.2026: Mit „Videos: Keine“ zeigte die Kachel trotzdem die
    /// Videos des Zeitraums — sie standen in der Mitgliedschaft, nur geladen wurden
    /// sie nicht. Was die Wahl ausschließt, gehört gar nicht erst hinein.
    @Test func ohneVideosStehenKeineVideosImVermerk() async throws {
        let lauf = UUID().uuidString.prefix(8)
        let foto = "f-\(lauf)", video = "v-\(lauf)"
        let antwort = seite([foto, video], weiter: nil, videos: [video])
        OrteMockURLProtocol.registriere(host: host) { req, _ in
            if req.url?.path.hasSuffix("/api/search/metadata") == true { return (200, Data(antwort.utf8)) }
            return (200, Data("DATEI".utf8))
        }
        defer { OrteMockURLProtocol.entferne(host: host); AppEnvironment.defaults.removeObject(forKey: ZuletztOffline.schluessel) }
        ZuletztOffline.setzeTage(14, defaults: AppEnvironment.defaults)

        let c = try container()
        let m = OfflineDownloadManager(ueberwacheNetz: false)
        await m.setzeWahlQuelle { _ in OfflineWahl(fotos: .vorschau, videos: .keine, mobilfunk: false) }
        await m.updateMeteredStatus(false)
        await m.syncOfflineAlbums(container: c, apiClient: OrteMockURLProtocol.client(host: host), force: true)

        #expect(try pin(c).assetIds == [foto])
    }

    @Test func fehlerBehaeltDieAlteMitgliedschaft() async throws {
        OrteMockURLProtocol.registriere(host: host) { _, _ in (500, Data()) }
        defer { OrteMockURLProtocol.entferne(host: host); AppEnvironment.defaults.removeObject(forKey: ZuletztOffline.schluessel) }
        ZuletztOffline.setzeTage(7, defaults: AppEnvironment.defaults)

        let c = try container()
        let ctx = ModelContext(c)
        let p = try #require(try ctx.fetch(FetchDescriptor<OfflinePin>()).first)
        p.assetIds = ["alt1", "alt2"]
        try ctx.save()

        let m = OfflineDownloadManager(ueberwacheNetz: false)
        await m.setzeWahlQuelle { _ in ZuletztOffline.vorgabeWahl }
        await m.updateMeteredStatus(false)
        await m.syncOfflineAlbums(container: c, apiClient: OrteMockURLProtocol.client(host: host), force: true)

        #expect(try pin(c).assetIds == ["alt1", "alt2"])
        #expect(try pin(c).lastError != nil)
    }
}
