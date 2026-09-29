import Foundation
import SwiftData
import os

/// Zugriff auf die ``OfflinePin``-Vermerke.
///
/// Bewusst zustandslos und contextfrei: Jede Funktion bekommt den `ModelContext`
/// gereicht, damit derselbe Code aus einer View (MainActor-Context) und aus dem
/// Sync-Hintergrund (eigener Background-Context) laufen kann.
enum OfflinePinStore {

    // MARK: - Lesen

    static func pin(kind: OfflinePinKind, targetId: String, in context: ModelContext) -> OfflinePin? {
        let id = OfflinePin.pinId(kind: kind, targetId: targetId)
        var descriptor = FetchDescriptor<OfflinePin>(predicate: #Predicate { $0.pinId == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    static func isPinned(kind: OfflinePinKind, targetId: String, in context: ModelContext) -> Bool {
        pin(kind: kind, targetId: targetId, in: context) != nil
    }

    static func allPins(in context: ModelContext) -> [OfflinePin] {
        let descriptor = FetchDescriptor<OfflinePin>(sortBy: [SortDescriptor(\.pinnedAt)])
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Alle Asset-IDs, die von irgendeinem Vermerk gehalten werden.
    ///
    /// Das ist die Menge, die der ``LocalFileCacheManager`` beim Aufräumen verschonen
    /// muss — sonst räumte er Dateien weg, die der ``OfflineDownloadManager`` im
    /// nächsten Lauf sofort wieder lüde.
    static func allPinnedAssetIds(in context: ModelContext) -> Set<String> {
        var ids = Set<String>()
        for pin in allPins(in: context) {
            ids.formUnion(pin.assetIds)
        }
        return ids
    }

    // MARK: - Schreiben

    /// Legt einen Vermerk an oder aktualisiert einen bestehenden. Speichert nicht —
    /// das übernimmt der Aufrufer, der oft noch mehr zu schreiben hat.
    @discardableResult
    static func pin(
        kind: OfflinePinKind,
        targetId: String,
        displayName: String,
        assetIds: [String]? = nil,
        in context: ModelContext
    ) -> OfflinePin {
        if let existing = pin(kind: kind, targetId: targetId, in: context) {
            existing.displayName = displayName
            if let assetIds {
                existing.assetIds = assetIds
                existing.lastResolvedAt = Date()
            }
            return existing
        }
        let new = OfflinePin(kind: kind, targetId: targetId, displayName: displayName, assetIds: assetIds ?? [])
        if assetIds != nil { new.lastResolvedAt = Date() }
        context.insert(new)
        return new
    }

    /// Entfernt den Vermerk. Die Dateien selbst räumt der ``LocalFileCacheManager``
    /// weg — der Aufrufer stößt das an, weil er weiß, ob das sofort passieren soll.
    static func unpin(kind: OfflinePinKind, targetId: String, in context: ModelContext) {
        guard let existing = pin(kind: kind, targetId: targetId, in: context) else { return }
        context.delete(existing)
    }

    // MARK: - Bedienung aus der Oberfläche

    /// Pinnt oder entpinnt und stößt an, was daraus folgt.
    ///
    /// Beides an einer Stelle, weil jede Ansicht sonst die Hälfte vergäße — das
    /// Entpinnen tat vor dieser Zusammenfassung genau das: Flag umsetzen, Dateien liegen
    /// lassen. Der `force`-Lauf beim Pinnen umgeht den 15-Minuten-Cooldown; wer den
    /// Schalter drückt, will nicht bis zu einer Viertelstunde warten.
    @MainActor
    static func setPinned(
        _ pinned: Bool,
        kind: OfflinePinKind,
        targetId: String,
        displayName: String,
        assetIds: [String]? = nil,
        context: ModelContext,
        apiClient: ImmichAPIClient
    ) {
        let container = context.container

        if pinned {
            pin(kind: kind, targetId: targetId, displayName: displayName, assetIds: assetIds, in: context)
            if kind == .album { setLegacyFlag(true, albumId: targetId, in: context) }
            try? context.save()

            Task.detached(priority: .background) {
                await OfflineDownloadManager.shared.syncOfflineAlbums(
                    container: container,
                    apiClient: apiClient,
                    force: true
                )
            }
        } else {
            unpin(kind: kind, targetId: targetId, in: context)
            if kind == .album { setLegacyFlag(false, albumId: targetId, in: context) }
            try? context.save()

            let cacheDays = AppEnvironment.defaults.integer(forKey: "localFileCacheDays")
            Task.detached(priority: .background) {
                await LocalFileCacheManager.shared.evictUnpinned(container: container, cacheDays: cacheDays)
            }
        }
    }

    /// Hält `CachedAlbum.isMarkedForOffline` mit dem Vermerk gleich.
    ///
    /// Das Feld ist seit V9 nicht mehr die Quelle der Wahrheit, aber es steht noch am
    /// Model (Entfernen änderte die Checksumme von `CachedAlbum` und damit alle
    /// Schema-Versionen). Solange es da ist, soll es nicht lügen.
    private static func setLegacyFlag(_ value: Bool, albumId: String, in context: ModelContext) {
        var descriptor = FetchDescriptor<CachedAlbum>(predicate: #Predicate { $0.albumId == albumId })
        descriptor.fetchLimit = 1
        guard let album = try? context.fetch(descriptor).first else { return }
        album.isMarkedForOffline = value
    }

    // MARK: - Übernahme der alten Flags

    /// Übernimmt einmalig `CachedAlbum.isMarkedForOffline` in echte Vermerke.
    ///
    /// Vor V9 war das Flag am Album die einzige Quelle. Nach der Übernahme wird es nicht
    /// mehr gelesen; es bleibt nur deshalb am Model stehen, weil sein Entfernen die
    /// Checksumme von `CachedAlbum` ändern und damit alle Schema-Versionen brechen würde.
    ///
    /// Idempotent: Ein bereits vorhandener Vermerk wird nicht überschrieben — sonst
    /// verlöre ein Album beim nächsten Start die aufgelösten Asset-IDs, die es
    /// inzwischen gesammelt hat.
    /// - Returns: Anzahl der neu angelegten Vermerke.
    @discardableResult
    static func migrateLegacyFlags(in context: ModelContext) -> Int {
        let descriptor = FetchDescriptor<CachedAlbum>(
            predicate: #Predicate<CachedAlbum> { $0.isMarkedForOffline == true }
        )
        guard let legacy = try? context.fetch(descriptor), !legacy.isEmpty else { return 0 }

        var created = 0
        for album in legacy where !isPinned(kind: .album, targetId: album.albumId, in: context) {
            let pin = OfflinePin(
                kind: .album,
                targetId: album.albumId,
                displayName: album.albumName,
                assetIds: album.assetIds
            )
            // Die IDs stammen aus dem letzten Offline-Lauf und sind damit echt
            // aufgelöst — sonst hielte `evictExpired` sie ab sofort für unbekannt und
            // löschte die bereits geladenen Originale, bevor der erste Lauf unter V9
            // sie neu auflösen kann.
            if !album.assetIds.isEmpty { pin.lastResolvedAt = Date() }
            context.insert(pin)
            created += 1
        }

        if created > 0 {
            try? context.save()
            AppLogger.cache.info("OfflinePinStore: \(created) Alt-Markierung(en) in Offline-Vermerke übernommen")
        }
        return created
    }
}
