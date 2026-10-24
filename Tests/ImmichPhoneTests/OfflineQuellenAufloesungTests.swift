import Foundation
import SwiftData
import Testing
@testable import ImmichPhone

/// Favoriten und Personen im ganzen Lauf gegen einen Mock-Server, dazu die
/// Ladereihenfolge über die Reihenfolge-Quelle.
@Suite("Offline-Quellen – Auflösung und Reihenfolge", .serialized)
@MainActor
struct OfflineQuellenAufloesungTests {
    private let host = "offline-quellen.test"
    private let vorschau = OfflineWahl(fotos: .vorschau, videos: .keine, mobilfunk: false)

    nonisolated private static func assetJSON(_ id: String) -> String {
        #"{"id":"\#(id)","type":"IMAGE","originalFileName":"\#(id).jpg","fileCreatedAt":"2024-01-01T10:00:00.000Z","fileModifiedAt":"2024-01-01T10:00:00.000Z","isFavorite":true}"#
    }

    nonisolated private static func seite(_ ids: [String], weiter: String?) -> Data {
        let cursor = weiter.map { "\"\($0)\"" } ?? "null"
        return Data(#"{"assets":{"items":[\#(ids.map(Self.assetJSON).joined(separator: ","))],"total":\#(ids.count),"count":\#(ids.count),"nextCursor":\#(cursor)}}"#.utf8)
    }

    nonisolated private static func personen(_ ids: [String]) -> Data {
        let p = ids.map { #"{"id":"\#($0)","name":"N\#($0)","isHidden":false}"# }.joined(separator: ",")
        return Data(#"{"people":[\#(p)],"total":\#(ids.count),"hidden":0,"hasNextPage":false}"#.utf8)
    }

    private func container(_ pins: [OfflinePin]) throws -> ModelContainer {
        let c = try ModelContainer(
            for: Schema(versionedSchema: ImmichMacMigrationPlan.currentSchema),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = ModelContext(c)
        pins.forEach { ctx.insert($0) }
        try ctx.save()
        return c
    }

    private func pins(_ c: ModelContainer) throws -> [String: OfflinePin] {
        Dictionary(uniqueKeysWithValues: try ModelContext(c).fetch(FetchDescriptor<OfflinePin>()).map { ($0.pinId, $0) })
    }

    private func lader() async -> OfflineDownloadManager {
        let m = OfflineDownloadManager(ueberwacheNetz: false)
        let wahl = vorschau
        await m.setzeWahlQuelle { _ in wahl }
        await m.updateMeteredStatus(false)
        return m
    }

    private func suchKoerper(_ m: OrteMitschnitt) -> [String] {
        m.alle.filter { $0.request.url?.path.hasSuffix("/api/search/metadata") == true }
            .map { String(decoding: $0.koerper, as: UTF8.self) }
    }

    @Test func favoritenLoestUeberSucheAuf() async throws {
        let lauf = UUID().uuidString.prefix(6)
        let mitschnitt = OrteMitschnitt()
        OrteMockURLProtocol.registriere(host: host) { req, body in
            guard req.url?.path.hasSuffix("/api/search/metadata") == true else { return (200, Data("DATEI".utf8)) }
            mitschnitt.merke(req, body)
            let ersteSeite = !String(decoding: body, as: UTF8.self).contains("\"cursor\"")
            return (200, ersteSeite ? Self.seite(["a-\(lauf)", "b-\(lauf)"], weiter: "c1") : Self.seite(["c-\(lauf)"], weiter: nil))
        }
        defer { OrteMockURLProtocol.entferne(host: host) }
        let c = try container([OfflinePin(kind: .favoriten, targetId: "eigene", displayName: "Favorites")])

        await (await lader()).syncOfflineAlbums(container: c, apiClient: OrteMockURLProtocol.client(host: host), force: true)

        let pin = try #require(try pins(c)["favoriten:eigene"])
        #expect(pin.assetIds == ["a-\(lauf)", "b-\(lauf)", "c-\(lauf)"])
        #expect(pin.lastError == nil)
        #expect(suchKoerper(mitschnitt).first?.contains("\"isFavorite\"") == true)
    }

    @Test func personLoestAuf() async throws {
        let lauf = UUID().uuidString.prefix(6)
        let mitschnitt = OrteMitschnitt()
        OrteMockURLProtocol.registriere(host: host) { req, body in
            let pfad = req.url?.path ?? ""
            if pfad.hasSuffix("/api/people") { return (200, Self.personen(["p1"])) }
            guard pfad.hasSuffix("/api/search/metadata") else { return (200, Data("DATEI".utf8)) }
            mitschnitt.merke(req, body)
            return (200, Self.seite(["x-\(lauf)"], weiter: nil))
        }
        defer { OrteMockURLProtocol.entferne(host: host) }
        let c = try container([OfflinePin(kind: .person, targetId: "p1", displayName: "Mia")])

        await (await lader()).syncOfflineAlbums(container: c, apiClient: OrteMockURLProtocol.client(host: host), force: true)

        let pin = try #require(try pins(c)["person:p1"])
        #expect(pin.assetIds == ["x-\(lauf)"])
        #expect(suchKoerper(mitschnitt).first?.contains("\"personIds\"") == true)
    }

    @Test func personWegWirdGemeldet() async throws {
        OrteMockURLProtocol.registriere(host: host) { req, _ in
            let pfad = req.url?.path ?? ""
            if pfad.hasSuffix("/api/people") { return (200, Self.personen(["andere"])) }
            if pfad.hasSuffix("/api/search/metadata") { return (200, Self.seite([], weiter: nil)) }
            return (200, Data("DATEI".utf8))
        }
        defer { OrteMockURLProtocol.entferne(host: host) }
        let alt = OfflinePin(kind: .person, targetId: "p1", displayName: "Mia", assetIds: ["alt"])
        let c = try container([alt])

        await (await lader()).syncOfflineAlbums(container: c, apiClient: OrteMockURLProtocol.client(host: host), force: true)

        let pin = try #require(try pins(c)["person:p1"])
        #expect(pin.lastError == OfflineDownloadManager.personWegText)
        #expect(pin.assetIds == ["alt"])
    }

    @Test func fehlerBehaeltMitgliedschaft() async throws {
        OrteMockURLProtocol.registriere(host: host) { req, _ in
            if req.url?.path.hasSuffix("/api/search/metadata") == true { return (500, Data()) }
            return (200, Data("DATEI".utf8))
        }
        defer { OrteMockURLProtocol.entferne(host: host) }
        let c = try container([OfflinePin(kind: .favoriten, targetId: "eigene", displayName: "Favorites", assetIds: ["alt"])])

        await (await lader()).syncOfflineAlbums(container: c, apiClient: OrteMockURLProtocol.client(host: host), force: true)

        let pin = try #require(try pins(c)["favoriten:eigene"])
        #expect(pin.assetIds == ["alt"])
        #expect(pin.lastError != nil)
    }

    @Test func reihenfolgeQuelleBestimmtLadereihenfolge() async throws {
        let lauf = UUID().uuidString.prefix(6)
        let mitschnitt = OrteMitschnitt()
        OrteMockURLProtocol.registriere(host: host) { req, body in
            let pfad = req.url?.path ?? ""
            if pfad.hasSuffix("/api/people") { return (200, Self.personen(["p1"])) }
            if pfad.hasSuffix("/api/search/metadata") {
                let person = String(decoding: body, as: UTF8.self).contains("personIds")
                return (200, Self.seite([person ? "p-\(lauf)" : "f-\(lauf)"], weiter: nil))
            }
            mitschnitt.merke(req, body)
            return (200, Data("DATEI".utf8))
        }
        defer { OrteMockURLProtocol.entferne(host: host) }
        let favoriten = OfflinePin(kind: .favoriten, targetId: "eigene", displayName: "Favorites")
        favoriten.pinnedAt = Date(timeIntervalSince1970: 0)
        let person = OfflinePin(kind: .person, targetId: "p1", displayName: "Mia")
        person.pinnedAt = Date(timeIntervalSince1970: 10)
        let c = try container([favoriten, person])
        let m = await lader()
        // Person zuerst, obwohl später angelegt.
        await m.setzeReihenfolgeQuelle { eintraege in
            eintraege.sorted { $0.kind == .person && $1.kind != .person }.map(\.pinId)
        }

        await m.syncOfflineAlbums(container: c, apiClient: OrteMockURLProtocol.client(host: host), force: true)

        let pfade = mitschnitt.alle.compactMap { $0.request.url?.path }
        #expect(pfade.count == 2)
        #expect(pfade.first?.contains("p-\(lauf)") == true)
    }

    /// Review-Befund: Eine durch Entdoppeln leere Quelle galt sofort als fertig —
    /// auch wenn die frühere Quelle das gemeinsame Foto gar nicht laden konnte.
    @Test func entdoppelteQuelleNichtFertigWennFruehereScheitert() async throws {
        let lauf = UUID().uuidString.prefix(6)
        let gemeinsam = "s-\(lauf)"
        OrteMockURLProtocol.registriere(host: host) { req, _ in
            let pfad = req.url?.path ?? ""
            if pfad.hasSuffix("/api/people") { return (200, Self.personen(["p1"])) }
            if pfad.hasSuffix("/api/search/metadata") { return (200, Self.seite([gemeinsam], weiter: nil)) }
            return (500, Data())
        }
        defer { OrteMockURLProtocol.entferne(host: host) }
        let favoriten = OfflinePin(kind: .favoriten, targetId: "eigene", displayName: "Favorites")
        favoriten.pinnedAt = Date(timeIntervalSince1970: 0)
        let person = OfflinePin(kind: .person, targetId: "p1", displayName: "Mia")
        person.pinnedAt = Date(timeIntervalSince1970: 10)
        let c = try container([favoriten, person])

        await (await lader()).syncOfflineAlbums(container: c, apiClient: OrteMockURLProtocol.client(host: host), force: true)

        let p = try #require(try pins(c)["person:p1"])
        #expect(p.lastCompletedAt == nil)
        #expect(p.lastError != nil)
    }
}
