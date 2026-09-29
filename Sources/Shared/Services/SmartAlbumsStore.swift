import Foundation
import SwiftData

// MARK: - Codable records (JSON-Repräsentation von SmartAlbum & SmartAlbumFolder)

struct SmartAlbumFolderRecord: Codable {
    var id: UUID
    var name: String
    var sortIndex: Int
    var createdAt: Date

    init(from folder: SmartAlbumFolder) {
        id        = folder.id
        name      = folder.name
        sortIndex = folder.sortIndex
        createdAt = folder.createdAt
    }
}

struct SmartAlbumRecord: Codable {
    var id: UUID
    var name: String
    var iconSymbol: String
    var matchModeRaw: String
    var sortOrderRaw: String
    var rulesData: Data              // JSON-encoded [SmartAlbumRuleEntry], im Sidecar Base64
    var createdAt: Date
    var folderID: UUID?
    var sortIndex: Int
    var mirrorAlbumId: String?
    var mirrorLastSyncedAt: Date?
    var mirrorLastSyncedIdsData: Data?
    var mirrorSyncStatusRaw: String?
    var mirrorLastError: String?

    init(from album: SmartAlbum) {
        id                      = album.id
        name                    = album.name
        iconSymbol              = album.iconSymbol
        matchModeRaw            = album.matchModeRaw
        sortOrderRaw            = album.sortOrderRaw
        rulesData               = album.rulesData
        createdAt               = album.createdAt
        folderID                = album.folderID
        sortIndex               = album.sortIndex
        mirrorAlbumId           = album.mirrorAlbumId
        mirrorLastSyncedAt      = album.mirrorLastSyncedAt
        mirrorLastSyncedIdsData = album.mirrorLastSyncedIdsData
        mirrorSyncStatusRaw     = album.mirrorSyncStatusRaw
        mirrorLastError         = album.mirrorLastError
    }
}

struct SmartAlbumsSidecar: Codable {
    var folders: [SmartAlbumFolderRecord]
    var albums: [SmartAlbumRecord]
}

// MARK: - SmartAlbumsStore

/// Hält einen JSON-Sidecar (`smart-albums.json`) in
/// `~/Library/Application Support/ImmichMac/` aktuell — analog zu ``SyncPairingsStore``.
///
/// **Zweck:** Smart Alben sind rein lokal; ein Store-Reset (fehlgeschlagene Migration,
/// Entwickler-Reset) löscht sie unwiederbringlich (passiert am 2026-07-06). Der Sidecar
/// stellt Alben und Ordner beim nächsten App-Start automatisch wieder her.
///
/// **Verwendung:**
/// - Nach jedem Insert/Update/Delete eines SmartAlbum/SmartAlbumFolder:
///   `SmartAlbumsStore.shared.exportAll(from: modelContext)`
///   (Mirror-Sync-Statusfelder lösen bewusst keinen Export aus — zu hohe Schreiblast.)
/// - Beim App-Start, nachdem der Container initialisiert wurde:
///   `SmartAlbumsStore.shared.importIfNeeded(into: ctx)` auf dem MainActor aufrufen,
///   danach `seedIfMissing(from:)` für den Erst-Export bestehender Alben.
final class SmartAlbumsStore: @unchecked Sendable {

    static let shared = SmartAlbumsStore()
    private init() { overrideURL = nil }

    /// Für Tests: schreibt/liest an einer beliebigen Datei-URL.
    init(fileURL: URL) { overrideURL = fileURL }

    // MARK: - Path

    static let fileName = "smart-albums.json"

    private let overrideURL: URL?

    /// Liegt bewusst unter ``AppEnvironment/supportDirectory`` und nicht direkt unter
    /// `~/Library/Application Support/ImmichMac/`: Die Unit-Tests benutzen ImmichMac.app
    /// als TEST_HOST, d.h. die Window-Szene mit ihren Sidecar-Aufrufen läuft bei jedem
    /// Testlauf mit. Mit dem direkten Pfad würde ein Testlauf den echten Sidecar des
    /// Nutzers lesen — und bei jeder Mutation mit Testdaten überschreiben.
    var jsonURL: URL {
        if let overrideURL { return overrideURL }
        return AppEnvironment.supportDirectory.appending(path: Self.fileName)
    }

    // MARK: - Export (write)

    /// Persistiert alle aktuellen Smart Alben & Ordner in den JSON-Sidecar.
    /// Darf auf jedem Thread aufgerufen werden; der Schreibvorgang ist synchron aber schnell.
    func export(albums: [SmartAlbum], folders: [SmartAlbumFolder]) {
        let sidecar = SmartAlbumsSidecar(
            folders: folders.map { SmartAlbumFolderRecord(from: $0) },
            albums: albums.map { SmartAlbumRecord(from: $0) }
        )
        let url = jsonURL
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(sidecar)
            // `.atomic` legt eine temporäre Datei im Zielverzeichnis an — fehlt das
            // Verzeichnis, schlägt der Schreibvorgang fehl (NSCocoaErrorDomain 4).
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            AppLogger.app.debug("SmartAlbumsStore: \(sidecar.albums.count) Alben / \(sidecar.folders.count) Ordner in JSON gesichert.")
        } catch {
            AppLogger.app.error("SmartAlbumsStore: Export nach \(url.path) fehlgeschlagen: \(error)")
        }
    }

    /// Convenience: lädt alle Smart Alben & Ordner aus dem Context und exportiert sie.
    /// An jeder Mutationsstelle nach dem `save()` aufrufen.
    @MainActor
    func exportAll(from ctx: ModelContext) {
        // Ein gescheiterter Fetch darf **nicht** wie ein leerer Bestand aussehen.
        //
        // `export` schreibt die Datei vollständig neu; mit `?? []` löschte ein
        // Lesefehler die Sicherung sämtlicher Smart Alben — und diese Funktion hängt
        // an jeder Mutation (Anlegen, Umbenennen, Verschieben, Löschen, Regeländerung),
        // wird also oft ausgeführt.
        //
        // Der leere Bestand selbst ist dagegen ein gültiger Stand: Wer sein letztes
        // Smart Album löscht, soll auch einen leeren Sidecar bekommen. Deshalb wird
        // hier unterschieden statt pauschal auf „nicht leer" geprüft.
        //
        // `seedIfMissing` weiter unten schützt genau davor schon — „ein vorhandener
        // Sidecar wird nie von einem (evtl. gerade resetteten) Store überschrieben" —,
        // nur stand der Schutz bisher allein dort.
        guard let albums = try? ctx.fetch(FetchDescriptor<SmartAlbum>()),
              let folders = try? ctx.fetch(FetchDescriptor<SmartAlbumFolder>()) else {
            AppLogger.app.error(
                "SmartAlbumsStore: Export übersprungen — der Bestand ließ sich nicht lesen. Der vorhandene Sidecar bleibt stehen."
            )
            return
        }
        export(albums: albums, folders: folders)
    }

    /// Erst-Seed beim App-Start: exportiert den Bestand nur, wenn noch kein Sidecar
    /// existiert und der Store Daten enthält. So sind bestehende Alben sofort
    /// geschützt, ohne dass eine Mutation nötig ist — und ein vorhandener Sidecar
    /// wird nie von einem (evtl. gerade resetteten) Store überschrieben.
    @MainActor
    func seedIfMissing(from ctx: ModelContext) {
        guard !FileManager.default.fileExists(atPath: jsonURL.path) else { return }
        let albums  = (try? ctx.fetch(FetchDescriptor<SmartAlbum>())) ?? []
        let folders = (try? ctx.fetch(FetchDescriptor<SmartAlbumFolder>())) ?? []
        guard !albums.isEmpty || !folders.isEmpty else { return }
        export(albums: albums, folders: folders)
        AppLogger.app.info("SmartAlbumsStore: Erst-Seed des JSON-Sidecars (\(albums.count) Alben, \(folders.count) Ordner).")
    }

    // MARK: - Personen-Merge

    /// Schreibt in allen Smart Alben die Personen-Regeln von `sourceIds` auf `targetId` um
    /// und persistiert das Ergebnis (SwiftData + Sidecar).
    ///
    /// Nach `POST /api/people/{id}/merge` existieren die Quell-Personen auf dem Server nicht
    /// mehr. Eine ``SmartAlbumRule/containsPerson(id:name:)``-Regel darauf würde ab dann
    /// stillschweigend keine Treffer mehr liefern — ohne Fehler, ohne Hinweis.
    ///
    /// - Important: Es dürfen **nur** die tatsächlich erfolgreich zusammengeführten IDs
    ///   übergeben werden, also `results.filter(\.success).map(\.id)` aus der
    ///   `[BulkIdResponse]`-Antwort von `ImmichAPIClient.mergePeople(into:sourceIds:)`.
    ///   Ein Merge kann teilweise fehlschlagen; würde man alle angefragten IDs übergeben,
    ///   bögen Regeln auf Personen um, die es noch gibt.
    ///
    /// - Parameters:
    ///   - sourceIds: Erfolgreich zusammengeführte Quell-IDs. `targetId` darin wird ignoriert.
    ///   - targetId: ID der Zielperson.
    ///   - targetName: Anzeigename der Zielperson für das Regel-Label. `nil` behält den
    ///     bisherigen Namen der Regel bei.
    /// - Returns: Anzahl der geänderten Alben (0, wenn nichts betroffen war).
    @MainActor
    @discardableResult
    func rewritePersonIds(
        from sourceIds: [String],
        to targetId: String,
        targetName: String? = nil,
        in ctx: ModelContext
    ) -> Int {
        // Die Zielperson selbst ist keine Quelle — sonst würde die Regel auf sich selbst
        // umgeschrieben und das Album unnötig als geändert markiert.
        let sources = Set(sourceIds).subtracting([targetId])
        guard !sources.isEmpty else { return 0 }

        let albums = (try? ctx.fetch(FetchDescriptor<SmartAlbum>())) ?? []
        guard !albums.isEmpty else { return 0 }

        var changed = 0
        for album in albums {
            let old = album.rules
            let new = old.rewritingPersonIds(from: sources, to: targetId, targetName: targetName)
            guard new != old else { continue }
            album.rules = new
            changed += 1
        }
        guard changed > 0 else { return 0 }

        do {
            try ctx.save()
        } catch {
            AppLogger.app.error("SmartAlbumsStore: Speichern nach Personen-Merge fehlgeschlagen: \(error)")
            ctx.rollback()
            return 0
        }

        exportAll(from: ctx)
        AppLogger.app.info("SmartAlbumsStore: \(changed) Smart Album(s) nach Personen-Merge auf \(targetId) umgeschrieben.")
        return changed
    }

    // MARK: - Import (read + restore)

    /// Liest den JSON-Sidecar und importiert fehlende Alben/Ordner in den übergebenen
    /// `ModelContext`. Bestehende Einträge werden nie doppelt eingefügt (Vergleich über `id`).
    ///
    /// - Returns: Anzahl wiederhergestellter Objekte (Alben + Ordner).
    @discardableResult
    @MainActor
    func importIfNeeded(into ctx: ModelContext) -> Int {
        guard FileManager.default.fileExists(atPath: jsonURL.path) else { return 0 }

        let sidecar: SmartAlbumsSidecar
        do {
            let data = try Data(contentsOf: jsonURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            sidecar = try decoder.decode(SmartAlbumsSidecar.self, from: data)
        } catch {
            AppLogger.app.error("SmartAlbumsStore: JSON konnte nicht gelesen werden: \(error)")
            return 0
        }

        guard !sidecar.albums.isEmpty || !sidecar.folders.isEmpty else { return 0 }

        let existingAlbumIds  = Set(((try? ctx.fetch(FetchDescriptor<SmartAlbum>())) ?? []).map(\.id))
        let existingFolderIds = Set(((try? ctx.fetch(FetchDescriptor<SmartAlbumFolder>())) ?? []).map(\.id))

        let missingFolders = sidecar.folders.filter { !existingFolderIds.contains($0.id) }
        let missingAlbums  = sidecar.albums.filter { !existingAlbumIds.contains($0.id) }
        guard !missingFolders.isEmpty || !missingAlbums.isEmpty else {
            AppLogger.app.debug("SmartAlbumsStore: Alle \(sidecar.albums.count) Alben / \(sidecar.folders.count) Ordner bereits im Store vorhanden.")
            return 0
        }

        for r in missingFolders {
            let folder = SmartAlbumFolder(id: r.id, name: r.name, sortIndex: r.sortIndex)
            folder.createdAt = r.createdAt
            ctx.insert(folder)
        }

        for r in missingAlbums {
            let album = SmartAlbum(id: r.id, name: r.name, iconSymbol: r.iconSymbol)
            album.matchModeRaw            = r.matchModeRaw
            album.sortOrderRaw            = r.sortOrderRaw
            album.rulesData               = r.rulesData
            album.createdAt               = r.createdAt
            album.folderID                = r.folderID
            album.sortIndex               = r.sortIndex
            album.mirrorAlbumId           = r.mirrorAlbumId
            album.mirrorLastSyncedAt      = r.mirrorLastSyncedAt
            album.mirrorLastSyncedIdsData = r.mirrorLastSyncedIdsData
            album.mirrorSyncStatusRaw     = r.mirrorSyncStatusRaw
            album.mirrorLastError         = r.mirrorLastError
            ctx.insert(album)
        }

        do {
            try ctx.save()
            AppLogger.app.info("SmartAlbumsStore: \(missingAlbums.count) Alben und \(missingFolders.count) Ordner aus JSON-Sidecar wiederhergestellt.")
        } catch {
            AppLogger.app.error("SmartAlbumsStore: Import-Save fehlgeschlagen: \(error)")
            return 0
        }

        return missingAlbums.count + missingFolders.count
    }
}
