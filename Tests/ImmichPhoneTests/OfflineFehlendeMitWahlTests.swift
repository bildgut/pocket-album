import Foundation
import SwiftData
import Testing
@testable import ImmichPhone

@Suite("Offline: fehlende Dateien mit Wahl")
@MainActor
struct OfflineFehlendeMitWahlTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(
            for: Schema(versionedSchema: ImmichMacMigrationPlan.currentSchema),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
    }

    private func asset(_ id: String, video: Bool = false, datum: String = "2024-01-15",
                       pfad: String? = nil, geloescht: Bool = false) -> CachedAsset {
        let a = CachedAsset(from: Asset(
            id: id, type: video ? .video : .image, originalFileName: "\(id).x",
            fileCreatedAt: "\(datum)T10:00:00.000Z", fileModifiedAt: "\(datum)T10:00:00.000Z",
            isFavorite: false))
        a.localFilePath = pfad
        a.isTrashed = geloescht
        return a
    }

    @Test func fotosZuerstDannVideosJeweilsNeuesteZuerst() throws {
        let ctx = try context()
        ctx.insert(asset("v-alt", video: true, datum: "2020-01-01"))
        ctx.insert(asset("f-alt", datum: "2021-01-01"))
        ctx.insert(asset("v-neu", video: true, datum: "2024-01-01"))
        ctx.insert(asset("f-neu", datum: "2023-01-01"))
        try ctx.save()

        let posten = OfflineDownloadManager.fehlendeDateien(
            for: ["v-alt", "f-alt", "v-neu", "f-neu"], in: ctx, wahl: OfflineWahl())
        #expect(posten.map(\.assetId) == ["f-neu", "f-alt", "v-neu", "v-alt"])
        #expect(posten.map(\.fassung) == [.vorschau, .vorschau, .klein, .klein])
        #expect(posten.first?.monthKey == "2023-01")
    }

    @Test func videosKeineFehlenNicht() throws {
        let ctx = try context()
        ctx.insert(asset("f")); ctx.insert(asset("v", video: true)); try ctx.save()
        let wahl = OfflineWahl(fotos: .vorschau, videos: .keine, mobilfunk: false)
        #expect(OfflineDownloadManager.fehlendeDateien(for: ["f", "v"], in: ctx, wahl: wahl).map(\.assetId) == ["f"])
    }

    @Test func vorhandenesOriginalReichtAuchFuerVorschau() throws {
        let ctx = try context()
        ctx.insert(asset("f", pfad: "2024-01/f.heic"))
        ctx.insert(asset("v", video: true, pfad: "2024-01/v.mov"))
        try ctx.save()
        #expect(OfflineDownloadManager.fehlendeDateien(for: ["f", "v"], in: ctx, wahl: OfflineWahl()).isEmpty)
    }

    @Test func kleinereFassungWirdFuerOriginalNachgeladen() throws {
        let ctx = try context()
        ctx.insert(asset("f", pfad: "2024-01/f.vorschau.jpg"))
        ctx.insert(asset("v", video: true, pfad: "2024-01/v.klein.mp4"))
        ctx.insert(asset("g", pfad: "2024-01/g.vorschau.jpg"))
        try ctx.save()
        let original = OfflineWahl(fotos: .original, videos: .original, mobilfunk: false)
        let posten = OfflineDownloadManager.fehlendeDateien(for: ["f", "v", "g"], in: ctx, wahl: original)
        #expect(Set(posten.map(\.assetId)) == ["f", "v", "g"])
        #expect(posten.allSatisfy { $0.fassung == .original })
        // Mit Wahl „Vorschau“ reicht die vorhandene Vorschau.
        #expect(OfflineDownloadManager.fehlendeDateien(for: ["g"], in: ctx, wahl: OfflineWahl()).isEmpty)
    }

    @Test func geloeschteUndUnbekannteFallenWeg() throws {
        let ctx = try context()
        ctx.insert(asset("weg", geloescht: true)); ctx.insert(asset("da")); try ctx.save()
        let posten = OfflineDownloadManager.fehlendeDateien(for: ["weg", "da", "unbekannt", "da"], in: ctx, wahl: OfflineWahl())
        #expect(posten.map(\.assetId) == ["da"])
    }

    @Test func gleichesDatumNachIdStabil() throws {
        let ctx = try context()
        for id in ["c", "a", "b"] { ctx.insert(asset(id)) }
        try ctx.save()
        #expect(OfflineDownloadManager.fehlendeDateien(for: ["c", "a", "b"], in: ctx, wahl: OfflineWahl()).map(\.assetId) == ["a", "b", "c"])
    }

    @Test func mehrAls500Ids() throws {
        let ctx = try context()
        let ids = (0..<1_203).map { String(format: "id-%04d", $0) }
        for id in ids { ctx.insert(asset(id)) }
        try ctx.save()
        #expect(OfflineDownloadManager.fehlendeDateien(for: ids, in: ctx, wahl: OfflineWahl()).count == 1_203)
    }
}
