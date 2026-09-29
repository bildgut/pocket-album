import Foundation
import SQLite3
import os

/// SQLite-backed inverted index of album membership: asset → albums.
///
/// Immich exposes membership only per-asset (`GET /api/albums?assetId=`) or
/// per-album (`POST /api/search/metadata`), and the sync stream carries no album
/// data at all — so every "which albums is this photo in?" question was a live
/// round-trip. This index answers it locally.
///
/// **Deliberately a separate database file, not a table in `grid_index.sqlite`.**
/// `GridIndexStore` drops and rebuilds its table on every schema bump, which is
/// cheap there because it repopulates from SwiftData. This index cannot be
/// rebuilt locally at all — a full refill costs one network request per album
/// (hundreds of them). It must never become collateral damage of a grid schema
/// change, so it gets its own file and its own `user_version`.
final class AlbumMembershipStore: Sendable {

    /// Shared instance using the default Application Support path
    /// (redirected to a temp directory when running under XCTest).
    static let shared: AlbumMembershipStore = {
        let dbURL = AppEnvironment.supportDirectory.appending(path: "album_index.sqlite")
        return AlbumMembershipStore(path: dbURL.path)
    }()

    private let dbPath: String
    /// Serialised queue for UI reads — high priority so menus/sheets stay snappy.
    private let readQueue  = DispatchQueue(label: "com.ralksta.immichmac.albumindex.read",  qos: .userInitiated)
    /// Serialised queue for writes (indexer refills, write-through) — lower priority
    /// so a long refill doesn't starve reads. WAL lets readers run concurrently.
    private let writeQueue = DispatchQueue(label: "com.ralksta.immichmac.albumindex.write", qos: .utility)

    private nonisolated(unsafe) var writeDB: OpaquePointer?
    private nonisolated(unsafe) var readDB: OpaquePointer?

    // Convenience alias for write-side code (writeQueue only).
    private var db: OpaquePointer? { writeDB }

    init(path: String) {
        self.dbPath = path
        writeQueue.sync { self.openWriteConnection() }
        readQueue.sync  { self.openReadConnection()  }
    }

    deinit {
        if let writeDB { sqlite3_close(writeDB) }
        if let readDB  { sqlite3_close(readDB)  }
    }

    // MARK: - Schema

    private func openWriteConnection() {
        guard sqlite3_open(dbPath, &writeDB) == SQLITE_OK else {
            AppLogger.app.error("AlbumMembershipStore: failed to open write DB at \(self.dbPath)")
            return
        }
        migrateSchema()
    }

    private func openReadConnection() {
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(dbPath, &readDB, flags, nil) == SQLITE_OK else {
            AppLogger.app.error("AlbumMembershipStore: failed to open read DB at \(self.dbPath)")
            return
        }
        execOn(readDB, "PRAGMA journal_mode = WAL")
        execOn(readDB, "PRAGMA cache_size = -4000")
    }

    private func migrateSchema() {
        execOn(writeDB, "PRAGMA journal_mode = WAL")
        execOn(writeDB, "PRAGMA synchronous = NORMAL")
        execOn(writeDB, "PRAGMA cache_size = -8000")

        let currentVersion = 1
        let userVersion: Int32 = {
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil)
            sqlite3_step(stmt)
            let v = sqlite3_column_int(stmt, 0)
            sqlite3_finalize(stmt)
            return v
        }()

        if userVersion < currentVersion {
            // Nothing to preserve yet at v0 → v1. Future bumps should prefer ALTER
            // over DROP: refilling this table is expensive (one request per album).
            exec("PRAGMA user_version = \(currentVersion)")
        }

        // Composite PK ordered (album_id, asset_id) so replacing one album's rows is a
        // contiguous range delete. WITHOUT ROWID keeps the PK as the table itself.
        exec("""
            CREATE TABLE IF NOT EXISTS album_membership (
                album_id TEXT NOT NULL,
                asset_id TEXT NOT NULL,
                PRIMARY KEY (album_id, asset_id)
            ) WITHOUT ROWID
        """)

        // Serves the asset → albums lookup (context menu, add-to-album sheet).
        exec("""
            CREATE INDEX IF NOT EXISTS idx_membership_asset
            ON album_membership(asset_id)
        """)

        // `filled_at` is the ONLY source of truth for "this album is fully indexed".
        // `asset_count` is stored purely as an opaque change token — never compare it
        // against COUNT(*) of album_membership: the server's count and the IDs the
        // search endpoint returns differ structurally (hidden live-photo motion parts),
        // so an equality check would mark every album permanently stale.
        exec("""
            CREATE TABLE IF NOT EXISTS album_index_state (
                album_id    TEXT PRIMARY KEY,
                updated_at  TEXT NOT NULL,
                asset_count INTEGER NOT NULL,
                filled_at   TEXT NOT NULL
            )
        """)
    }

    // MARK: - Reads

    /// Album IDs containing `assetId`. Empty when the asset is in no album — callers
    /// must consult ``isCoveringAllAlbums(knownAlbumCount:)`` to distinguish that from
    /// "not indexed yet".
    func albumIds(forAsset assetId: String) -> [String] {
        var result = [String]()
        readQueue.sync {
            guard let db = readDB else { return }
            let sql = "SELECT album_id FROM album_membership WHERE asset_id = ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, assetId)
            while sqlite3_step(stmt) == SQLITE_ROW {
                result.append(columnText(stmt, 0))
            }
        }
        return result
    }

    /// Album IDs per asset, for a batch of assets. Assets in no album are absent from
    /// the result. One statement, reused — the add-to-album sheet asks this for the
    /// whole current selection at once.
    func albumIds(forAssets assetIds: [String]) -> [String: Set<String>] {
        guard !assetIds.isEmpty else { return [:] }
        var result = [String: Set<String>]()
        readQueue.sync {
            guard let db = readDB else { return }
            let sql = "SELECT album_id FROM album_membership WHERE asset_id = ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            for assetId in assetIds {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                bindText(stmt, 1, assetId)
                var albums = Set<String>()
                while sqlite3_step(stmt) == SQLITE_ROW {
                    albums.insert(columnText(stmt, 0))
                }
                if !albums.isEmpty { result[assetId] = albums }
            }
        }
        return result
    }

    /// Number of albums that have been fully indexed at least once.
    func indexedAlbumCount() -> Int {
        var count = 0
        readQueue.sync {
            guard let db = readDB else { return }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM album_index_state", -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            if sqlite3_step(stmt) == SQLITE_ROW {
                count = Int(sqlite3_column_int64(stmt, 0))
            }
        }
        return count
    }

    /// Asset IDs in one album. Empty both when the album is empty and when it has never
    /// been indexed — check ``isIndexed(albumId:)`` if the difference matters.
    func assetIds(inAlbum albumId: String) -> [String] {
        var result = [String]()
        readQueue.sync {
            guard let db = readDB else { return }
            let sql = "SELECT asset_id FROM album_membership WHERE album_id = ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, albumId)
            while sqlite3_step(stmt) == SQLITE_ROW {
                result.append(columnText(stmt, 0))
            }
        }
        return result
    }

    /// Alle Asset-IDs, die in mindestens einem Album stehen — ohne die in
    /// `excludingAlbumIds` genannten Alben.
    ///
    /// Ausgenommen werden die Spiegel-Alben der Smart Alben: Sie sind auf dem Server
    /// echte Alben, entstehen aber automatisch aus Regeln. Ein Foto, das nur dort
    /// liegt, hat niemand einsortiert — „in keinem Album" muss es weiterhin finden.
    /// (Für das eigene Spiegel-Album kommt hinzu, dass die Regel sich sonst an ihrem
    /// eigenen Ergebnis misst und die Mitgliedschaft zwischen zwei Läufen kippt.)
    ///
    /// Leer ist mehrdeutig (kein Album vs. nichts indiziert) — Aufrufer müssen
    /// ``isCoveringAllAlbums(knownAlbumCount:)`` prüfen.
    func assetIdsInAnyAlbum(excludingAlbumIds: Set<String> = []) -> Set<String> {
        var result = Set<String>()
        readQueue.sync {
            guard let db = readDB else { return }
            let excluded = Array(excludingAlbumIds)
            let sql: String
            if excluded.isEmpty {
                sql = "SELECT DISTINCT asset_id FROM album_membership"
            } else {
                let placeholders = Array(repeating: "?", count: excluded.count).joined(separator: ",")
                sql = "SELECT DISTINCT asset_id FROM album_membership WHERE album_id NOT IN (\(placeholders))"
            }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            for (offset, albumId) in excluded.enumerated() {
                bindText(stmt, Int32(offset + 1), albumId)
            }
            while sqlite3_step(stmt) == SQLITE_ROW {
                result.insert(columnText(stmt, 0))
            }
        }
        return result
    }

    /// Whether this specific album has been fully indexed at least once.
    func isIndexed(albumId: String) -> Bool {
        var found = false
        readQueue.sync {
            guard let db = readDB else { return }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT 1 FROM album_index_state WHERE album_id = ?", -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, albumId)
            found = sqlite3_step(stmt) == SQLITE_ROW
        }
        return found
    }

    /// IDs of all albums that have been indexed. Used to spot albums that vanished
    /// server-side, which `staleAlbumIds` cannot see because it only walks live albums.
    func indexedAlbumIds() -> [String] {
        var result = [String]()
        readQueue.sync {
            guard let db = readDB else { return }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT album_id FROM album_index_state", -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                result.append(columnText(stmt, 0))
            }
        }
        return result
    }

    /// True when every album the app knows about has been indexed, i.e. an empty
    /// lookup result really means "in no album" rather than "not indexed yet".
    func isCoveringAllAlbums(knownAlbumCount: Int) -> Bool {
        knownAlbumCount > 0 && indexedAlbumCount() >= knownAlbumCount
    }

    /// Albums that need a (re-)fill: never indexed, changed on the server, or older
    /// than `ttl`.
    ///
    /// `updatedAt` and `assetCount` are the change tokens. They miss exactly one case —
    /// an add plus a remove that nets to the same count without bumping `updatedAt` —
    /// which is what the TTL sweep exists to heal.
    ///
    /// - Parameter ttlRefillLimit: cap on how many *merely expired* albums are returned
    ///   per call, so the TTL sweep spreads across cycles instead of firing hundreds of
    ///   requests at once. Genuinely changed and never-indexed albums are never capped.
    func staleAlbumIds(
        against albums: [Album],
        ttl: TimeInterval = 24 * 3600,
        ttlRefillLimit: Int = 25,
        now: Date = Date()
    ) -> [String] {
        var state = [String: (updatedAt: String, assetCount: Int, filledAt: Date)]()
        readQueue.sync {
            guard let db = readDB else { return }
            let sql = "SELECT album_id, updated_at, asset_count, filled_at FROM album_index_state"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                let filledAt = Self.iso8601.date(from: columnText(stmt, 3)) ?? .distantPast
                state[columnText(stmt, 0)] = (
                    updatedAt: columnText(stmt, 1),
                    assetCount: Int(sqlite3_column_int64(stmt, 2)),
                    filledAt: filledAt
                )
            }
        }

        var changed = [String]()
        var expired = [(id: String, filledAt: Date)]()
        for album in albums {
            guard let entry = state[album.id] else {
                changed.append(album.id)   // never indexed
                continue
            }
            if entry.updatedAt != album.updatedAt || entry.assetCount != album.assetCount {
                changed.append(album.id)
            } else if now.timeIntervalSince(entry.filledAt) > ttl {
                expired.append((album.id, entry.filledAt))
            }
        }

        // Oldest first, so the sweep works its way through the library predictably.
        let sweep = expired
            .sorted { $0.filledAt < $1.filledAt }
            .prefix(max(0, ttlRefillLimit))
            .map(\.id)

        return changed + sweep
    }

    // MARK: - Writes

    /// Replace one album's membership wholesale and record its change tokens.
    /// Delete + insert + state upsert happen in a single transaction, so a crash
    /// mid-write can never leave an album marked "filled" with partial rows.
    func replaceMembership(albumId: String, assetIds: [String], updatedAt: String, assetCount: Int, filledAt: Date = Date()) {
        writeQueue.sync {
            guard let db else { return }
            exec("BEGIN TRANSACTION")

            // Jeder Schritt wird geprüft, und die Zustandszeile wird **nur** geschrieben,
            // wenn alle Mitgliedschaftszeilen standen.
            //
            // Vorher gingen die Rückgabewerte von `sqlite3_step` verloren. Eine
            // gescheiterte Einfügung (volle Platte, E/A-Fehler) lief damit still durch,
            // die Zustandszeile wurde trotzdem geschrieben — und weil sie die
            // Server-Kennzahlen trägt, hielt `staleAlbumIds` das Album fortan für
            // aktuell. Die Lücke wäre erst aufgefallen, wenn sich das Album
            // serverseitig ändert: bis dahin fehlen Fotos in „In welchen Alben ist
            // dieses Bild?" und in allem, was darauf aufbaut.
            //
            // Die Transaktion allein genügt dafür nicht: Sie schützt gegen einen
            // Absturz mitten im Schreiben, nicht gegen einen Fehler, den niemand liest.
            var failure: String?

            var deleteStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "DELETE FROM album_membership WHERE album_id = ?", -1, &deleteStmt, nil) == SQLITE_OK {
                bindText(deleteStmt, 1, albumId)
                if sqlite3_step(deleteStmt) != SQLITE_DONE {
                    failure = "DELETE: \(Self.errorText(db))"
                }
            } else {
                failure = "DELETE vorbereiten: \(Self.errorText(db))"
            }
            sqlite3_finalize(deleteStmt)

            if failure == nil, !assetIds.isEmpty {
                var insertStmt: OpaquePointer?
                let sql = "INSERT OR REPLACE INTO album_membership (album_id, asset_id) VALUES (?, ?)"
                if sqlite3_prepare_v2(db, sql, -1, &insertStmt, nil) == SQLITE_OK {
                    for assetId in assetIds {
                        sqlite3_reset(insertStmt)
                        bindText(insertStmt, 1, albumId)
                        bindText(insertStmt, 2, assetId)
                        if sqlite3_step(insertStmt) != SQLITE_DONE {
                            failure = "INSERT \(assetId): \(Self.errorText(db))"
                            break
                        }
                    }
                } else {
                    failure = "INSERT vorbereiten: \(Self.errorText(db))"
                }
                sqlite3_finalize(insertStmt)
            }

            if failure == nil {
                var stateStmt: OpaquePointer?
                let stateSQL = """
                    INSERT OR REPLACE INTO album_index_state (album_id, updated_at, asset_count, filled_at)
                    VALUES (?, ?, ?, ?)
                """
                if sqlite3_prepare_v2(db, stateSQL, -1, &stateStmt, nil) == SQLITE_OK {
                    bindText(stateStmt, 1, albumId)
                    bindText(stateStmt, 2, updatedAt)
                    sqlite3_bind_int64(stateStmt, 3, Int64(assetCount))
                    bindText(stateStmt, 4, Self.iso8601.string(from: filledAt))
                    if sqlite3_step(stateStmt) != SQLITE_DONE {
                        failure = "Zustandszeile: \(Self.errorText(db))"
                    }
                } else {
                    failure = "Zustandszeile vorbereiten: \(Self.errorText(db))"
                }
                sqlite3_finalize(stateStmt)
            }

            if let failure {
                AppLogger.sync.error(
                    "AlbumIndex: Mitgliedschaft für \(albumId) nicht geschrieben (\(failure)) — Album bleibt ungefüllt und wird erneut versucht"
                )
                exec("ROLLBACK")
            } else {
                exec("COMMIT")
            }
        }
    }

    /// Write-through for a local "add to album". No-op for albums that were never
    /// indexed — inserting rows there would fake partial coverage for an album whose
    /// remaining members are still unknown.
    func addMembership(albumId: String, assetIds: [String]) {
        guard !assetIds.isEmpty else { return }
        writeQueue.sync {
            guard let db, isIndexedLocked(albumId) else { return }
            exec("BEGIN TRANSACTION")
            let sql = "INSERT OR REPLACE INTO album_membership (album_id, asset_id) VALUES (?, ?)"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                exec("ROLLBACK")
                return
            }
            defer { sqlite3_finalize(stmt) }
            for assetId in assetIds {
                sqlite3_reset(stmt)
                bindText(stmt, 1, albumId)
                bindText(stmt, 2, assetId)
                sqlite3_step(stmt)
            }
            exec("COMMIT")
        }
    }

    /// Write-through for a local "remove from album".
    func removeMembership(albumId: String, assetIds: [String]) {
        guard !assetIds.isEmpty else { return }
        writeQueue.sync {
            guard let db else { return }
            exec("BEGIN TRANSACTION")
            let sql = "DELETE FROM album_membership WHERE album_id = ? AND asset_id = ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                exec("ROLLBACK")
                return
            }
            defer { sqlite3_finalize(stmt) }
            for assetId in assetIds {
                sqlite3_reset(stmt)
                bindText(stmt, 1, albumId)
                bindText(stmt, 2, assetId)
                sqlite3_step(stmt)
            }
            exec("COMMIT")
        }
    }

    /// Drop an album that no longer exists on the server.
    func removeAlbum(albumId: String) {
        writeQueue.sync {
            guard let db else { return }
            exec("BEGIN TRANSACTION")
            for sql in ["DELETE FROM album_membership WHERE album_id = ?",
                        "DELETE FROM album_index_state WHERE album_id = ?"] {
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                    bindText(stmt, 1, albumId)
                    sqlite3_step(stmt)
                }
                sqlite3_finalize(stmt)
            }
            exec("COMMIT")
        }
    }

    /// Drop assets that were permanently deleted. Mirrors the `GridIndexStore.delete`
    /// call sites so a purged asset doesn't linger in any album.
    func removeAssets(ids: [String]) {
        guard !ids.isEmpty else { return }
        writeQueue.sync {
            guard let db else { return }
            exec("BEGIN TRANSACTION")
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM album_membership WHERE asset_id = ?", -1, &stmt, nil) == SQLITE_OK else {
                exec("ROLLBACK")
                return
            }
            defer { sqlite3_finalize(stmt) }
            for id in ids {
                sqlite3_reset(stmt)
                bindText(stmt, 1, id)
                sqlite3_step(stmt)
            }
            exec("COMMIT")
        }
    }

    /// Wipe everything — used when switching servers and by tests.
    func deleteAll() {
        writeQueue.sync {
            exec("DELETE FROM album_membership")
            exec("DELETE FROM album_index_state")
        }
    }

    // MARK: - Helpers

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Must be called from writeQueue.
    private func isIndexedLocked(_ albumId: String) -> Bool {
        var found = false
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT 1 FROM album_index_state WHERE album_id = ?", -1, &stmt, nil) == SQLITE_OK {
            bindText(stmt, 1, albumId)
            found = sqlite3_step(stmt) == SQLITE_ROW
        }
        sqlite3_finalize(stmt)
        return found
    }

    private static func errorText(_ db: OpaquePointer?) -> String {
        guard let message = sqlite3_errmsg(db) else { return "unbekannt" }
        return String(cString: message)
    }

    private func exec(_ sql: String) {
        sqlite3_exec(writeDB, sql, nil, nil, nil)
    }

    private func execOn(_ conn: OpaquePointer?, _ sql: String) {
        sqlite3_exec(conn, sql, nil, nil, nil)
    }

    private func columnText(_ stmt: OpaquePointer?, _ col: Int32) -> String {
        if let cStr = sqlite3_column_text(stmt, col) {
            return String(cString: cStr)
        }
        return ""
    }

    private func bindText(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String) {
        _ = value.withCString { cStr in
            sqlite3_bind_text(stmt, idx, cStr, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
    }
}
