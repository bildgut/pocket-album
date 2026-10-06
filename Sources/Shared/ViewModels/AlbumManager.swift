import Foundation
import SwiftData
import os

@Observable
@MainActor
final class AlbumManager {
    var albums: [Album] = []
    var sharedAlbums: [Album] = []
    
    private let apiClient: ImmichAPIClient
    private var modelContext: ModelContext?
    
    /// Monoton steigender Zähler — verhindert, dass eine langsame SwiftData-Cache-Task
    /// frische Server-Daten überschreibt (Race-Condition in loadAlbums).
    private var albumLoadGeneration = 0
    
    init(apiClient: ImmichAPIClient) {
        self.apiClient = apiClient
    }
    
    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
    }
    
    func loadAlbums() async {
        // Jede loadAlbums()-Runde bekommt eine neue Generation.
        // Die Cache-Task schreibt NUR, wenn keine frischeren Server-Daten angekommen sind.
        albumLoadGeneration &+= 1
        let generation = albumLoadGeneration
        loadAlbumsFromCache(generation: generation)

        do {
            let serverAlbums = try await apiClient.getAlbums()
            let serverShared = try await apiClient.getSharedAlbums()
            
            if let modelContext {
                let container = modelContext.container
                Task.detached(priority: .userInitiated) {
                    let bgContext = ModelContext(container)
                    bgContext.autosaveEnabled = false
                    
                    let descriptor = FetchDescriptor<CachedAlbum>()
                    // Beide Zweige unten setzen eine **vollständige** Liste voraus:
                    // Was nicht darin steht, gilt als neu und wird eingefügt; was
                    // darin steht und der Server nicht kennt, wird gelöscht. Ein
                    // leeres Ergebnis nach einem Lesefehler hieße also „keins davon
                    // ist bekannt" — jedes Serveralbum käme ein zweites Mal in den
                    // Store, und zwar dauerhaft: Beim nächsten Lauf trägt auch die
                    // Dublette eine albumId, die der Server kennt, die Löschschleife
                    // fasst sie nie an, und die Sidebar zeigt jedes Album doppelt.
                    //
                    // `applyAlbumSync` im SyncEngine macht denselben Abgleich und
                    // lässt den Fehler durch. Hier gab es dieselbe Absicherung nicht.
                    guard let existingAlbums = try? bgContext.fetch(descriptor) else {
                        AppLogger.api.error(
                            "Album-Abgleich übersprungen: lokale Albumliste nicht lesbar"
                        )
                        return
                    }
                    var existingDict: [String: CachedAlbum] = [:]
                    for album in existingAlbums {
                        existingDict[album.albumId] = album
                    }
                    
                    var seen = Set<String>()
                    
                    for album in serverAlbums {
                        seen.insert(album.id)
                        if let existing = existingDict[album.id] {
                            existing.update(from: album)
                            existing.isShared = false
                        } else {
                            bgContext.insert(CachedAlbum(from: album))
                        }
                    }
                    
                    for album in serverShared {
                        seen.insert(album.id)
                        if let existing = existingDict[album.id] {
                            existing.update(from: album)
                            existing.isShared = true
                        } else {
                            let cached = CachedAlbum(from: album)
                            cached.isShared = true
                            bgContext.insert(cached)
                        }
                    }
                    
                    for existing in existingAlbums {
                        if !seen.contains(existing.albumId) {
                            bgContext.delete(existing)
                        }
                    }
                    
                    do {
                        try bgContext.save()
                        // Heißt "ein Serverabgleich hat einmal geklappt", nicht "es
                        // gibt etwas zu zeigen" — wird auch gesetzt, wenn `serverAlbums`
                        // und `serverShared` beide leer sind (Server kennt schlicht
                        // keine Alben). Konsumenten wie `ConnectionManager.hasCachedData`
                        // dürfen das Flag also nicht als Beleg für vorhandene Cache-Inhalte
                        // lesen, nur als Beleg für einen einmal erfolgreichen Abgleich.
                        AppEnvironment.defaults.set(true, forKey: "hasCachedAlbums")
                    } catch {
                        AppLogger.api.error(
                            "Album-Abgleich nicht gespeichert: \(error.localizedDescription)"
                        )
                    }
                }
            }

            // Server-Daten ungültig machen ältere Cache-Schreibvorgänge
            albumLoadGeneration &+= 1
            // Ein eigenes Album kann zusätzlich geteilt sein — Immich liefert es
            // dann in beiden Antworten. „Geteilt" gewinnt, wie im Cache-Pfad
            // (partitioniert nach isShared) und in SyncEngine.applyAlbumSync.
            let sharedIds = Set(serverShared.map(\.id))
            albums = serverAlbums.filter { !sharedIds.contains($0.id) }
            sharedAlbums = serverShared
        } catch {
            AppLogger.api.error("Failed to load albums: \(error.localizedDescription)")
        }
    }

    func loadAlbumsFromCacheLocked() {
        loadAlbumsFromCache(generation: albumLoadGeneration)
    }

    private func loadAlbumsFromCache(generation: Int) {
        guard let modelContext else { return }
        let container = modelContext.container

        Task.detached(priority: .userInitiated) {
            let bgContext = ModelContext(container)
            bgContext.autosaveEnabled = false

            // Der Server liefert Alben nach Erstellungsdatum absteigend; nach Namen zu
            // sortieren ließ die Liste beim Offline-Gehen umspringen. `SortDescriptor`
            // vergleicht String-KeyPaths mit dem Standardvergleicher `.localizedStandard`
            // (lokalisiert, ziffernblockbewusst) — nicht byteweise. Hier ordnet er
            // trotzdem zeitlich richtig, weil `createdAt` vom Server immer als
            // UTC-ISO-8601 fester Breite kommt (dreistellige Millisekunden, kein
            // wechselndes Zonensuffix): Bei fester Breite fallen lexikographische und
            // zeitliche Ordnung zusammen. Anders bei EXIF-abgeleiteten Feldern wie
            // `Asset.fileCreatedAt`, die wechselnde Zonensuffixe tragen können — dort
            // trägt diese Begründung nicht.
            let descriptor = FetchDescriptor<CachedAlbum>(
                sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
            )
            let cached = (try? bgContext.fetch(descriptor)) ?? []
            guard !cached.isEmpty else { return }

            let owned = cached.filter { !$0.isShared }.map { $0.toAlbum() }
            let shared = cached.filter { $0.isShared }.map { $0.toAlbum() }

            await MainActor.run {
                // Nur schreiben, wenn sich die Generation nicht verändert hat —
                // d.h. Server-Daten sind noch nicht angekommen.
                guard self.albumLoadGeneration == generation else {
                    AppLogger.app.debug("[Albums] Cache write discarded (gen \(generation) < \(self.albumLoadGeneration)) — server was faster")
                    return
                }
                self.albums = owned
                self.sharedAlbums = shared
            }
        }
    }
}
