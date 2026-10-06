import Foundation
import SwiftData
import Testing
@testable import ImmichPhone

// `PhoneOfflineModel` liegt in Sources/ImmichPhone und ist damit vom Mac-Testziel
// strukturell nicht erreichbar — dieser Test ist der erste, der den iOS-Target
// benutzt. Geprüft wird ausschließlich die Ableitung der Abzeichen aus den
// Vermerken; `toggle(album:context:apiClient:)` bleibt außen vor, weil es über
// `OfflinePinStore.setPinned` einen echten Download anstößt.
//
// Der Container ist derselbe wie im Mac-Ziel (`OfflinePinTests`): das aktuelle
// Schema, nur im Arbeitsspeicher. Absichtlich ohne `migrationPlan` — ein frischer
// In-Memory-Store hat nichts zu migrieren.

@MainActor
private func makeContext() throws -> ModelContext {
    let container = try ModelContainer(
        for: Schema(versionedSchema: ImmichMacMigrationPlan.currentSchema),
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    return ModelContext(container)
}

@Suite("PhoneOfflineModel")
@MainActor
struct PhoneOfflineModelTests {

    @Test("Ohne Vermerke ist jedes Abzeichen .cloud")
    func frischesModellLiefertCloud() throws {
        let model = PhoneOfflineModel()
        #expect(model.badge(for: "a-1") == .cloud)
        #expect(model.badge(for: "beliebig") == .cloud)

        // Auch nach einem refresh gegen einen leeren Store — der Standardwert darf
        // nicht davon abhängen, ob je gelesen wurde.
        let ctx = try makeContext()
        model.refresh(context: ctx)
        #expect(model.badges.isEmpty)
        #expect(model.badge(for: "a-1") == .cloud)
    }

    @Test("Ein gepinntes Album ohne abgeschlossenen Lauf ist .pending, andere bleiben .cloud")
    func gepinntesAlbumIstPending() throws {
        let ctx = try makeContext()
        // `pin` statt `setPinned`: Letzteres stößt über einen Task.detached einen
        // echten Offline-Download gegen den Server an.
        OfflinePinStore.pin(kind: .album, targetId: "a-1", displayName: "Urlaub", in: ctx)
        try ctx.save()

        let model = PhoneOfflineModel()
        model.refresh(context: ctx)

        #expect(model.badge(for: "a-1") == .pending)
        #expect(model.badge(for: "a-2") == .cloud)
    }

    @Test("Ein abgeschlossener Lauf macht das Abzeichen .offline")
    func abgeschlossenerLaufIstOffline() throws {
        let ctx = try makeContext()
        let pin = OfflinePinStore.pin(kind: .album, targetId: "a-1", displayName: "Urlaub", in: ctx)
        pin.lastCompletedAt = Date()
        try ctx.save()

        let model = PhoneOfflineModel()
        model.refresh(context: ctx)

        #expect(model.badge(for: "a-1") == .offline)
    }

    @Test("Ein Fehler schlägt den abgeschlossenen Lauf und ergibt .failed")
    func fehlerSchlaegtAbgeschlossenenLauf() throws {
        let ctx = try makeContext()
        let pin = OfflinePinStore.pin(kind: .album, targetId: "a-1", displayName: "Urlaub", in: ctx)
        pin.lastCompletedAt = Date()
        pin.lastError = "Netz weg"
        try ctx.save()

        let model = PhoneOfflineModel()
        model.refresh(context: ctx)

        #expect(model.badge(for: "a-1") == .failed)
    }

    @Test("Vermerke für Smart Alben landen nicht im Album-Abzeichen")
    func smartAlbumVermerkWirdUebergangen() throws {
        let ctx = try makeContext()
        // Gleiche Ziel-ID wie ein Album hätte — `refresh` filtert auf `kind == .album`,
        // sonst überschriebe ein Smart-Album-Vermerk das Abzeichen eines Albums.
        OfflinePinStore.pin(kind: .smartAlbum, targetId: "a-1", displayName: "Rollend", in: ctx)
        try ctx.save()

        let model = PhoneOfflineModel()
        model.refresh(context: ctx)

        #expect(model.badges.isEmpty)
        #expect(model.badge(for: "a-1") == .cloud)
    }

    @Test("Ein entfernter Vermerk verschwindet beim nächsten refresh")
    func entfernterVermerkVerschwindet() throws {
        let ctx = try makeContext()
        OfflinePinStore.pin(kind: .album, targetId: "a-1", displayName: "Urlaub", in: ctx)
        try ctx.save()

        let model = PhoneOfflineModel()
        model.refresh(context: ctx)
        #expect(model.badge(for: "a-1") == .pending)

        // `refresh` baut die Abbildung neu auf, statt in die alte hineinzuschreiben —
        // ein additives Update ließe das Abzeichen nach dem Entpinnen stehen.
        OfflinePinStore.unpin(kind: .album, targetId: "a-1", in: ctx)
        try ctx.save()
        model.refresh(context: ctx)

        #expect(model.badge(for: "a-1") == .cloud)
        #expect(model.badges.isEmpty)
    }

    @Test("Freigeben löscht die gemerkte Wahl")
    func freigebenLoeschtWahl() throws {
        let ctx = try makeContext()
        let speicher = OfflineWahlSpeicher(defaults: UserDefaults(suiteName: "PhoneOfflineModelTests-\(UUID().uuidString)")!)
        let album = Album(
            id: "a-1", albumName: "A", description: nil, createdAt: "", updatedAt: "",
            startDate: nil, endDate: nil, assetCount: 0, albumThumbnailAssetId: nil,
            shared: nil, hasSharedLink: nil, owner: nil)
        let pinId = OfflinePin.pinId(kind: .album, targetId: "a-1")
        OfflinePinStore.pin(kind: .album, targetId: "a-1", displayName: "A", in: ctx)
        try ctx.save()
        speicher.setze(OfflineWahl(), fuer: pinId)

        let model = PhoneOfflineModel()
        // Freigeben geht nicht ins Netz; der Client wird nur durchgereicht.
        model.gibFrei(album: album, context: ctx,
                      apiClient: OrteMockURLProtocol.client(host: "nie.test"), speicher: speicher)

        #expect(speicher.wahl(fuer: pinId) == nil)
        #expect(model.badge(for: "a-1") == .cloud)
    }

    @Test("Aufheben aus den Einstellungen räumt Vermerk, Wahl und WLAN-Marke")
    func aufhebenRaeumtAlles() throws {
        let ctx = try makeContext()
        let speicher = OfflineWahlSpeicher(defaults: UserDefaults(suiteName: "PhoneOfflineModelTests-\(UUID().uuidString)")!)
        let pinId = OfflinePin.pinId(kind: .album, targetId: "a-9")
        OfflinePinStore.pin(kind: .album, targetId: "a-9", displayName: "B", in: ctx)
        try ctx.save()
        speicher.setze(OfflineWahl(), fuer: pinId)
        OfflineSyncProgress.shared.wartetAufWLAN.insert(pinId)

        PhoneOfflineModel.hebeAuf(kind: .album, targetId: "a-9", displayName: "B", context: ctx,
                                  apiClient: OrteMockURLProtocol.client(host: "nie.test"), speicher: speicher)

        #expect(speicher.wahl(fuer: pinId) == nil)
        #expect(!OfflineSyncProgress.shared.wartetAufWLAN.contains(pinId))
        #expect(!OfflinePinStore.allPins(in: ctx).contains { $0.targetId == "a-9" })
    }
}
