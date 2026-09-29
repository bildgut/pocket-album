import Foundation
import SQLite3
import SwiftData
import os

/// Lightweight SQLite-backed grid index for fast cold-start asset loading.
///
/// Stores only the columns needed for the photo grid timeline (11 fields vs
/// SwiftData's 30+), enabling ~10× faster bulk reads on app launch.
///
/// Updated incrementally during sync — no separate rebuild step needed.
/// Falls back gracefully: if the grid index is empty (first launch), the
/// caller uses the existing SwiftData path instead.
final class GridIndexStore: Sendable {

    /// Shared instance using the default Application Support path
    /// (redirected to a temp directory when running under XCTest).
    static let shared: GridIndexStore = {
        let dbURL = AppEnvironment.supportDirectory.appending(path: "grid_index.sqlite")
        return GridIndexStore(path: dbURL.path)
    }()

    private let dbPath: String
    /// Serialised queue for UI reads — high priority so scroll/load stays snappy.
    private let readQueue  = DispatchQueue(label: "com.ralksta.immichmac.gridindex.read",  qos: .userInitiated)
    /// Serialised queue for bulk writes (sync upserts) — lower priority so large
    /// write batches don't starve reads. SQLite WAL mode allows concurrent readers
    /// even while a writer holds the lock, so using a separate queue at lower QoS
    /// ensures the OS schedules reads ahead of writes under contention.
    private let writeQueue = DispatchQueue(label: "com.ralksta.immichmac.gridindex.write", qos: .utility)

    /// Dedicated write connection — only ever touched on writeQueue.
    /// Owns the schema and all mutations.
    private nonisolated(unsafe) var writeDB: OpaquePointer?

    /// Dedicated read connection — only ever touched on readQueue.
    /// Opened in read-only mode; WAL allows it to run concurrently with writes.
    private nonisolated(unsafe) var readDB: OpaquePointer?

    // Convenience alias for write-side code (writeQueue only).
    private var db: OpaquePointer? { writeDB }

    /// Wächter gegen doppelte Backfill-Läufe: Das `.task` an `ContentView` kann erneut
    /// feuern, wenn das Fenster geschlossen und über das Dock wieder geöffnet wird, bevor
    /// der erste Lauf durch ist und den Marker gesetzt hat — beide Läufe wären zwar
    /// idempotent, liefen aber minutenlang parallel über dieselben Queues. Ein einfaches
    /// `var` würde die `Sendable`-Konformität der Klasse verletzen; `OSAllocatedUnfairLock`
    /// macht das Lesen-und-Setzen atomar.
    private let backfillInProgress = OSAllocatedUnfairLock(initialState: false)

    /// Ablage für die einmaligen Backfill-Marken (siehe `checksumBackfillPendingKey`,
    /// `exifV8BackfillKey`). Injizierbar, damit `GridIndexStoreTests` eine isolierte
    /// Suite übergeben können — der `Verbot: UserDefaults.standard`-Buildscript-Check
    /// (siehe `project.yml`) verbietet den direkten Zugriff auf `.standard` aus genau
    /// diesem Grund: Der app-gehostete Testlauf teilt sonst dieselbe Domain wie die
    /// ausgelieferte App.
    ///
    /// `nonisolated(unsafe)`: `UserDefaults` ist laut Apple threadsicher, im SDK aber
    /// nicht als `Sendable` markiert — die Eigenschaft wird nie neu zugewiesen.
    nonisolated(unsafe) private let defaults: UserDefaults

    init(path: String, defaults: UserDefaults = AppEnvironment.defaults) {
        self.dbPath = path
        self.defaults = defaults
        // Open + migrate on the write queue first so the schema exists before
        // any read connection is opened.
        writeQueue.sync { self.openWriteConnection() }
        readQueue.sync  { self.openReadConnection()  }
    }

    deinit {
        if let writeDB { sqlite3_close(writeDB) }
        if let readDB  { sqlite3_close(readDB)  }
    }

    // MARK: - Schema

    /// Opens the write connection and applies any pending schema migrations.
    /// Must only be called from writeQueue.
    private func openWriteConnection() {
        guard sqlite3_open(dbPath, &writeDB) == SQLITE_OK else {
            AppLogger.app.error("GridIndexStore: failed to open write DB at \(self.dbPath)")
            return
        }
        migrateSchema()
        vacuumIfFragmented()
    }

    /// Ab welchem Anteil leerer Seiten sich ein `VACUUM` lohnt. Nach vielen Resyncs
    /// waren 34 % der Datei (34 von 99 MB) leer — SQLite gibt gelöschte Seiten ohne
    /// `VACUUM` nicht an das Dateisystem zurück.
    static func sollteVacuum(pageCount: Int64, freelistCount: Int64) -> Bool {
        pageCount > 0 && freelistCount * 4 >= pageCount   // ≥ 25 %
    }

    /// Einmal beim Öffnen, noch vor der Leseverbindung — dauert bei 100 MB unter einer
    /// Sekunde und läuft nur, wenn wirklich viel leer steht.
    private func vacuumIfFragmented() {
        func zahl(_ sql: String) -> Int64 {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(writeDB, sql, -1, &stmt, nil) == SQLITE_OK,
                  sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return sqlite3_column_int64(stmt, 0)
        }
        let seiten = zahl("PRAGMA page_count")
        let frei = zahl("PRAGMA freelist_count")
        guard Self.sollteVacuum(pageCount: seiten, freelistCount: frei) else { return }
        execOn(writeDB, "VACUUM")
        AppLogger.app.info("GridIndexStore: VACUUM, \(frei) von \(seiten) Seiten waren leer")
    }

    /// Opens a read-only connection for the read queue.
    /// WAL mode lets this run concurrently with the write connection.
    /// Must only be called from readQueue.
    private func openReadConnection() {
        // SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX — no internal mutex needed
        // because we serialise all reads on readQueue ourselves.
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(dbPath, &readDB, flags, nil) == SQLITE_OK else {
            AppLogger.app.error("GridIndexStore: failed to open read DB at \(self.dbPath)")
            return
        }
        // Mirror performance settings on the read connection
        execOn(readDB, "PRAGMA journal_mode = WAL")
        execOn(readDB, "PRAGMA cache_size = -4000")  // 4 MB read cache
    }

    private func migrateSchema() {
        // Performance tuning
        execOn(writeDB, "PRAGMA journal_mode = WAL")
        execOn(writeDB, "PRAGMA synchronous = NORMAL")
        execOn(writeDB, "PRAGMA cache_size = -8000")  // 8MB write-side cache

        // MARK: - Schema Versioning
        let currentVersion = 10
        let userVersion: Int32 = {
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil)
            sqlite3_step(stmt)
            let v = sqlite3_column_int(stmt, 0)
            sqlite3_finalize(stmt)
            return v
        }()

        // Beide ALTER-Blöcke sind einzeln aufrufbar, damit ein Sprung von v6
        // direkt auf v8 nicht den Zwischenschritt überspringt.
        func addExifCheckedAtColumn() {
            exec("ALTER TABLE grid_assets ADD COLUMN exifCheckedAt TEXT")
            // Zeilen, die bereits EXIF tragen, gelten als geprüft — sie müssen nicht
            // noch einmal beim Server erfragt werden.
            exec("""
                UPDATE grid_assets SET exifCheckedAt = '1970-01-01T00:00:00Z'
                WHERE cameraModel IS NOT NULL OR lensModel IS NOT NULL
                   OR city IS NOT NULL OR country IS NOT NULL
            """)
        }

        func addExifV8Columns() {
            exec("ALTER TABLE grid_assets ADD COLUMN latitude REAL")
            exec("ALTER TABLE grid_assets ADD COLUMN longitude REAL")
            exec("ALTER TABLE grid_assets ADD COLUMN cameraMake TEXT")
            exec("ALTER TABLE grid_assets ADD COLUMN fileSizeInByte INTEGER")
        }

        func addChecksumColumn() {
            exec("ALTER TABLE grid_assets ADD COLUMN checksum TEXT")
        }

        func addOrientationColumn() {
            exec("ALTER TABLE grid_assets ADD COLUMN exifOrientation INTEGER")
        }

        if userVersion >= 6 && userVersion < currentVersion {
            // Ein DROP würde hier 165.000 Zeilen verwerfen und den nächsten Kaltstart
            // über den langsamen SwiftData-Pfad erzwingen — für ein paar Spalten ein
            // absurder Preis.
            AppLogger.app.info("GridIndexStore: migrating v\(userVersion) → v\(currentVersion) (ALTER, kein Neuaufbau)")
            if userVersion == 6 { addExifCheckedAtColumn() }
            if userVersion <= 7 { addExifV8Columns() }
            if userVersion <= 8 {
                addChecksumColumn()
                defaults.set(true, forKey: Self.checksumBackfillPendingKey)
            }
            addOrientationColumn()
            defaults.set(true, forKey: Self.orientationBackfillPendingKey)
            exec("PRAGMA user_version = \(currentVersion)")
        } else if userVersion < currentVersion {
            AppLogger.app.info("GridIndexStore: migrating from v\(userVersion) to v\(currentVersion)")
            exec("DROP TABLE IF EXISTS grid_assets")
            defaults.set(true, forKey: Self.checksumBackfillPendingKey)
            defaults.set(true, forKey: Self.orientationBackfillPendingKey)
            exec("PRAGMA user_version = \(currentVersion)")
        }

        exec("""
            CREATE TABLE IF NOT EXISTS grid_assets (
                id TEXT PRIMARY KEY,
                type TEXT NOT NULL DEFAULT 'IMAGE',
                originalFileName TEXT NOT NULL DEFAULT '',
                fileCreatedAt TEXT NOT NULL,
                fileModifiedAt TEXT NOT NULL,
                isFavorite INTEGER NOT NULL DEFAULT 0,
                isArchived INTEGER NOT NULL DEFAULT 0,
                isTrashed INTEGER NOT NULL DEFAULT 0,
                isHidden INTEGER NOT NULL DEFAULT 0,
                duration TEXT,
                thumbhash TEXT,
                width INTEGER,
                height INTEGER,
                lensModel TEXT,
                cameraModel TEXT,
                city TEXT,
                country TEXT,
                livePhotoVideoId TEXT,
                exifCheckedAt TEXT,
                latitude REAL,
                longitude REAL,
                cameraMake TEXT,
                fileSizeInByte INTEGER,
                checksum TEXT,
                exifOrientation INTEGER
            )
        """)

        // Bedient genau die Arbeitsliste der EXIF-Reparatur und schrumpft mit ihrem
        // Fortschritt, statt über die ganze Tabelle zu liegen.
        exec("""
            CREATE INDEX IF NOT EXISTS idx_grid_exif_pending
            ON grid_assets(fileCreatedAt DESC)
            WHERE exifCheckedAt IS NULL AND isTrashed = 0
        """)

        exec("""
            CREATE INDEX IF NOT EXISTS idx_grid_camera
            ON grid_assets(cameraModel)
            WHERE cameraModel IS NOT NULL AND isTrashed = 0
        """)

        exec("""
            CREATE INDEX IF NOT EXISTS idx_grid_visible
            ON grid_assets(isTrashed, isArchived, isHidden, fileCreatedAt DESC)
        """)

        exec("""
            CREATE INDEX IF NOT EXISTS idx_grid_city
            ON grid_assets(city)
            WHERE city IS NOT NULL AND isTrashed = 0
        """)

        exec("""
            CREATE INDEX IF NOT EXISTS idx_grid_country
            ON grid_assets(country)
            WHERE country IS NOT NULL AND isTrashed = 0
        """)

        // Deckt `loadGeoScanRows` vollständig ab: Filter, Reihenfolge *und* alle vier
        // gelesenen Spalten stehen im Index, die Tabelle wird nicht mehr angefasst.
        // `idx_grid_visible` kann das nicht — dessen Einträge tragen bei einer
        // `TEXT PRIMARY KEY`-Tabelle nur die rowid, jede der 155 000 Zeilen bräuchte
        // einen Rücksprung für `latitude`/`longitude`.
        //
        // Die drei Sichtbarkeits-Flags stehen bewusst *vorn* und nicht im Prädikat:
        // So bietet dieser Index dieselbe Gleichheitssuche wie `idx_grid_visible`,
        // nur eben zusätzlich abdeckend.
        //
        // Welchen der beiden SQLite dann nimmt, entscheidet die Abfrage selbst —
        // `geoScanSQL` schreibt ihn per `INDEXED BY` fest (Begründung dort).
        // `GeoIndexScanTests` prüft den Abfrageplan zusätzlich.
        exec("""
            CREATE INDEX IF NOT EXISTS idx_grid_geo_scan
            ON grid_assets(isTrashed, isArchived, isHidden, fileCreatedAt, id, latitude, longitude)
            WHERE exifCheckedAt IS NOT NULL
        """)
    }

    // MARK: - Public API

    /// Batch load of favorites, videos and asset stats — all in a single readQueue.sync block.
    /// Avoids 3 separate blocking dispatches when recomputeDerivedArrays fires.
    func loadDerivedCollections() -> (favorites: [Asset], videos: [Asset], libStats: (images: Int, videos: Int, earliest: String?, latest: String?), favStats: (images: Int, videos: Int, earliest: String?, latest: String?)) {
        var favs: [Asset] = []
        var vids: [Asset] = []
        var libStats = (images: 0, videos: 0, earliest: nil as String?, latest: nil as String?)
        var favStats = (images: 0, videos: 0, earliest: nil as String?, latest: nil as String?)

        readQueue.sync {
            guard let db = readDB else { return }

            // Favorites
            //
            // `isArchived = 0` gehört hier dazu, so wie in die Zählung weiter unten:
            // Liste und Untertitel werden von `recomputeDerivedArrays` gemeinsam
            // gesetzt und stehen in derselben Ansicht übereinander. Ohne den Filter
            // stand eine archivierte Aufnahme im Raster, fehlte aber in „n Fotos".
            // Es ist auch die Menge, die die beiden anderen Wege in dieselben Arrays
            // schreiben: der Rückfallzweig (sichtbarer Pool) und `loadNextLocalPage`
            // (aus `loadVisiblePage`, ebenfalls ohne Archiv).
            let favSQL = """
                SELECT \(Self.selectColumns)
                FROM grid_assets
                WHERE isFavorite = 1 AND isTrashed = 0 AND isArchived = 0 AND isHidden = 0
                ORDER BY fileCreatedAt DESC
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, favSQL, -1, &stmt, nil) == SQLITE_OK {
                favs.reserveCapacity(1000)
                while sqlite3_step(stmt) == SQLITE_ROW { favs.append(assetFromRow(stmt)) }
                sqlite3_finalize(stmt)
            }

            // Videos — dieselbe Menge wie bei den Favoriten, aus demselben Grund.
            let vidSQL = """
                SELECT \(Self.selectColumns)
                FROM grid_assets
                WHERE type = 'VIDEO' AND isTrashed = 0 AND isArchived = 0 AND isHidden = 0
                ORDER BY fileCreatedAt DESC
            """
            stmt = nil
            if sqlite3_prepare_v2(db, vidSQL, -1, &stmt, nil) == SQLITE_OK {
                vids.reserveCapacity(1000)
                while sqlite3_step(stmt) == SQLITE_ROW { vids.append(assetFromRow(stmt)) }
                sqlite3_finalize(stmt)
            }

            // Stats (library)
            let statsSQL = """
                SELECT
                    SUM(CASE WHEN type = 'IMAGE' THEN 1 ELSE 0 END),
                    SUM(CASE WHEN type = 'VIDEO' THEN 1 ELSE 0 END),
                    MIN(fileCreatedAt), MAX(fileCreatedAt)
                FROM grid_assets
                WHERE isTrashed = 0 AND isArchived = 0 AND isHidden = 0
            """
            stmt = nil
            if sqlite3_prepare_v2(db, statsSQL, -1, &stmt, nil) == SQLITE_OK {
                if sqlite3_step(stmt) == SQLITE_ROW {
                    libStats.images   = Int(sqlite3_column_int64(stmt, 0))
                    libStats.videos   = Int(sqlite3_column_int64(stmt, 1))
                    libStats.earliest = columnOptionalText(stmt, 2)
                    libStats.latest   = columnOptionalText(stmt, 3)
                }
                sqlite3_finalize(stmt)
            }

            // Stats (favorites only)
            let favStatsSQL = """
                SELECT
                    SUM(CASE WHEN type = 'IMAGE' THEN 1 ELSE 0 END),
                    SUM(CASE WHEN type = 'VIDEO' THEN 1 ELSE 0 END),
                    MIN(fileCreatedAt), MAX(fileCreatedAt)
                FROM grid_assets
                WHERE isTrashed = 0 AND isArchived = 0 AND isHidden = 0 AND isFavorite = 1
            """
            stmt = nil
            if sqlite3_prepare_v2(db, favStatsSQL, -1, &stmt, nil) == SQLITE_OK {
                if sqlite3_step(stmt) == SQLITE_ROW {
                    favStats.images   = Int(sqlite3_column_int64(stmt, 0))
                    favStats.videos   = Int(sqlite3_column_int64(stmt, 1))
                    favStats.earliest = columnOptionalText(stmt, 2)
                    favStats.latest   = columnOptionalText(stmt, 3)
                }
                sqlite3_finalize(stmt)
            }
        }
        return (favs, vids, libStats, favStats)
    }

    /// Load all visible (non-trashed, non-archived, non-hidden) assets sorted by date descending.
    /// Returns an empty array if the index is empty (first launch).
    func loadAll() -> [Asset] {
        var result: [Asset] = []
        readQueue.sync {
            guard let db = readDB else { return }

            let sql = """
                SELECT \(Self.selectColumns)
                FROM grid_assets
                WHERE isTrashed = 0 AND isArchived = 0 AND isHidden = 0
                ORDER BY fileCreatedAt DESC
            """

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            result.reserveCapacity(100_000)

            while sqlite3_step(stmt) == SQLITE_ROW {
                result.append(assetFromRow(stmt))
            }
        }
        return result
    }

    /// Load a page of visible assets sorted by date descending.
    func loadVisiblePage(offset: Int, limit: Int) -> [Asset] {
        guard limit > 0, offset >= 0 else { return [] }

        var result: [Asset] = []
        readQueue.sync {
            guard let db = readDB else { return }

            let sql = """
                SELECT \(Self.selectColumns)
                FROM grid_assets
                WHERE isTrashed = 0 AND isArchived = 0 AND isHidden = 0
                ORDER BY fileCreatedAt DESC
                LIMIT ? OFFSET ?
            """

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int64(stmt, 1, Int64(limit))
            sqlite3_bind_int64(stmt, 2, Int64(offset))

            result.reserveCapacity(limit)
            while sqlite3_step(stmt) == SQLITE_ROW {
                result.append(assetFromRow(stmt))
            }
        }
        return result
    }

    /// Load visible assets for a specific ID set.
    func loadVisible(ids: [String]) -> [Asset] {
        guard !ids.isEmpty else { return [] }

        var result: [Asset] = []
        readQueue.sync {
            guard let db = readDB else { return }

            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let sql = """
                SELECT \(Self.selectColumns)
                FROM grid_assets
                WHERE id IN (\(placeholders))
                  AND isTrashed = 0 AND isArchived = 0 AND isHidden = 0
            """

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            for (index, id) in ids.enumerated() {
                bindText(stmt, Int32(index + 1), id)
            }

            result.reserveCapacity(ids.count)
            while sqlite3_step(stmt) == SQLITE_ROW {
                result.append(assetFromRow(stmt))
            }
        }

        return result
    }

    /// Alle sichtbaren Bilder als IDs — die Kandidatenliste der Bildeinordnung.
    ///
    /// Nur IDs, keine ganzen `Asset`s: Bei ~117 000 Fotos ist der Unterschied
    /// zwischen einer Spalte und 25 Spalten der zwischen Sekunden und Minuten.
    /// Videos bleiben draußen — das Modell bekommt nur Standbilder.
    func idsVisibleImages() -> [String] {
        var result: [String] = []
        readQueue.sync {
            guard let db = readDB else { return }
            let sql = """
                SELECT id FROM grid_assets
                WHERE isTrashed = 0 AND isArchived = 0 AND isHidden = 0 AND type = 'IMAGE'
                ORDER BY fileCreatedAt DESC
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let c = sqlite3_column_text(stmt, 0) { result.append(String(cString: c)) }
            }
        }
        return result
    }

    /// Load archived assets for the archive view.
    func loadArchived() -> [Asset] {
        var result: [Asset] = []
        readQueue.sync {
            guard let db = readDB else { return }

            let sql = """
                SELECT \(Self.selectColumns)
                FROM grid_assets
                WHERE isTrashed = 0 AND isArchived = 1 AND isHidden = 0
                ORDER BY fileCreatedAt DESC
            """

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            while sqlite3_step(stmt) == SQLITE_ROW {
                result.append(assetFromRow(stmt))
            }
        }
        return result
    }

    /// Number of visible assets (non-trashed, non-archived, non-hidden).
    /// Sichtbare Zeilen, oder `0`, wenn die Abfrage nicht durchlief.
    ///
    /// Für Anzeigezwecke reicht das. Wer aus dem Ergebnis eine Entscheidung
    /// ableitet, für die „keine Zeilen" und „nicht gelesen" verschiedene Dinge
    /// bedeuten, nimmt ``countVisibleChecked()``.
    func countVisible() -> Int {
        countVisibleChecked() ?? 0
    }

    /// Wie ``countVisible()``, aber `nil`, wenn die Abfrage nicht durchlief.
    ///
    /// Dieselbe Unterscheidung, die der EXIF-Backfill weiter unten schon trifft
    /// (`rows: [...]?`): Ein Lesefehler sieht sonst aus wie ein leerer Index, und
    /// wer daraus „am Ende angekommen" schließt, schneidet den Rest der Bibliothek
    /// ab. `loadVisiblePage` kann das nicht unterscheiden — diese Zählung schon.
    func countVisibleChecked() -> Int? {
        var result: Int?
        readQueue.sync {
            guard let db = readDB else { return }
            let sql = "SELECT COUNT(*) FROM grid_assets WHERE isTrashed = 0 AND isArchived = 0 AND isHidden = 0"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            if sqlite3_step(stmt) == SQLITE_ROW {
                result = Int(sqlite3_column_int64(stmt, 0))
            }
        }
        return result
    }

    /// Die Spaltenliste, die ``assetFromRow(_:)`` erwartet — Reihenfolge ist bindend,
    /// der Reader greift über feste Indizes zu. Stand vor v8 elfmal wörtlich im Code;
    /// eine vergessene Stelle verschiebt lautlos alle Indizes dahinter.
    private static let selectColumns = """
        id, type, fileCreatedAt, isFavorite, isArchived, isTrashed, isHidden, \
        duration, thumbhash, width, height, originalFileName, fileModifiedAt, \
        lensModel, cameraModel, city, country, livePhotoVideoId, \
        latitude, longitude, cameraMake, fileSizeInByte
        """

    // MARK: - Upserts
    //
    // Grundregel für alle drei Upserts: Jeder Schreiber aktualisiert nur die Spalten,
    // die seine Quelle tatsächlich trägt. Was die Quelle nicht kennt, bleibt beim
    // Bestandswert stehen — deshalb ON CONFLICT DO UPDATE statt INSERT OR REPLACE.
    // REPLACE löschte die Zeile und legte sie neu an; alles, was die Quelle nicht
    // kennt, wurde dabei still auf NULL gesetzt.

    /// Batch upsert assets into the grid index within a single transaction.
    /// Quelle: API-`Asset`. `visibility == .hidden` wird beim INSERT gebunden; im UPDATE bleibt `isHidden` unverändert, um einen vom Sync gesetzten Wert nicht zu überschreiben.
    func upsert(_ assets: [Asset]) {
        guard !assets.isEmpty else { return }
        writeQueue.sync {
            guard let db else { return }

            exec("BEGIN TRANSACTION")

            let sql = """
                INSERT INTO grid_assets
                (id, type, fileCreatedAt, isFavorite, isArchived, isTrashed, isHidden,
                 duration, thumbhash, width, height, originalFileName, fileModifiedAt, lensModel, cameraModel,
                 city, country, livePhotoVideoId, latitude, longitude, cameraMake, fileSizeInByte, checksum)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    type             = excluded.type,
                    fileCreatedAt    = excluded.fileCreatedAt,
                    isFavorite       = excluded.isFavorite,
                    isArchived       = excluded.isArchived,
                    isTrashed        = excluded.isTrashed,
                    duration         = excluded.duration,
                    thumbhash        = excluded.thumbhash,
                    width            = excluded.width,
                    height           = excluded.height,
                    originalFileName = excluded.originalFileName,
                    fileModifiedAt   = excluded.fileModifiedAt,
                    lensModel        = excluded.lensModel,
                    cameraModel      = excluded.cameraModel,
                    city             = excluded.city,
                    country          = excluded.country,
                    livePhotoVideoId = excluded.livePhotoVideoId,
                    latitude         = excluded.latitude,
                    longitude        = excluded.longitude,
                    cameraMake       = excluded.cameraMake,
                    fileSizeInByte   = excluded.fileSizeInByte,
                    -- Polling-Antworten ohne checksum dürfen die Stream-Checksum nicht löschen.
                    checksum         = COALESCE(excluded.checksum, grid_assets.checksum)
            """

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                exec("ROLLBACK")
                return
            }
            defer { sqlite3_finalize(stmt) }

            for asset in assets {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)

                bindText(stmt, 1, asset.id)
                bindText(stmt, 2, asset.type.rawValue)
                bindText(stmt, 3, asset.fileCreatedAt)
                sqlite3_bind_int(stmt, 4, asset.isFavorite ? 1 : 0)
                sqlite3_bind_int(stmt, 5, asset.isArchived ? 1 : 0)
                sqlite3_bind_int(stmt, 6, asset.isTrashed ? 1 : 0)
                sqlite3_bind_int(stmt, 7, (asset.visibility == .hidden) ? 1 : 0)
                bindOptionalText(stmt, 8, asset.duration)
                bindOptionalText(stmt, 9, asset.thumbhash)
                bindOptionalInt(stmt, 10, asset.effectiveWidth)
                bindOptionalInt(stmt, 11, asset.effectiveHeight)
                bindText(stmt, 12, asset.originalFileName)
                bindText(stmt, 13, asset.fileModifiedAt)
                bindOptionalText(stmt, 14, asset.exifInfo?.lensModel)
                bindOptionalText(stmt, 15, asset.exifInfo?.model)
                bindOptionalText(stmt, 16, asset.exifInfo?.city)
                bindOptionalText(stmt, 17, asset.exifInfo?.country)
                bindOptionalText(stmt, 18, asset.livePhotoVideoId)
                bindOptionalDouble(stmt, 19, asset.exifInfo?.latitude)
                bindOptionalDouble(stmt, 20, asset.exifInfo?.longitude)
                bindOptionalText(stmt, 21, asset.exifInfo?.make)
                bindOptionalInt(stmt, 22, asset.exifInfo?.fileSizeInByte)
                bindOptionalText(stmt, 23, asset.checksum)

                sqlite3_step(stmt)
            }

            exec("COMMIT")
        }
    }

    /// Wie ``upsert(_:)``, vermerkt zusätzlich `exifCheckedAt`.
    ///
    /// **Vorbedingung:** Die Assets stammen aus einem Abruf mit `withExif: true`. Nur
    /// dann trägt der Vermerk seine Bedeutung — „wir haben den Server nach EXIF
    /// gefragt" —, und nur dann gilt danach die Invariante
    /// `exifCheckedAt IS NOT NULL ⟹ EXIF-Spalten autoritativ`.
    ///
    /// Diese Regel steht schon in der v7-Migration: Sie stempelt Zeilen, die EXIF
    /// tragen, nachträglich als geprüft. Der Einfügepfad wandte sie nicht an — nur
    /// der damalige `SyncEngine.exifCatchUp` markierte, und das sah ausschließlich
    /// IDs aus dem Stream-Delta. Inzwischen markiert `AssetExifsV1` im Sync-Stream
    /// direkt (`updateExifFromSync`). Für eine frische Installation hieß das damals: 155 000 mit EXIF geholte
    /// Zeilen, keine einzige markiert. Der Geo-Scan liest nur Zeilen mit gesetztem
    /// Vermerk und fand nichts; Duplikatsuche und GPS-Ergänzen meldeten die volle
    /// Bibliothek als „EXIF ausstehend"; und die EXIF-Reparatur hätte genau die Seiten
    /// erneut geholt, die der Erstsync gerade geholt hatte.
    func upsertFromExifFetch(_ assets: [Asset]) {
        guard !assets.isEmpty else { return }
        upsert(assets)
        markExifChecked(ids: assets.map(\.id))
    }

    /// Batch upsert from CachedAsset objects (used during sync).
    /// Quelle: `CachedAsset` aus SwiftData. Kennt alle Spalten → Vollupdate.
    func upsertFromCache(_ cached: [CachedAsset]) {
        guard !cached.isEmpty else { return }
        writeQueue.sync {
            guard let db else { return }

            exec("BEGIN TRANSACTION")

            let sql = """
                INSERT INTO grid_assets
                (id, type, fileCreatedAt, isFavorite, isArchived, isTrashed, isHidden,
                 duration, thumbhash, width, height, originalFileName, fileModifiedAt, lensModel, cameraModel,
                 city, country, livePhotoVideoId, latitude, longitude, cameraMake, fileSizeInByte)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    type             = excluded.type,
                    fileCreatedAt    = excluded.fileCreatedAt,
                    isFavorite       = excluded.isFavorite,
                    isArchived       = excluded.isArchived,
                    isTrashed        = excluded.isTrashed,
                    isHidden         = excluded.isHidden,
                    duration         = excluded.duration,
                    thumbhash        = excluded.thumbhash,
                    width            = excluded.width,
                    height           = excluded.height,
                    originalFileName = excluded.originalFileName,
                    fileModifiedAt   = excluded.fileModifiedAt,
                    lensModel        = excluded.lensModel,
                    cameraModel      = excluded.cameraModel,
                    city             = excluded.city,
                    country          = excluded.country,
                    livePhotoVideoId = excluded.livePhotoVideoId,
                    latitude         = excluded.latitude,
                    longitude        = excluded.longitude,
                    cameraMake       = excluded.cameraMake,
                    fileSizeInByte   = excluded.fileSizeInByte
            """

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                exec("ROLLBACK")
                return
            }
            defer { sqlite3_finalize(stmt) }

            for asset in cached {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)

                bindText(stmt, 1, asset.assetId)
                bindText(stmt, 2, asset.type)
                bindText(stmt, 3, asset.fileCreatedAt)
                sqlite3_bind_int(stmt, 4, asset.isFavorite ? 1 : 0)
                sqlite3_bind_int(stmt, 5, asset.isArchived ? 1 : 0)
                sqlite3_bind_int(stmt, 6, asset.isTrashed ? 1 : 0)
                sqlite3_bind_int(stmt, 7, asset.isHidden ? 1 : 0)
                bindOptionalText(stmt, 8, asset.duration)
                bindOptionalText(stmt, 9, asset.thumbhash)
                bindOptionalInt(stmt, 10, asset.width)
                bindOptionalInt(stmt, 11, asset.height)
                bindText(stmt, 12, asset.originalFileName)
                bindText(stmt, 13, asset.fileModifiedAt)
                bindOptionalText(stmt, 14, asset.lensModel)
                bindOptionalText(stmt, 15, asset.cameraModel)
                bindOptionalText(stmt, 16, asset.city)
                bindOptionalText(stmt, 17, asset.country)
                bindOptionalText(stmt, 18, asset.livePhotoVideoId)
                bindOptionalDouble(stmt, 19, asset.latitude)
                bindOptionalDouble(stmt, 20, asset.longitude)
                bindOptionalText(stmt, 21, asset.cameraMake)
                bindOptionalInt(stmt, 22, asset.fileSizeInByte)

                sqlite3_step(stmt)
            }

            exec("COMMIT")
        }
    }

    /// Batch upsert from SyncAsset objects (used during stream sync).
    /// Quelle: `SyncAssetV1`. Trägt weder Bildmaße noch EXIF → width, height, lensModel,
    /// cameraModel, city und country werden im UPDATE ausgelassen und behalten ihren
    /// Bestandswert. Vorher setzte INSERT OR REPLACE sie bei jedem Sync auf NULL.
    func upsertFromSync(_ syncAssets: [SyncAsset]) {
        guard !syncAssets.isEmpty else { return }
        writeQueue.sync {
            guard let db else { return }

            exec("BEGIN TRANSACTION")

            // fileCreatedAt/fileModifiedAt können im Stream fehlen und werden dann als ""
            // gebunden. COALESCE(NULLIF(...)) verhindert, dass ein leerer Wert ein
            // vorhandenes Datum überschreibt — das würde die Timeline-Sortierung zerstören.
            let sql = """
                INSERT INTO grid_assets
                (id, type, fileCreatedAt, isFavorite, isArchived, isTrashed, isHidden,
                 duration, thumbhash, width, height, originalFileName, fileModifiedAt, lensModel, cameraModel,
                 city, country, livePhotoVideoId, checksum)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    type             = excluded.type,
                    fileCreatedAt    = COALESCE(NULLIF(excluded.fileCreatedAt, ''), grid_assets.fileCreatedAt),
                    isFavorite       = excluded.isFavorite,
                    isArchived       = excluded.isArchived,
                    isTrashed        = excluded.isTrashed,
                    isHidden         = excluded.isHidden,
                    duration         = excluded.duration,
                    thumbhash        = excluded.thumbhash,
                    originalFileName = excluded.originalFileName,
                    fileModifiedAt   = COALESCE(NULLIF(excluded.fileModifiedAt, ''), grid_assets.fileModifiedAt),
                    livePhotoVideoId = excluded.livePhotoVideoId,
                    checksum         = excluded.checksum
            """

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                exec("ROLLBACK")
                return
            }
            defer { sqlite3_finalize(stmt) }

            // Gesperrte Assets werden nie lokal gespeichert – sie sind nur live
            // abrufbar. Ein Asset kann aber erst nachträglich in den gesperrten
            // Ordner wandern: dann liegt es schon im Index und muss raus, sonst
            // bleibt es in der Timeline stehen.
            var lockedIds: [String] = []

            for asset in syncAssets {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)

                let isArchived = asset.visibility == "archive"
                let isHidden = asset.visibility == "hidden"
                let isTrashed = asset.deletedAt != nil

                if asset.visibility == "locked" {
                    lockedIds.append(asset.id)
                    continue
                }

                bindText(stmt, 1, asset.id)
                bindText(stmt, 2, asset.type)
                bindText(stmt, 3, asset.fileCreatedAt ?? "")
                sqlite3_bind_int(stmt, 4, asset.isFavorite ? 1 : 0)
                sqlite3_bind_int(stmt, 5, isArchived ? 1 : 0)
                sqlite3_bind_int(stmt, 6, isTrashed ? 1 : 0)
                sqlite3_bind_int(stmt, 7, isHidden ? 1 : 0)
                bindOptionalText(stmt, 8, asset.duration)
                bindOptionalText(stmt, 9, asset.thumbhash)
                // Die folgenden NULL-Bindungen wirken nur noch im INSERT-Zweig, also für
                // Assets, die der Index noch nicht kennt. Beim UPDATE bleiben die
                // Bestandswerte stehen, weil diese Spalten im DO UPDATE SET fehlen.
                sqlite3_bind_null(stmt, 10)  // width not in SyncAsset
                sqlite3_bind_null(stmt, 11)  // height not in SyncAsset
                bindText(stmt, 12, asset.originalFileName)
                let createdAt = asset.fileCreatedAt ?? ""
                bindText(stmt, 13, asset.fileModifiedAt ?? createdAt)
                sqlite3_bind_null(stmt, 14)  // lensModel not in SyncAssetV1
                sqlite3_bind_null(stmt, 15)  // cameraModel not in SyncAssetV1
                sqlite3_bind_null(stmt, 16)  // city not in SyncAssetV1
                sqlite3_bind_null(stmt, 17)  // country not in SyncAssetV1
                bindOptionalText(stmt, 18, asset.livePhotoVideoId)
                bindText(stmt, 19, asset.checksum)

                sqlite3_step(stmt)
            }

            // Gesperrte Assets aus dem Index entfernen — in derselben Transaktion,
            // `delete(ids:)` würde writeQueue.sync erneut betreten.
            if !lockedIds.isEmpty {
                var deleteStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, "DELETE FROM grid_assets WHERE id = ?", -1, &deleteStmt, nil) == SQLITE_OK {
                    defer { sqlite3_finalize(deleteStmt) }
                    for id in lockedIds {
                        sqlite3_reset(deleteStmt)
                        bindText(deleteStmt, 1, id)
                        sqlite3_step(deleteStmt)
                    }
                }
            }

            exec("COMMIT")
        }
    }

    /// EXIF-Spalten aus dem Sync-Stream (`SyncAssetExif`) nachtragen — und die Zeile
    /// als EXIF-geprüft markieren: Eine Stream-Zeile ist die autoritative Antwort
    /// des Servers, genau das, was `exifCheckedAt` bedeutet („wir haben gefragt").
    ///
    /// Bewusst UPDATE statt Upsert: Die Asset-Zeile legt `upsertFromSync` an.
    /// Fehlt sie, ist das Asset lokal absichtlich nicht vorhanden (gesperrt) —
    /// dann läuft das UPDATE ins Leere. Die Nachzügler-Behandlung (EXIF kam vor
    /// seinem Asset) macht die SyncEngine über den SwiftData-Abgleich, nicht SQLite.
    ///
    /// **Maße:** Der Stream liefert die **rohen Sensormaße**. Am 06.09.2026 über 154.966
    /// Stream-Zeilen ausgezählt: Bei `orientation = 6` kamen 33.357-mal quere Maße und
    /// kein einziges hohes — obwohl das genau die hochkant fotografierten Bilder sind.
    /// ``ExifOrientation`` macht daraus die Anzeigegröße.
    ///
    /// **Überschrieben wird nur, wenn die Orientierung tatsächlich tauscht** (5–8).
    /// Diese Einschränkung ist teuer gelernt: Ein erster Anlauf ließ jede EXIF-Zeile die
    /// Maße überschreiben und ersetzte damit auch die guten Top-Level-Werte aus der
    /// REST-API durch rohe Sensormaße — die Zahl der Hochformate fiel von 71.647 auf
    /// 37.653. Wo getauscht wird, ist das Ergebnis dagegen dieselbe Anzeigegröße, die
    /// auch die REST-API meldet; dort kann das Überschreiben nichts kaputt machen.
    ///
    /// Ohne Tausch bleibt es beim alten Verhalten: nur auffüllen, nichts überschreiben.
    ///
    /// `exifOrientation` wird mitgeschrieben — nicht, weil es beim Lesen gebraucht würde
    /// (die Maße sind ja bereits korrigiert), sondern als Beleg, dass diese Zeile die
    /// Korrektur gesehen hat. Genau daran erkennt `orientationColumnComplete()`, ob der
    /// einmalige Nachlauf noch aussteht. `0` heißt „der Server führt für dieses Asset
    /// keine Orientierung", `NULL` heißt „noch nicht nachgezogen".
    func updateExifFromSync(_ exifs: [SyncAssetExif]) {
        guard !exifs.isEmpty else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())

        writeQueue.sync {
            guard let db else { return }
            exec("BEGIN TRANSACTION")

            let sql = """
                UPDATE grid_assets SET
                    city           = ?,
                    country        = ?,
                    latitude       = ?,
                    longitude      = ?,
                    cameraMake     = ?,
                    cameraModel    = ?,
                    lensModel      = ?,
                    fileSizeInByte = ?,
                    width          = CASE WHEN ?14 = 1 THEN ?9  ELSE COALESCE(width, ?9)   END,
                    height         = CASE WHEN ?14 = 1 THEN ?10 ELSE COALESCE(height, ?10) END,
                    exifOrientation = ?11,
                    exifCheckedAt  = ?12
                WHERE id = ?13
            """

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                exec("ROLLBACK")
                return
            }
            defer { sqlite3_finalize(stmt) }

            for exif in exifs {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                bindOptionalText(stmt, 1, exif.city)
                bindOptionalText(stmt, 2, exif.country)
                bindOptionalDouble(stmt, 3, exif.latitude)
                bindOptionalDouble(stmt, 4, exif.longitude)
                bindOptionalText(stmt, 5, exif.make)
                bindOptionalText(stmt, 6, exif.model)
                bindOptionalText(stmt, 7, exif.lensModel)
                bindOptionalInt(stmt, 8, exif.fileSizeInByte)
                let tauscht = ExifOrientation.swapsSides(exif.orientation)
                let masse = ExifOrientation.displaySize(
                    width: exif.exifImageWidth ?? 0,
                    height: exif.exifImageHeight ?? 0,
                    orientation: exif.orientation
                )
                let hatMasse = exif.exifImageWidth != nil && exif.exifImageHeight != nil
                bindOptionalInt(stmt, 9, hatMasse ? masse.width : nil)
                bindOptionalInt(stmt, 10, hatMasse ? masse.height : nil)
                // 0 statt NULL, wenn der Server nichts führt: NULL bleibt der Marke
                // „noch nicht nachgezogen" vorbehalten.
                sqlite3_bind_int(stmt, 11, Int32(exif.orientation ?? 0))
                bindText(stmt, 12, stamp)
                bindText(stmt, 13, exif.assetId)
                // Überschreiben nur, wenn die Orientierung tatsächlich etwas ändert —
                // siehe die lange Begründung über dieser Funktion.
                sqlite3_bind_int(stmt, 14, (tauscht && hatMasse) ? 1 : 0)
                sqlite3_step(stmt)
            }

            exec("COMMIT")
        }
    }

    /// Load ALL visible assets that match a given camera model (case-insensitive LIKE).
    /// Used for Smart Album deep scans — bypasses the 4 000-asset window.
    func loadVisible(matchingCameraModel model: String) -> [Asset] {
        var result: [Asset] = []
        readQueue.sync {
            guard let db = readDB else { return }
            let sql = """
                SELECT \(Self.selectColumns)
                FROM grid_assets
                WHERE isTrashed = 0 AND isArchived = 0 AND isHidden = 0
                  AND cameraModel LIKE ? ESCAPE '\\'
                ORDER BY fileCreatedAt DESC
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, "%\(model)%")
            while sqlite3_step(stmt) == SQLITE_ROW {
                result.append(assetFromRow(stmt))
            }
        }
        return result
    }

    /// Modell, EXIF-Vermerk und Aufnahmezeit je ID — für „Nach Kamera aufteilen".
    ///
    /// IDs, die der Index nicht kennt, kommen als „EXIF unbekannt" ohne Aufnahmezeit
    /// zurück, statt still zu fehlen: Sonst schrumpfte die Auswahl beim Übernehmen um
    /// Fotos, die der Nutzer nie abgewählt hat. Die Reihenfolge ist die der Eingabe.
    ///
    /// - Returns: `nil`, wenn der Index nicht lesbar ist.
    func kameraZeilen(ids: [String]) -> [KameraZeile]? {
        guard !ids.isEmpty else { return [] }
        var gefunden: [String: KameraZeile] = [:]
        var readable = true

        readQueue.sync {
            guard let db = readDB else { readable = false; return }
            var offset = 0
            while offset < ids.count {
                let chunk = Array(ids[offset..<min(offset + 900, ids.count)])
                offset += chunk.count

                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                let sql = """
                    SELECT id, NULLIF(TRIM(cameraModel), ''), exifCheckedAt IS NOT NULL,
                           CAST(strftime('%s', fileCreatedAt) AS INTEGER)
                    FROM grid_assets
                    WHERE id IN (\(placeholders))
                """
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                    readable = false
                    return
                }
                defer { sqlite3_finalize(stmt) }
                for (i, id) in chunk.enumerated() {
                    bindText(stmt, Int32(i + 1), id)
                }
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let zeile = KameraZeile(
                        id: columnText(stmt, 0),
                        modell: columnOptionalText(stmt, 1),
                        exifGeprueft: sqlite3_column_int(stmt, 2) != 0,
                        aufnahme: columnOptionalInt(stmt, 3)
                    )
                    gefunden[zeile.id] = zeile
                }
            }
        }

        guard readable else {
            AppLogger.app.error("kameraZeilen: Grid-Index nicht lesbar")
            return nil
        }
        return ids.map {
            gefunden[$0] ?? KameraZeile(id: $0, modell: nil, exifGeprueft: false, aufnahme: nil)
        }
    }

    /// Sichtbare Fotos je Kameramodell in einem Zeitfenster (Sekunden seit 1970) —
    /// daraus bestimmt „Nach Kamera aufteilen" die Hauptkamera des Zeitraums.
    ///
    /// - Returns: `nil`, wenn der Index nicht lesbar ist.
    func kameraAnzahlen(in fenster: ClosedRange<Int>) -> [String: Int]? {
        var result: [String: Int] = [:]
        var readable = true

        readQueue.sync {
            guard let db = readDB else { readable = false; return }
            let sql = """
                SELECT TRIM(cameraModel), COUNT(*)
                FROM grid_assets
                WHERE isTrashed = 0 AND isArchived = 0 AND isHidden = 0
                  AND cameraModel IS NOT NULL AND TRIM(cameraModel) <> ''
                  AND CAST(strftime('%s', fileCreatedAt) AS INTEGER) BETWEEN ? AND ?
                GROUP BY TRIM(cameraModel)
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                readable = false
                return
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(fenster.lowerBound))
            sqlite3_bind_int64(stmt, 2, Int64(fenster.upperBound))
            while sqlite3_step(stmt) == SQLITE_ROW {
                result[columnText(stmt, 0)] = Int(sqlite3_column_int64(stmt, 1))
            }
        }

        guard readable else {
            AppLogger.app.error("kameraAnzahlen: Grid-Index nicht lesbar")
            return nil
        }
        return result
    }

    /// Alle sichtbaren Assets im Umkreis einer Koordinate.
    ///
    /// Zweistufig, weil SQLite keine Entfernungsfunktion hat: Erst schneidet ein
    /// Rechteck den Kandidatenkreis grob heraus — das kann über `latitude`/`longitude`
    /// laufen —, dann rechnet ``GeoDistance/meters(fromLat:fromLon:toLat:toLon:)`` die
    /// echte Entfernung nach. Ohne den zweiten Schritt wären die Ecken des Rechtecks
    /// bis zu 41 % zu weit entfernt.
    ///
    /// Das ist die Grundlage der Straßensuche: Immich kennt pro Foto nur Stadt, Land
    /// und Bundesland, aber die Koordinaten stehen hier.
    func loadVisible(nearLatitude lat: Double, longitude lon: Double, radiusMeters radius: Double) -> [Asset] {
        let box = GeoDistance.boundingBox(lat: lat, lon: lon, radius: radius)
        var result: [Asset] = []
        readQueue.sync {
            guard let db = readDB else { return }
            let sql = """
                SELECT \(Self.selectColumns)
                FROM grid_assets
                WHERE isTrashed = 0 AND isArchived = 0 AND isHidden = 0
                  AND latitude IS NOT NULL AND longitude IS NOT NULL
                  AND latitude BETWEEN ? AND ?
                  AND longitude BETWEEN ? AND ?
                ORDER BY fileCreatedAt DESC
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, box.minLat)
            sqlite3_bind_double(stmt, 2, box.maxLat)
            sqlite3_bind_double(stmt, 3, box.minLon)
            sqlite3_bind_double(stmt, 4, box.maxLon)
            while sqlite3_step(stmt) == SQLITE_ROW {
                let asset = assetFromRow(stmt)
                guard let aLat = asset.exifInfo?.latitude, let aLon = asset.exifInfo?.longitude else { continue }
                if GeoDistance.meters(fromLat: lat, fromLon: lon, toLat: aLat, toLon: aLon) <= radius {
                    result.append(asset)
                }
            }
        }
        return result
    }

    /// Return all distinct, non-null camera models in the index, sorted alphabetically.
    /// Used to populate the Smart Album camera-rule picker.
    /// Count of non-trashed assets that have no cameraModel AND no city (= EXIF never loaded).
    /// Von den übergebenen IDs diejenigen, die noch nie beim Server nach EXIF gefragt
    /// wurden.
    ///
    /// `exifCheckedAt` bedeutet **nicht** „hat EXIF", sondern „wir haben danach gefragt".
    /// Ein Scan, ein Screenshot oder ein WhatsApp-Bild wird einmal gefragt, kommt leer
    /// zurück, wird markiert — und taucht nie wieder auf. Eine Abfrage auf das *Ergebnis*
    /// (`cameraModel IS NULL`) könnte das nicht und würde solche Assets bei jedem
    /// Durchlauf erneut anfragen.
    ///
    /// Wird nach jedem Sync nur für die *geänderten* Assets aufgerufen, ist also so groß
    /// wie der Sync und nicht wie die Bibliothek.
    ///
    /// Bewusst **ohne** das `isHidden = 0` der Zählfunktionen: Die Pools der Aufrufer
    /// (Grid, Person-Fetch, Deep-Scan, Server-Suche) enthalten nie versteckte Assets.
    /// Käme doch eine versteckte ID herein, ist „ungeprüft" die sichere Antwort — das
    /// EXIF-Gate der Smart Albums hält sie dann konservativ zurück, statt sie mit
    /// leeren EXIF-Spalten als „hat kein GPS" in einen Server-Mirror hochzuladen.
    ///
    /// - Returns: `nil`, wenn der Index nicht lesbar ist — sei es, weil die
    ///   Lese-Verbindung nie erfolgreich geöffnet wurde, sei es, weil ein Statement
    ///   nicht vorbereitet werden konnte. Ein leeres Array bedeutet dagegen „nichts
    ///   offen". Der Aufrufer muss beides unterscheiden können: diese Liste füttert
    ///   das EXIF-Gate der Smart Albums — ein fälschliches `[]` ließe dort jedes Asset
    ///   als EXIF-geprüft gelten, obwohl niemand nachgesehen hat.
    func idsMissingExifCheck(among ids: [String]) -> [String]? {
        guard !ids.isEmpty else { return [] }
        var result: [String] = []
        var readable = true

        readQueue.sync {
            guard let db = readDB else {
                AppLogger.app.error("idsMissingExifCheck: Grid-Index nicht lesbar — Lese-Verbindung nicht offen")
                readable = false
                return
            }

            // SQLite erlaubt konservativ 999 gebundene Variablen pro Statement.
            var offset = 0
            while offset < ids.count {
                let chunk = Array(ids[offset..<min(offset + 900, ids.count)])
                offset += chunk.count

                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                let sql = """
                    SELECT id FROM grid_assets
                    WHERE id IN (\(placeholders))
                      AND exifCheckedAt IS NULL
                """

                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                    AppLogger.app.error("idsMissingExifCheck: Statement konnte nicht vorbereitet werden: \(String(cString: sqlite3_errmsg(db)))")
                    readable = false
                    continue
                }
                defer { sqlite3_finalize(stmt) }

                for (index, id) in chunk.enumerated() {
                    bindText(stmt, Int32(index + 1), id)
                }
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let raw = sqlite3_column_text(stmt, 0) {
                        result.append(String(cString: raw))
                    }
                }
            }
        }
        return readable ? result : nil
    }

    /// Der ehrliche Nenner für die EXIF-Reparatur: wie viele Assets wurden noch nie
    /// beim Server nach EXIF gefragt.
    ///
    /// Die frühere Zählung fragte nach dem *Ergebnis* („kein cameraModel, keine city")
    /// und zählte damit auch Scans, Screenshots und Messenger-Bilder mit, die nie EXIF
    /// hatten und nie welches bekommen können. Der Fortschrittsbalken blieb deshalb
    /// stehen und sprang am Ende ohne Erklärung auf „fertig".
    /// Offene EXIF-Prüfungen, oder `0`, wenn die Abfrage nicht durchlief.
    ///
    /// Für Anzeigezwecke reicht das. Wer daraus ableitet, dass **nichts zu tun** ist,
    /// nimmt ``countAssetsWithoutExifCheckChecked()`` — sonst sieht ein Lesefehler
    /// aus wie „alles geprüft".
    /// Ab welcher Indexgröße der Größenvergleich mit SwiftData überhaupt etwas aussagt.
    ///
    /// Unterhalb davon sind Schwankungen normal (frische Installation, laufender
    /// Erstsync) und ein Vergleich hieße nichts.
    static let storeComparisonMinimumRows = 500

    /// Ob der SwiftData-Bestand **deutlich** kleiner ist als der Grid-Index — das
    /// Kennzeichen eines zurückgesetzten Stores neben einem überlebenden Index.
    ///
    /// Diese Rechnung stand an zwei Stellen mit denselben Zahlen: hier im
    /// EXIF-v8-Backfill und in `SyncEngine.performSync`. Der Kommentar am Backfill
    /// verlangte ausdrücklich, dass „beide Stellen dieselbe Vorstellung von ‚deutlich
    /// weniger'" haben — durchgesetzt war das nicht.
    ///
    /// Bewusst **ohne** `Int?`: Was ein Lesefehler bedeutet, ist an den beiden Stellen
    /// verschieden. Hier heißt eine unlesbare Zählung „abbrechen" (sicher), im
    /// `SyncEngine` müsste sie „nichts tun" heißen, weil ein Ja dort einen
    /// Komplett-Neuabgleich auslöst. Gemeinsam ist der Schwellenwert, nicht die
    /// Deutung des Fehlers.
    static func swiftDataLooksSmaller(cachedCount: Int, gridCount: Int) -> Bool {
        gridCount > storeComparisonMinimumRows && cachedCount < gridCount / 2
    }

    func countAssetsWithoutExifCheck() -> Int {
        countAssetsWithoutExifCheckChecked() ?? 0
    }

    /// Wie ``countAssetsWithoutExifCheck()``, aber `nil`, wenn die Abfrage nicht
    /// durchlief. Dieselbe Unterscheidung wie bei ``countVisibleChecked()``.
    func countAssetsWithoutExifCheckChecked() -> Int? {
        var result: Int?
        readQueue.sync {
            guard let db = readDB else { return }
            var stmt: OpaquePointer?
            // `isHidden = 0`: Versteckte Assets (Motion-Photo-Videoteile) bekommen vom
            // Server nie EXIF und fehlen in der Server-Suche — die Reparatur kann sie
            // nie als geprüft markieren. Im Nenner hielten sie die Anzeige dauerhaft
            // auf „n noch nicht geprüft".
            let sql = "SELECT COUNT(*) FROM grid_assets WHERE isTrashed = 0 AND isHidden = 0 AND exifCheckedAt IS NULL"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            if sqlite3_step(stmt) == SQLITE_ROW {
                result = Int(sqlite3_column_int(stmt, 0))
            }
        }
        return result
    }

    /// Vermerkt für die übergebenen IDs, dass der Server nach EXIF gefragt wurde —
    /// unabhängig davon, ob er welches geliefert hat.
    func markExifChecked(ids: [String], at date: Date = Date()) {
        guard !ids.isEmpty else { return }
        let stamp = ISO8601DateFormatter().string(from: date)

        writeQueue.sync {
            guard let db else { return }
            exec("BEGIN TRANSACTION")

            var offset = 0
            while offset < ids.count {
                let chunk = Array(ids[offset..<min(offset + 900, ids.count)])
                offset += chunk.count

                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                let sql = "UPDATE grid_assets SET exifCheckedAt = ? WHERE id IN (\(placeholders))"

                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
                defer { sqlite3_finalize(stmt) }

                bindText(stmt, 1, stamp)
                for (index, id) in chunk.enumerated() {
                    bindText(stmt, Int32(index + 2), id)
                }
                sqlite3_step(stmt)
            }

            exec("COMMIT")
        }
    }

    /// Marke für den einmaligen Checksum-Backfill nach der v9-Migration.
    /// UserDefaults statt SwiftData aus demselben Grund wie `exifV8BackfillKey`:
    /// eine Schema-Migration wäre für eine Fortschrittsmarke der falsche Preis.
    /// Gelöscht wird sie erst, wenn der Checkpoint-Reset-Replay durchgelaufen
    /// ist (SyncEngine) — bis dahin wiederholt jeder Sync den Versuch.
    static let checksumBackfillPendingKey = "gridIndex.checksumBackfillPending"

    func isChecksumBackfillPending() -> Bool {
        defaults.bool(forKey: Self.checksumBackfillPendingKey)
    }

    func clearChecksumBackfillPending() {
        defaults.removeObject(forKey: Self.checksumBackfillPendingKey)
        defaults.removeObject(forKey: Self.checksumBackfillAttemptsKey)
    }

    /// Ob die checksum-Spalte nachweislich vollständig ist.
    ///
    /// Drei Antworten, bewusst getrennt:
    /// - `true`:  Tabelle hat Zeilen und keine ohne Checksum — Backfill unnötig,
    ///            die Marke darf fallen.
    /// - `false`: Es fehlen Checksums ODER die Tabelle ist leer. Leer heißt nicht
    ///            vollständig: Ein laufender Neuaufbau aus SwiftData
    ///            (`upsertFromCache`, ohne Checksum) füllt sie gleich mit
    ///            NULL-Checksums — die Marke muss stehen bleiben.
    /// - `nil`:   Index nicht lesbar. Weder Marke fällen noch Replay anstoßen —
    ///            der nächste Sync fragt erneut.
    func checksumColumnComplete() -> Bool? {
        var result: Bool?
        readQueue.sync {
            guard let db = readDB else { return }
            var stmt: OpaquePointer?
            let sql = """
                SELECT EXISTS(SELECT 1 FROM grid_assets),
                       EXISTS(SELECT 1 FROM grid_assets WHERE checksum IS NULL)
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            if sqlite3_step(stmt) == SQLITE_ROW {
                let hasRows = sqlite3_column_int(stmt, 0) != 0
                let hasNulls = sqlite3_column_int(stmt, 1) != 0
                result = hasRows && !hasNulls
            }
        }
        return result
    }

    // MARK: - Einmaliger Nachlauf für die EXIF-Orientierung

    /// Marke: Die EXIF-Zeilen müssen einmal neu geholt werden, weil sie beim ersten Mal
    /// ohne `orientation` kamen und die Maße im Index deshalb die rohen Sensorwerte sind.
    ///
    /// Gesetzt bei der Migration auf Schema v10, gelöscht nach einem nachweislich
    /// vollständigen Replay. Liegt neben den anderen Marken in UserDefaults — eine
    /// Fortschrittsmarke rechtfertigt keine eigene Tabelle.
    static let orientationBackfillPendingKey = "gridIndex.orientationBackfillPending"

    static func isOrientationBackfillPending(defaults: UserDefaults = AppEnvironment.defaults) -> Bool {
        defaults.bool(forKey: Self.orientationBackfillPendingKey)
    }

    func isOrientationBackfillPending() -> Bool {
        Self.isOrientationBackfillPending(defaults: defaults)
    }

    func clearOrientationBackfillPending() {
        defaults.removeObject(forKey: Self.orientationBackfillPendingKey)
        defaults.removeObject(forKey: Self.orientationBackfillAttemptsKey)
    }

    /// Ob die Orientierung nachweislich überall nachgezogen ist.
    ///
    /// Gefragt wird nur nach Zeilen, die schon einmal EXIF gesehen haben
    /// (`exifCheckedAt IS NOT NULL`): Für alle anderen steht der Nachlauf ohnehin noch
    /// bevor, und ihr `NULL` sagt nichts über den Erfolg des Replays.
    ///
    /// - `true`: Es gibt geprüfte Zeilen und keine davon ohne `exifOrientation`.
    /// - `false`: Es fehlen welche — oder es gibt noch gar keine geprüfte Zeile. Leer
    ///   heißt hier nicht fertig, sondern „zu früh": Ein laufender Neuaufbau aus
    ///   SwiftData füllt gleich Zeilen ohne Orientierung nach.
    /// - `nil`: Index nicht lesbar; weder Marke fällen noch Replay anstoßen.
    func orientationColumnComplete() -> Bool? {
        var result: Bool?
        readQueue.sync {
            guard let db = readDB else { return }
            var stmt: OpaquePointer?
            let sql = """
                SELECT EXISTS(SELECT 1 FROM grid_assets WHERE exifCheckedAt IS NOT NULL),
                       EXISTS(SELECT 1 FROM grid_assets
                              WHERE exifCheckedAt IS NOT NULL AND exifOrientation IS NULL)
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            if sqlite3_step(stmt) == SQLITE_ROW {
                let hatGeprüfte = sqlite3_column_int(stmt, 0) != 0
                let hatLücken = sqlite3_column_int(stmt, 1) != 0
                result = hatGeprüfte && !hatLücken
            }
        }
        return result
    }

    static let orientationBackfillAttemptsKey = "gridIndex.orientationBackfillAttempts"

    static let orientationBackfillMaxAttempts = 3

    func registerOrientationBackfillFailure() -> Int {
        let next = defaults.integer(forKey: Self.orientationBackfillAttemptsKey) + 1
        defaults.set(next, forKey: Self.orientationBackfillAttemptsKey)
        return next
    }

    /// Versuchsbudget für den Checkpoint-Reset-Replay: Ein dauerhaft
    /// scheiternder Replay (Netzwerk, Server-Fehler) soll nicht bei jedem
    /// Sync unbegrenzt erneut zünden. Zähler liegt neben der Marke in
    /// UserDefaults — gleiche Begründung, keine Schema-Migration für einen
    /// Fortschrittszähler.
    static let checksumBackfillAttemptsKey = "gridIndex.checksumBackfillAttempts"

    /// Nach der wievielten Runde die SyncEngine die Reißleine zieht und die
    /// Marke unabhängig vom Ausgang fallen lässt.
    static let checksumBackfillMaxAttempts = 3

    /// Erhöht den Fehlschlag-Zähler und liefert den neuen Stand — der Aufrufer
    /// vergleicht ihn gegen `checksumBackfillMaxAttempts`.
    func registerChecksumBackfillFailure() -> Int {
        let next = defaults.integer(forKey: Self.checksumBackfillAttemptsKey) + 1
        defaults.set(next, forKey: Self.checksumBackfillAttemptsKey)
        return next
    }

    /// Marker gegen Doppelläufe. Bewusst in UserDefaults statt in SwiftData — ein Feld
    /// an `SyncState` wäre eine Schema-Migration, und die ist für eine einmalige
    /// Fortschrittsmarke der falsche Preis. `ExifRepairModel` hält seinen Resume-Cursor
    /// aus demselben Grund hier.
    ///
    /// Bewusst `internal` statt `private`: `GridIndexStoreTests` liest den Marker über
    /// `@testable import` direkt aus, um den Store-Reset-Schutz zu prüfen (Marker bleibt
    /// nach einem abgebrochenen Lauf ungesetzt). `@testable` schaltet nur auf `internal`
    /// hoch, nicht auf `private` — die Sichtbarkeit ist also absichtlich so gewählt und
    /// keine übersehene Aufräumarbeit.
    static let exifV8BackfillKey = "gridIndex.exifV8BackfillDone"

    /// Ob der einmalige v8-Backfill nachweislich durchgelaufen ist — und damit, ob die
    /// Invariante **`exifCheckedAt IS NOT NULL` ⟹ EXIF-Spalten autoritativ** gilt.
    ///
    /// Vorbedingung für jede Auswertung des EXIF-Gates (siehe
    /// `SmartAlbumEvaluator.resolveExifGate`): Direkt nach der v8-Migration tragen
    /// zehntausende Zeilen einen Prüfzeitpunkt bei leeren EXIF-Spalten.
    /// `idsMissingExifCheck` meldet die als geprüft, `latitude` ist trotzdem `NULL` —
    /// „hat kein GPS" träfe dann fast die gesamte Bibliothek. Das Fenster kann lang
    /// sein: Der Backfill läuft mit `.background`-QoS hinter dem Kaltstart-Sync.
    ///
    /// Bewusst **nicht** in `idsMissingExifCheck` selbst geprüft: `ExifRepairModel`
    /// benutzt die Methode während genau dieses Fensters und würde sonst fälschlich
    /// „Index nicht lesbar" melden.
    ///
    /// - Parameter defaults: nur für Tests injizierbar; die App nutzt
    ///   `AppEnvironment.defaults`.
    static func exifV8BackfillComplete(defaults: UserDefaults = AppEnvironment.defaults) -> Bool {
        defaults.bool(forKey: exifV8BackfillKey)
    }

    /// Chunk-Größe für den Backfill: so viele IDs pro `#Predicate`-Fetch und pro
    /// Lese-Seite. Bewusst identisch zum erprobten Maß in `SyncEngine` — dasselbe
    /// `Set<String>.contains`-Muster läuft dort mit maximal 1 000 IDs.
    private static let exifV8ChunkSize = 1_000

    /// Füllt `latitude`, `longitude`, `cameraMake` und `fileSizeInByte` einmalig aus
    /// SwiftData nach — `CachedAsset` trägt die Werte bereits.
    ///
    /// Stellt die Invariante her, auf der alle „hat kein X"-Regeln beruhen:
    /// **`exifCheckedAt IS NOT NULL` ⟹ alle EXIF-Spalten sind autoritativ.**
    /// Direkt nach der v8-Migration gilt sie nicht — die neuen Spalten sind leer,
    /// `exifCheckedAt` steht aber bei vielen Zeilen. Ohne diesen Lauf würde jedes
    /// Asset mit gesetztem `exifCheckedAt` fälschlich als „hat kein GPS" gelten.
    ///
    /// Rein lokal, kein Server-Roundtrip. Der frühere Voll-Backfill über die API wurde
    /// wegen genau dieser Kosten entfernt (der damalige Ersatz dafür war
    /// `SyncEngine.exifCatchUp`; heute liefert `AssetExifsV1` im Sync-Stream EXIF direkt).
    ///
    /// Zeilen ohne passenden `CachedAsset` bekommen `exifCheckedAt = NULL` und fallen
    /// damit an die bestehende EXIF-Reparatur zurück, statt die Invariante zu brechen.
    ///
    /// Der Lauf passiert genau **einmal im App-Leben**; alles, was dabei schiefgeht,
    /// bliebe dauerhaft falsch. Deshalb wird der Marker erst gesetzt, wenn der Lauf
    /// nachweislich vollständig war: Ist der Index nicht lesbar, scheitert ein
    /// SwiftData-Fetch oder ein SQL-`prepare`, bleibt er ungesetzt und der nächste
    /// Start wiederholt. Das ist gefahrlos, weil der Backfill nur *füllt* (siehe
    /// `writeExifV8`) und deshalb idempotent ist.
    ///
    /// - Parameter defaults: nur für Tests injizierbar; die App nutzt
    ///   `AppEnvironment.defaults`.
    func backfillExifV8(from container: ModelContainer, defaults: UserDefaults = AppEnvironment.defaults) async {
        guard !Self.exifV8BackfillComplete(defaults: defaults) else { return }

        let alreadyRunning = backfillInProgress.withLock { running -> Bool in
            if running { return true }
            running = true
            return false
        }
        guard !alreadyRunning else {
            AppLogger.app.info("EXIF-v8-Backfill: läuft bereits — zweiter Aufruf übersprungen")
            return
        }
        defer { backfillInProgress.withLock { $0 = false } }

        // Schutz vor einem geleerten/zurückgesetzten SwiftData-Store (siehe
        // `SyncEngine.performSync`, Store-Reset-Erkennung um Zeile 304): Dieser Backfill
        // startet aus `ContentView.task` und kann damit vor dem ersten Sync-Lauf laufen —
        // vor der Erkennung dort. Ohne diese Prüfung deutete jede Zeile „kein CachedAsset
        // gefunden" als „verwaist", der Lauf setzte `exifCheckedAt` über die gesamte
        // Bibliothek auf NULL und markierte sich danach trotzdem als vollständig, weil
        // dabei kein Fehler auftrat — der einmalige Lauf wäre verbraucht, ohne je etwas
        // Sinnvolles getan zu haben. Gleicher Schwellenwert wie in `SyncEngine`, damit
        // beide Stellen dieselbe Vorstellung von „deutlich weniger" haben.
        let gridCount = totalAssetCount()
        do {
            let cachedCount = await Task.detached(priority: .utility) { () -> Int in
                // `?? 0` ist hier die **sichere** Richtung: Ein Lesefehler führt zum
                // Abbruch, und der Marker bleibt ungesetzt. Im `SyncEngine` ist es
                // umgekehrt — dort löste eine Null einen Komplett-Neuabgleich aus und
                // musste eigens abgesichert werden. Gemeinsam ist beiden nur der
                // Schwellenwert, nicht die Deutung des Fehlers.
                let ctx = ModelContext(container)
                return (try? ctx.fetchCount(FetchDescriptor<CachedAsset>())) ?? 0
            }.value
            guard !Self.swiftDataLooksSmaller(cachedCount: cachedCount, gridCount: gridCount) else {
                AppLogger.app.error("EXIF-v8-Backfill abgebrochen: SwiftData wirkt leer oder zurückgesetzt (cached=\(cachedCount), grid=\(gridCount)) — Marker bleibt ungesetzt, der nächste Start wiederholt")
                return
            }
        }

        var seen = 0
        var filled = 0
        var orphanedTotal = 0
        var incomplete = false
        var cursor = ""

        AppLogger.app.info("EXIF-v8-Backfill gestartet")

        while true {
            // Seitenweise lesen: ein voller Tabellenscan über ~155 000 Zeilen würde die
            // readQueue (.userInitiated) am Stück blockieren — genau die Queue, die
            // parallel den Timeline-Kaltstart bedient.
            guard let chunk = assetIdPage(after: cursor, limit: Self.exifV8ChunkSize) else {
                AppLogger.app.error("EXIF-v8-Backfill abgebrochen: Grid-Index nicht lesbar — Marker bleibt ungesetzt")
                return
            }
            guard let last = chunk.last else { break }
            cursor = last
            seen += chunk.count

            let idSet = Set(chunk)
            let rows: [(String, Double?, Double?, String?, Int?)]? =
                await Task.detached(priority: .utility) {
                    let ctx = ModelContext(container)
                    ctx.autosaveEnabled = false
                    let descriptor = FetchDescriptor<CachedAsset>(
                        predicate: #Predicate { idSet.contains($0.assetId) }
                    )
                    do {
                        return try ctx.fetch(descriptor).map {
                            ($0.assetId, $0.latitude, $0.longitude, $0.cameraMake, $0.fileSizeInByte)
                        }
                    } catch {
                        AppLogger.app.error("EXIF-v8-Backfill: SwiftData-Fetch fehlgeschlagen: \(error.localizedDescription)")
                        return nil
                    }
                }.value

            // Fetch fehlgeschlagen: diesen Chunk komplett auslassen. Die Zeilen jetzt als
            // verwaist zu behandeln, würde 1 000 intakte EXIF-Prüfungen verwerfen.
            guard let rows else {
                incomplete = true
                continue
            }

            if let changed = writeExifV8(rows) {
                filled += changed
            } else {
                incomplete = true
            }

            // Pro Chunk aufräumen statt am Ende — sonst stünden im schlimmsten Fall
            // alle 155 000 IDs gleichzeitig im Speicher.
            let orphaned = Array(idSet.subtracting(rows.map(\.0)))
            if !orphaned.isEmpty {
                orphanedTotal += orphaned.count
                if !clearExifChecked(ids: orphaned) {
                    incomplete = true
                }
            }
        }

        if orphanedTotal > 0 {
            AppLogger.app.info("EXIF-v8-Backfill: \(orphanedTotal) Zeilen ohne CachedAsset — zurück in die EXIF-Reparatur")
        }

        guard !incomplete else {
            AppLogger.app.error("EXIF-v8-Backfill unvollständig: \(seen) Zeilen geprüft, \(filled) ergänzt — Marker bleibt ungesetzt, der nächste Start wiederholt")
            return
        }

        defaults.set(true, forKey: Self.exifV8BackfillKey)
        AppLogger.app.info("EXIF-v8-Backfill fertig: \(seen) Zeilen geprüft, \(filled) ergänzt, \(orphanedTotal) offen")

        // Die Oberfläche neu laden lassen — aus zwei Gründen, die beide sonst bis zum
        // nächsten Ansichtswechsel liegen blieben:
        // 1. Offene Smart-Album-Ansichten zeigen das „Backfill läuft"-Band und rechnen
        //    mit einem Gate, das den gesamten Pool als ungeprüft führt.
        // 2. Der In-Memory-Asset-Pool wurde vor dem Backfill geladen — seine
        //    `exifInfo`-Felder sind noch leer, obwohl der Index jetzt gefüllt ist.
        // Der userInfo-lose Post nimmt in LibraryViewModel den Fallback-Zweig
        // (`loadAssetsFromCache()`), der beides erledigt: Pool neu aus dem Index laden
        // und `forceRefreshTrigger` bumpen, worauf `SmartAlbumDetailView.task(id:)`
        // das Gate neu auflöst.
        await MainActor.run {
            NotificationCenter.default.post(name: .assetsDidChange, object: nil)
        }
    }

    /// Eine nach `id` sortierte Seite von Asset-IDs, beginnend hinter `after`.
    ///
    /// Keyset- statt OFFSET-Paginierung: Sie kommt ohne wachsenden Vorlauf-Scan aus und
    /// bleibt stabil, wenn während des Laufs Zeilen eingefügt oder gelöscht werden.
    ///
    /// Kein `isTrashed`-Filter: Papierkorb-Zeilen behalten ihr `exifCheckedAt`. Würden
    /// sie ausgelassen, hätte ein wiederhergestelltes Asset danach dauerhaft gesetztes
    /// `exifCheckedAt` bei leeren EXIF-Spalten — `upsertFromSync` setzt beim Restore nur
    /// `isTrashed = 0` und rührt die EXIF-Spalten bewusst nicht an.
    ///
    /// - Returns: `nil`, wenn der Index nicht lesbar ist — ein leeres Array bedeutet
    ///   dagegen „fertig". Der Aufrufer muss beides unterscheiden können.
    private func assetIdPage(after: String, limit: Int) -> [String]? {
        var result: [String]?
        readQueue.sync {
            guard let db = readDB else { return }
            var stmt: OpaquePointer?
            let sql = "SELECT id FROM grid_assets WHERE id > ? ORDER BY id LIMIT ?"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, after)
            sqlite3_bind_int(stmt, 2, Int32(limit))
            var page: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let raw = sqlite3_column_text(stmt, 0) {
                    page.append(String(cString: raw))
                }
            }
            result = page
        }
        return result
    }

    /// Schreibt die EXIF-Momentaufnahme aus SwiftData in den Index — **nur in leere
    /// Spalten**.
    ///
    /// Die Bedingung ist keine Optimierung, sondern die Absicherung gegen ein Rennen:
    /// Zwischen Lesen (T0) und Schreiben (T0+Δ) kann `AssetExifsV1` im Sync-Stream
    /// frisches EXIF vom Server in dieselbe Zeile geschrieben haben. Ohne die Bedingung setzte
    /// der Backfill es mit seiner veralteten Momentaufnahme wieder auf `NULL` — und weil
    /// `exifCheckedAt` dabei gesetzt bleibt, sähe die EXIF-Reparatur die Zeile nie
    /// wieder. Steht bereits ein Wert, ist er autoritativ; kein legitimer Fall geht
    /// dadurch verloren.
    ///
    /// - Returns: Zahl der tatsächlich geänderten Zeilen, oder `nil`, wenn die
    ///   Datenbankverbindung nicht offen war, das Statement nicht vorbereitet werden
    ///   konnte, `BEGIN`/`COMMIT` fehlschlug oder ein `sqlite3_step` nicht `SQLITE_DONE`
    ///   lieferte — all das lässt den Marker in `backfillExifV8` ungesetzt.
    ///
    /// Prüft `BEGIN`/`COMMIT` und jedes `sqlite3_step`, obwohl das sonst in dieser Klasse
    /// nicht Konvention ist (siehe Klassenkommentar). Der Unterschied: jede andere
    /// Methode hier wird bei Bedarf erneut aufgerufen — dieser Backfill läuft
    /// nachweislich genau einmal im App-Leben. Genau das ist im Produktivbetrieb
    /// schiefgegangen: Der erste Lauf über die reale Bibliothek (155 905 Zeilen) fiel in
    /// eine hohe Systemlast (Migration + parallel laufender Sync), brauchte 3,5 Minuten,
    /// schrieb dabei still **null** Zeilen — mit hoher Wahrscheinlichkeit ein
    /// `SQLITE_BUSY` bei `sqlite3_step` oder ein fehlgeschlagenes `COMMIT`, beides damals
    /// ungeprüft — und markierte sich trotzdem als vollständig. Ein zweiter Lauf (nach
    /// manuellem Löschen des Markers) schrieb in 34 Sekunden alle 155 897 Werte korrekt.
    /// Ohne diese Prüfung bleibt ein solcher Fehlschlag für immer unsichtbar, weil der
    /// einmalige Lauf dann bereits verbraucht ist.
    private func writeExifV8(_ rows: [(String, Double?, Double?, String?, Int?)]) -> Int? {
        guard !rows.isEmpty else { return 0 }
        var changed: Int?
        writeQueue.sync {
            guard let db else { return }
            guard exec("BEGIN TRANSACTION") == SQLITE_OK else {
                AppLogger.app.error("EXIF-v8-Backfill: BEGIN TRANSACTION fehlgeschlagen: \(String(cString: sqlite3_errmsg(db)))")
                return
            }
            let sql = """
                UPDATE grid_assets
                SET latitude = ?, longitude = ?, cameraMake = ?, fileSizeInByte = ?
                WHERE id = ?
                  AND latitude IS NULL AND longitude IS NULL
                  AND cameraMake IS NULL AND fileSizeInByte IS NULL
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                AppLogger.app.error("EXIF-v8-Backfill: UPDATE konnte nicht vorbereitet werden: \(String(cString: sqlite3_errmsg(db)))")
                exec("ROLLBACK"); return
            }
            defer { sqlite3_finalize(stmt) }

            var count = 0
            var stepFailed = false
            for (id, lat, lon, make, size) in rows {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                bindOptionalDouble(stmt, 1, lat)
                bindOptionalDouble(stmt, 2, lon)
                bindOptionalText(stmt, 3, make)
                bindOptionalInt(stmt, 4, size)
                bindText(stmt, 5, id)
                let stepResult = sqlite3_step(stmt)
                guard stepResult == SQLITE_DONE else {
                    // Einmalig pro Chunk loggen, nicht pro Zeile — bei SQLITE_BUSY unter
                    // Last würde sonst derselbe Fehler bis zu 1 000-mal geloggt.
                    AppLogger.app.error("EXIF-v8-Backfill: UPDATE-step fehlgeschlagen (code=\(stepResult)): \(String(cString: sqlite3_errmsg(db)))")
                    stepFailed = true
                    break
                }
                // Ehrlich zählen: `rows.count` wären die *geholten* CachedAssets, nicht
                // die geänderten Zeilen.
                count += Int(sqlite3_changes(db))
            }

            guard !stepFailed else {
                exec("ROLLBACK")
                return
            }

            guard exec("COMMIT") == SQLITE_OK else {
                AppLogger.app.error("EXIF-v8-Backfill: COMMIT fehlgeschlagen: \(String(cString: sqlite3_errmsg(db)))")
                exec("ROLLBACK")
                return
            }
            changed = count
        }
        return changed
    }

    /// Nimmt die übergebenen IDs zurück in die Arbeitsliste der EXIF-Reparatur.
    ///
    /// - Returns: `false`, wenn der Index nicht schreibbar war, ein Statement nicht
    ///   vorbereitet werden konnte, `BEGIN`/`COMMIT` fehlschlug oder ein `sqlite3_step`
    ///   nicht `SQLITE_DONE` lieferte — dann ist die v8-Invariante für diese IDs noch
    ///   nicht hergestellt und der Backfill darf sich nicht als fertig markieren.
    ///
    /// Dieselbe Härtung wie `writeExifV8` und aus demselben Grund: Diese Methode läuft
    /// nur innerhalb des einmaligen Backfills (siehe dortiger Kommentar zum
    /// Produktivvorfall — erster Lauf schrieb still 0 Zeilen und markierte sich trotzdem
    /// als vollständig). Andere Methoden dieser Klasse prüfen `sqlite3_step` bewusst
    /// nicht; hier ist das anders, weil ein stiller Fehlschlag den Marker setzen und den
    /// einmaligen Lauf verbrauchen würde, ohne dass er je wiederholt wird.
    private func clearExifChecked(ids: [String]) -> Bool {
        guard !ids.isEmpty else { return true }
        var ok = false
        writeQueue.sync {
            guard let db else { return }
            guard exec("BEGIN TRANSACTION") == SQLITE_OK else {
                AppLogger.app.error("EXIF-v8-Backfill: clearExifChecked BEGIN TRANSACTION fehlgeschlagen: \(String(cString: sqlite3_errmsg(db)))")
                return
            }
            var allPrepared = true
            var offset = 0
            while offset < ids.count {
                let chunk = Array(ids[offset..<min(offset + 900, ids.count)])
                offset += chunk.count
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                let sql = "UPDATE grid_assets SET exifCheckedAt = NULL WHERE id IN (\(placeholders))"
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                    AppLogger.app.error("EXIF-v8-Backfill: clearExifChecked konnte nicht vorbereitet werden: \(String(cString: sqlite3_errmsg(db)))")
                    allPrepared = false
                    continue
                }
                defer { sqlite3_finalize(stmt) }
                for (index, id) in chunk.enumerated() {
                    bindText(stmt, Int32(index + 1), id)
                }
                let stepResult = sqlite3_step(stmt)
                guard stepResult == SQLITE_DONE else {
                    // Einmalig pro Chunk loggen, nicht pro Zeile/Batch — sonst könnte
                    // SQLITE_BUSY unter Last denselben Fehler mehrfach wiederholen.
                    AppLogger.app.error("EXIF-v8-Backfill: clearExifChecked-step fehlgeschlagen (code=\(stepResult)): \(String(cString: sqlite3_errmsg(db)))")
                    allPrepared = false
                    continue
                }
            }
            guard allPrepared else {
                exec("ROLLBACK")
                return
            }
            guard exec("COMMIT") == SQLITE_OK else {
                AppLogger.app.error("EXIF-v8-Backfill: clearExifChecked COMMIT fehlgeschlagen: \(String(cString: sqlite3_errmsg(db)))")
                exec("ROLLBACK")
                return
            }
            ok = true
        }
        return ok
    }

    /// Total non-trashed asset count in the grid index (used for store-reset detection).
    ///
    /// `readDB` ausdrücklich, nicht die Kurzform `guard let db`: `db` ist der Alias
    /// für die **Schreib**verbindung und laut ihrer eigenen Dokumentation nur auf
    /// `writeQueue` zu benutzen. Diese Funktion läuft auf `readQueue` — die Kurzform
    /// griff hier also über die falsche Queue auf die Schreibverbindung zu, während
    /// nebenan ein Upsert auf derselben Verbindung laufen konnte. Es war die einzige
    /// Lesefunktion der Klasse mit diesem Fehler; alle anderen binden `readDB`.
    func totalAssetCount() -> Int {
        readQueue.sync {
            guard let db = readDB else { return 0 }
            var stmt: OpaquePointer?
            let sql = "SELECT COUNT(*) FROM grid_assets WHERE isTrashed = 0"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
        }
    }

    func distinctCameraModels() -> [String] {
        var result: [String] = []
        readQueue.sync {
            guard let db = readDB else { return }
            let sql = """
                SELECT DISTINCT cameraModel
                FROM grid_assets
                WHERE cameraModel IS NOT NULL AND isTrashed = 0
                ORDER BY cameraModel ASC
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                result.append(columnText(stmt, 0))
            }
        }
        return result
    }

    /// Wie ``distinctCameraModels()``, für den Hersteller. Die Suche bildet „Leica" damit
    /// auf alle Schreibweisen im Bestand ab („LEICA CAMERA AG", „LEICA").
    func distinctCameraMakes() -> [String] {
        var result: [String] = []
        readQueue.sync {
            guard let db = readDB else { return }
            let sql = """
                SELECT DISTINCT cameraMake
                FROM grid_assets
                WHERE cameraMake IS NOT NULL AND isTrashed = 0
                ORDER BY cameraMake ASC
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                result.append(columnText(stmt, 0))
            }
        }
        return result
    }

    /// Distinct non-null cities in the index, sorted by frequency (most photos first).
    /// Used for `place:` token suggestions in Search.
    ///
    /// Standardmäßig **ohne** Deckel: Mit `limit: 50` waren nur die 50 häufigsten Orte
    /// als Chip wählbar, alles darunter gab es in der Suche schlicht nicht — gemessen
    /// 719 von 769 Orten und damit 35 751 Fotos. 769 Zeichenketten im Speicher sind
    /// nichts, die Abfrage lief ohnehin schon.
    func distinctCities(limit: Int? = nil) -> [(city: String, count: Int)] {
        var result: [(String, Int)] = []
        readQueue.sync {
            guard let db = readDB else { return }
            let sql = """
                SELECT city, COUNT(*) AS n
                FROM grid_assets
                WHERE city IS NOT NULL AND isTrashed = 0 AND isArchived = 0 AND isHidden = 0
                GROUP BY city
                ORDER BY n DESC
                LIMIT ?
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(limit ?? -1))
            while sqlite3_step(stmt) == SQLITE_ROW {
                let city  = columnText(stmt, 0)
                let count = Int(sqlite3_column_int64(stmt, 1))
                result.append((city, count))
            }
        }
        return result
    }

    /// Distinct non-null countries in the index, sorted by frequency (most photos first).
    /// Used for `country:` token suggestions in Search.
    ///
    /// Ohne Deckel wie `distinctCities`. Die frühere Grenze von 30 hat nie gebissen
    /// (gemessen 25 Länder) — sie hätte es irgendwann still getan.
    func distinctCountries(limit: Int? = nil) -> [(country: String, count: Int)] {
        var result: [(String, Int)] = []
        readQueue.sync {
            guard let db = readDB else { return }
            let sql = """
                SELECT country, COUNT(*) AS n
                FROM grid_assets
                WHERE country IS NOT NULL AND isTrashed = 0 AND isArchived = 0 AND isHidden = 0
                GROUP BY country
                ORDER BY n DESC
                LIMIT ?
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(limit ?? -1))
            while sqlite3_step(stmt) == SQLITE_ROW {
                let country = columnText(stmt, 0)
                let count   = Int(sqlite3_column_int64(stmt, 1))
                result.append((country, count))
            }
        }
        return result
    }

    /// Delete assets by ID.
    func delete(ids: [String]) {
        guard !ids.isEmpty else { return }
        writeQueue.sync {
            guard let db else { return }

            exec("BEGIN TRANSACTION")

            let sql = "DELETE FROM grid_assets WHERE id = ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
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

    /// Mark assets as trashed by ID (soft delete).
    func markTrashed(ids: [String]) {
        guard !ids.isEmpty else { return }
        writeQueue.sync {
            guard let db else { return }

            exec("BEGIN TRANSACTION")

            let sql = "UPDATE grid_assets SET isTrashed = 1 WHERE id = ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
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

    /// All asset IDs currently flagged as trashed in the grid index. Used by
    /// deletion reconciliation to also heal entries whose flag diverged from
    /// SwiftData.
    func allTrashedIds() -> [String] {
        var result = [String]()
        readQueue.sync {
            guard let db = readDB else { return }
            let sql = "SELECT id FROM grid_assets WHERE isTrashed = 1"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let cString = sqlite3_column_text(stmt, 0) {
                    result.append(String(cString: cString))
                }
            }
        }
        return result
    }

    /// Clear the trashed flag for assets that turned out to be alive on the
    /// server (deletion-reconcile self-healing).
    func unmarkTrashed(ids: [String]) {
        guard !ids.isEmpty else { return }
        writeQueue.sync {
            guard let db else { return }

            exec("BEGIN TRANSACTION")

            let sql = "UPDATE grid_assets SET isTrashed = 0 WHERE id = ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
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

    /// Remove assets from the visible grid (moves to trash in SQLite).
    /// Use this for optimistic local delete — matches what Immich does server-side.
    func removeAssets(ids: [String]) {
        markTrashed(ids: ids)
    }


    /// Update the favorite status of an asset natively in SQLite
    func updateFavorite(id: String, isFavorite: Bool) {
        writeQueue.sync {
            guard let db else { return }

            exec("BEGIN TRANSACTION")

            let sql = "UPDATE grid_assets SET isFavorite = ? WHERE id = ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                exec("ROLLBACK")
                return
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int(stmt, 1, isFavorite ? 1 : 0)
            bindText(stmt, 2, id)
            sqlite3_step(stmt)

            exec("COMMIT")
        }
    }

    /// Update the archive status of an asset natively in SQLite
    func updateArchive(id: String, isArchived: Bool) {
        writeQueue.sync {
            guard let db else { return }

            exec("BEGIN TRANSACTION")

            let sql = "UPDATE grid_assets SET isArchived = ? WHERE id = ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                exec("ROLLBACK")
                return
            }
            defer { sqlite3_finalize(stmt) }

            sqlite3_bind_int(stmt, 1, isArchived ? 1 : 0)
            bindText(stmt, 2, id)
            sqlite3_step(stmt)

            exec("COMMIT")
        }
    }

    // MARK: - GPS-Abgleich

    /// Die Abfrage des Geo-Scans. Als Konstante, damit der Abfrageplan-Test
    /// (`GeoIndexScanTests`) exakt dieselbe Abfrage prüft, die auch läuft.
    ///
    /// `strftime` statt `Asset.createdDate(from:)`: 155 000 `ISO8601DateFormatter`-Aufrufe
    /// kosten je nach Maschine 0,3–0,8 Sekunden reinen Foundation-Overhead. SQLite liest
    /// das ISO-Format nativ und liefert Epochensekunden in C. Sekundenauflösung genügt —
    /// die Schwellen des Abgleichs sind in Minuten.
    ///
    /// `exifCheckedAt IS NOT NULL` ist die tragende Bedingung: Ohne sie kämen Assets in
    /// die Auswertung, nach deren EXIF nie gefragt wurde. Deren `latitude` ist per
    /// Definition `NULL` — sie wären also falsche Waisen und bekämen fremde Koordinaten
    /// aufgeschrieben. Dieselbe Regel wie bei `SmartAlbumEvaluator.hasNoLocation`.
    ///
    /// `INDEXED BY` ist hier bewusst gesetzt und nicht vorsorglich: Ohne die Angabe
    /// wählt SQLite `idx_grid_visible`. Beide Indizes bieten dieselbe Gleichheitssuche
    /// auf den drei Flags, aber nur dieser deckt zusätzlich `latitude`/`longitude` ab.
    /// Der Planer erkennt den Unterschied erst mit `ANALYZE`-Statistiken — und ein
    /// globales `ANALYZE` über 155 000 Zeilen würde die Pläne *aller* anderen Abfragen
    /// dieser Klasse mitverändern, was ein zu breiter Eingriff für dieses eine Problem
    /// wäre. Nachgemessen: ohne Angabe `idx_grid_visible`, mit `ANALYZE` bzw. mit
    /// `INDEXED BY` der hier gewünschte Index.
    ///
    /// Angenehmer Nebeneffekt: Weicht die `WHERE`-Bedingung je vom Prädikat des
    /// partiellen Index ab, scheitert schon `sqlite3_prepare_v2` mit „no query
    /// solution" — der lautlose Rückfall auf einen vollen Tabellenscan ist damit
    /// ausgeschlossen.
    private static let geoScanSQL = """
        SELECT id, CAST(strftime('%s', fileCreatedAt) AS INTEGER), latitude, longitude
        FROM grid_assets INDEXED BY idx_grid_geo_scan
        WHERE isTrashed = 0 AND isArchived = 0 AND isHidden = 0 AND exifCheckedAt IS NOT NULL
        ORDER BY fileCreatedAt ASC
    """

    /// Die schlanke Projektion für den GPS-Abgleich: vier Spalten statt der 22 aus
    /// `selectColumns`.
    ///
    /// Bewusst **nicht** über `assetFromRow`: das baut je Zeile einen `Asset` samt
    /// verschachteltem 15-Feld-`ExifInfo`. Über 155 000 Zeilen sind das zig Megabyte
    /// und eine knappe Million Retain/Release-Paare für vier Werte.
    ///
    /// - Returns: `nil`, wenn der Index nicht lesbar ist. Ein leeres `rows` heißt
    ///   dagegen „nichts Sichtbares" — zwei verschiedene Dinge, wie bei
    ///   `idsMissingExifCheck`.
    func loadGeoScanRows() -> GeoIndexSnapshot? {
        var snapshot: GeoIndexSnapshot?

        readQueue.sync {
            guard let db = readDB else { return }

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, Self.geoScanSQL, -1, &stmt, nil) == SQLITE_OK else {
                AppLogger.app.error("Geo-Scan: Abfrage konnte nicht vorbereitet werden: \(String(cString: sqlite3_errmsg(db)))")
                return
            }
            defer { sqlite3_finalize(stmt) }

            var rows: [GeoScanRow] = []
            rows.reserveCapacity(100_000)
            var unparsable = 0

            while sqlite3_step(stmt) == SQLITE_ROW {
                // Unlesbare Zeitstempel werden gezählt, nicht in SQL weggefiltert —
                // sonst fehlten sie später kommentarlos in jeder Bilanz.
                guard sqlite3_column_type(stmt, 1) != SQLITE_NULL else {
                    unparsable += 1
                    continue
                }
                rows.append(GeoScanRow(
                    id: columnText(stmt, 0),
                    timestamp: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 1))),
                    latitude: columnOptionalDouble(stmt, 2),
                    longitude: columnOptionalDouble(stmt, 3)
                ))
            }

            snapshot = GeoIndexSnapshot(rows: rows, unparsableTimestampCount: unparsable)
        }

        return snapshot
    }

    /// Der Abfrageplan des Geo-Scans.
    ///
    /// Bewusst `internal`: `GeoIndexScanTests` weist damit nach, dass
    /// `idx_grid_geo_scan` tatsächlich benutzt wird. Eine Abweichung zwischen der
    /// `WHERE`-Bedingung der Abfrage und der des partiellen Index ist sonst völlig
    /// lautlos — die Ergebnisse blieben richtig, nur würde jeder Scan über die volle
    /// Tabelle laufen. Dieselbe Begründung wie bei `exifV8BackfillKey`.
    func geoScanQueryPlan() -> [String] {
        var plan: [String] = []
        readQueue.sync {
            guard let db = readDB else { return }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "EXPLAIN QUERY PLAN \(Self.geoScanSQL)", -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                plan.append(columnText(stmt, 3))
            }
        }
        return plan
    }

    // MARK: - Etappen-Scan

    /// Die Projektion für die Albumvorschläge: sieben Spalten statt der 22 aus
    /// `selectColumns`.
    ///
    /// `NOT INDEXED` ist hier Pflicht, aus demselben Grund wie bei `dateScanSQL`:
    /// Ohne den Hinweis wählt SQLite `idx_grid_geo_scan`, weil dessen Prädikat von
    /// dieser `WHERE`-Bedingung impliziert wird. Der Index deckt aber `city` und
    /// `country` nicht ab — jede der 155 000 Zeilen kostete einen Rücksprung in die
    /// Tabelle. Für einen Scan, der ohnehin *alle* sichtbaren Zeilen liest, ist der
    /// glatte Tabellendurchlauf das Billigere.
    ///
    /// Kein `ORDER BY`: `TripSegmenter` sortiert selbst nach (Zeit, ID) — nach der
    /// ID, weil bei gleichem Zeitstempel sonst die Eingabereihenfolge über das
    /// Ergebnis entschiede. Diese Sortierung hier zusätzlich in SQL zu verlangen,
    /// hieße 155 000 Zeilen zweimal zu sortieren.
    ///
    /// `exifCheckedAt` wird mitgelesen statt in `WHERE` weggefiltert — nur so lässt
    /// sich die Lücke beziffern, statt sie zu verschweigen (siehe
    /// `TripIndexSnapshot.exifUncheckedCount`).
    private static let tripScanSQL = """
        SELECT id, CAST(strftime('%s', fileCreatedAt) AS INTEGER),
               latitude, longitude, city, country, exifCheckedAt
        FROM grid_assets NOT INDEXED
        WHERE isTrashed = 0 AND isArchived = 0 AND isHidden = 0
    """

    /// Lädt die sichtbaren Zeilen für die Etappenerkennung.
    ///
    /// - Parameter restrictedTo: Beschränkung auf ein bestehendes Album. Gefiltert
    ///   wird in Swift, nicht per `IN (…)`: ein Album mit 3 000 Fotos ergäbe 3 000
    ///   Platzhalter, und SQLite deckelt die Zahl der Parameter.
    /// - Returns: `nil`, wenn der Index nicht lesbar ist. Ein leeres `rows` heißt
    ///   dagegen „nichts Sichtbares" — zwei verschiedene Dinge, wie bei
    ///   `loadGeoScanRows`.
    func loadTripScanRows(restrictedTo ids: Set<String>? = nil) -> TripIndexSnapshot? {
        var snapshot: TripIndexSnapshot?

        readQueue.sync {
            guard let db = readDB else { return }

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, Self.tripScanSQL, -1, &stmt, nil) == SQLITE_OK else {
                AppLogger.app.error("Etappen-Scan: Abfrage konnte nicht vorbereitet werden: \(String(cString: sqlite3_errmsg(db)))")
                return
            }
            defer { sqlite3_finalize(stmt) }

            var rows: [TripScanRow] = []
            rows.reserveCapacity(ids?.count ?? 100_000)
            var unparsable = 0
            var unchecked = 0

            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = columnText(stmt, 0)
                if let ids, !ids.contains(id) { continue }

                guard sqlite3_column_type(stmt, 6) != SQLITE_NULL else {
                    unchecked += 1
                    continue
                }
                // Unlesbare Zeitstempel werden gezählt, nicht weggefiltert —
                // sonst fehlten sie später kommentarlos in jeder Bilanz.
                guard sqlite3_column_type(stmt, 1) != SQLITE_NULL else {
                    unparsable += 1
                    continue
                }

                rows.append(TripScanRow(
                    id: id,
                    timestamp: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 1))),
                    latitude: columnOptionalDouble(stmt, 2),
                    longitude: columnOptionalDouble(stmt, 3),
                    city: columnOptionalText(stmt, 4),
                    country: columnOptionalText(stmt, 5)
                ))
            }

            snapshot = TripIndexSnapshot(rows: rows,
                                         unparsableTimestampCount: unparsable,
                                         exifUncheckedCount: unchecked)
        }

        return snapshot
    }

    /// Der Abfrageplan des Etappen-Scans.
    ///
    /// Bewusst `internal`, aus demselben Grund wie `geoScanQueryPlan`: Griffe die
    /// Abfrage doch nach `idx_grid_geo_scan`, bliebe das Ergebnis richtig und nur
    /// die Laufzeit stiege — lautlos. `TripIndexScanTests` weist den glatten
    /// Tabellendurchlauf nach.
    func tripScanQueryPlan() -> [String] {
        var plan: [String] = []
        readQueue.sync {
            guard let db = readDB else { return }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "EXPLAIN QUERY PLAN \(Self.tripScanSQL)", -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                plan.append(columnText(stmt, 3))
            }
        }
        return plan
    }

    // MARK: - Datums-Abgleich

    /// Die Projektion für den Datums-Abgleich.
    ///
    /// `NOT INDEXED` ist Pflicht, kein Zierrat: Ohne den Hinweis wählt SQLite
    /// `idx_grid_geo_scan`, weil dessen Prädikat (`exifCheckedAt IS NOT NULL`) von
    /// dieser `WHERE`-Bedingung impliziert wird. Das Ergebnis bliebe richtig, aber
    /// der Index deckt keine der sechs gelesenen Spalten ab — jede Zeile kostete
    /// einen Sprung in die Tabelle. Dieselbe Falle wie bei `dupeScanSQL`.
    ///
    /// `exifCheckedAt` wird mitgelesen statt in `WHERE` weggefiltert, weil die
    /// beiden Fälle auseinandergehalten werden müssen: „im Index, aber nie nach
    /// EXIF gefragt" ist eine Lücke, die der Nutzer über die EXIF-Reparatur
    /// schließen kann. „Gar nicht im Index" (Papierkorb, Archiv, ausgeblendet) ist
    /// keine. Ein gemeinsamer Filter machte aus beidem dasselbe.
    /// `latitude`/`longitude` dienen allein der Ortszeit-Prüfung: aus dem Längengrad
    /// wird der UTC-Versatz des Aufnahmeorts geschätzt, um zu sehen, ob ein
    /// vorgeschlagener Versatz Aufnahmen aus dem Tag in die Nacht schöbe.
    private static let dateScanSQL = """
        SELECT id, CAST(strftime('%s', fileCreatedAt) AS INTEGER),
               originalFileName, cameraMake, cameraModel, exifCheckedAt,
               latitude, longitude
        FROM grid_assets NOT INDEXED
        WHERE isTrashed = 0 AND isArchived = 0 AND isHidden = 0
    """

    /// Lädt alle sichtbaren Zeilen für den Datums-Abgleich.
    ///
    /// Liefert eine Zuordnung nach ID statt einer Liste: der Album-Gruppierer kennt
    /// die Mitgliedschaft als Menge von IDs und schlägt darin nach.
    ///
    /// - Returns: `nil`, wenn der Index nicht lesbar ist. Ein leeres Ergebnis heißt
    ///   dagegen „nichts Sichtbares" — zwei verschiedene Dinge, wie bei
    ///   `loadGeoScanRows`.
    func loadDateScanRows() -> DateIndexSnapshot? {
        var snapshot: DateIndexSnapshot?

        readQueue.sync {
            guard let db = readDB else { return }

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, Self.dateScanSQL, -1, &stmt, nil) == SQLITE_OK else {
                AppLogger.app.error("Datums-Scan: Abfrage konnte nicht vorbereitet werden: \(String(cString: sqlite3_errmsg(db)))")
                return
            }
            defer { sqlite3_finalize(stmt) }

            var rows: [String: DateScanRow] = [:]
            rows.reserveCapacity(100_000)
            var unknown: Set<String> = []

            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = columnText(stmt, 0)

                // Ohne exifCheckedAt ist die Kameraangabe nicht aussagekräftig — die
                // Zeile wird gezählt, nicht beurteilt.
                guard sqlite3_column_type(stmt, 5) != SQLITE_NULL else {
                    unknown.insert(id)
                    continue
                }
                // Unlesbare Zeitstempel ebenso: sie sind der Gegenstand des
                // Werkzeugs, aber ohne Zahl lässt sich nichts über sie sagen.
                guard sqlite3_column_type(stmt, 1) != SQLITE_NULL else {
                    unknown.insert(id)
                    continue
                }

                rows[id] = DateScanRow(
                    id: id,
                    timestamp: Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 1))),
                    originalFileName: columnText(stmt, 2),
                    cameraMake: columnOptionalText(stmt, 3),
                    cameraModel: columnOptionalText(stmt, 4),
                    latitude: columnOptionalDouble(stmt, 6),
                    longitude: columnOptionalDouble(stmt, 7)
                )
            }

            snapshot = DateIndexSnapshot(rowsById: rows, unknownExifIds: unknown)
        }

        return snapshot
    }

    /// Der Abfrageplan des Datums-Scans.
    ///
    /// Bewusst `internal`: `DateIndexScanTests` weist damit nach, dass der Scan
    /// tatsächlich über die Tabelle läuft. Eine stillschweigende Indexwahl bliebe
    /// sonst lautlos — die Ergebnisse blieben richtig, nur würde jeder Durchlauf um
    /// Größenordnungen langsamer.
    func dateScanQueryPlan() -> [String] {
        var plan: [String] = []
        readQueue.sync {
            guard let db = readDB else { return }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "EXPLAIN QUERY PLAN \(Self.dateScanSQL)", -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                plan.append(columnText(stmt, 3))
            }
        }
        return plan
    }

    // MARK: - Duplikatsuche

    /// Die Projektion der Duplikatsuche.
    ///
    /// Bewusst **kein** `ORDER BY`: Der Matcher sortiert ohnehin nach `(Zeit, ID)`,
    /// und ein `ORDER BY fileCreatedAt` über 155 000 Zeilen zwingt SQLite entweder
    /// zu einem eigenen Sortierschritt oder auf einen Index, der die übrigen
    /// Spalten nicht abdeckt. In Swift über `Int`-Zeitstempel zu sortieren ist
    /// billiger.
    ///
    /// Bewusst auch **kein** eigener partieller Index, anders als beim Geo-Scan:
    /// Dort deckte ein schmaler Index vier Spalten ab, hier werden fast alle
    /// gebraucht — ein deckender Index wäre eine zweite Kopie der Tabelle. Der
    /// gefilterte Tabellenscan ist für diese Abfrage der richtige Zugriff.
    ///
    /// `NOT INDEXED` ist deshalb kein Zierrat, sondern nötig: Nachgemessen wählt
    /// SQLite sonst `idx_grid_geo_scan`, weil dessen Prädikat von dieser
    /// `WHERE`-Bedingung impliziert wird. Das Ergebnis bliebe richtig, aber der
    /// Index deckt nur sieben der siebzehn Spalten ab — für alle übrigen fiele je
    /// Zeile ein Sprung in die Tabelle an, 155 000 Mal in zufälliger Reihenfolge.
    ///
    /// `exifCheckedAt IS NOT NULL` ist dieselbe tragende Bedingung wie beim
    /// Geo-Scan: Ohne sie kämen Assets in die Auswertung, nach deren EXIF nie
    /// gefragt wurde. Deren `fileSizeInByte`, `width` und `height` sind per
    /// Definition `NULL` — die Identitätsregel und die Keeper-Wahl liefen damit ins
    /// Leere, und zwar lautlos.
    private static let dupeScanSQL = """
        SELECT id, type, originalFileName, CAST(strftime('%s', fileCreatedAt) AS INTEGER),
               fileSizeInByte, width, height, thumbhash, duration, isFavorite,
               latitude, longitude, cameraMake, cameraModel, lensModel, city, country, checksum
        FROM grid_assets NOT INDEXED
        WHERE isTrashed = 0 AND isArchived = 0 AND isHidden = 0 AND exifCheckedAt IS NOT NULL
    """

    /// Wie viele der EXIF-Felder im Index belegt sind, die die Keeper-Wahl kennt.
    private static let dupeExifFieldCount = 8.0

    /// Lädt die Zeilen der Duplikatsuche.
    ///
    /// Der Thumbhash wird hier **einmal** aus Base64 dekodiert, nicht bei jedem
    /// Vergleich: Über 155 000 Zeilen entstehen im Matcher Millionen Vergleiche,
    /// und jeder würde denselben String erneut auspacken.
    ///
    /// - Returns: `nil`, wenn der Index nicht lesbar ist. Ein leeres `rows` heißt
    ///   dagegen „nichts Sichtbares" — zwei verschiedene Dinge, wie bei
    ///   `loadGeoScanRows`.
    func loadDupeScanRows() -> DupeIndexSnapshot? {
        var snapshot: DupeIndexSnapshot?

        readQueue.sync {
            guard let db = readDB else { return }

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, Self.dupeScanSQL, -1, &stmt, nil) == SQLITE_OK else {
                AppLogger.app.error("Duplikatsuche: Abfrage konnte nicht vorbereitet werden: \(String(cString: sqlite3_errmsg(db)))")
                return
            }
            defer { sqlite3_finalize(stmt) }

            var rows: [DupeScanRow] = []
            rows.reserveCapacity(100_000)
            var unparsable = 0
            var withoutThumbhash = 0
            var withoutSize = 0

            while sqlite3_step(stmt) == SQLITE_ROW {
                // Unlesbare Zeitstempel werden gezählt, nicht in SQL weggefiltert —
                // sonst fehlten sie später kommentarlos in jeder Bilanz.
                guard sqlite3_column_type(stmt, 3) != SQLITE_NULL else {
                    unparsable += 1
                    continue
                }

                let hashBytes = Self.decodeThumbhash(columnOptionalText(stmt, 7))
                if hashBytes == nil { withoutThumbhash += 1 }

                let size = columnOptionalInt(stmt, 4)
                let width = columnOptionalInt(stmt, 5)
                let height = columnOptionalInt(stmt, 6)
                if size == nil || width == nil || height == nil { withoutSize += 1 }

                let latitude = columnOptionalDouble(stmt, 10)
                let longitude = columnOptionalDouble(stmt, 11)

                var filled = 0.0
                if size != nil { filled += 1 }
                if width != nil { filled += 1 }
                if height != nil { filled += 1 }
                if latitude != nil, longitude != nil { filled += 1 }
                if columnOptionalText(stmt, 12) != nil { filled += 1 }   // cameraMake
                if columnOptionalText(stmt, 13) != nil { filled += 1 }   // cameraModel
                if columnOptionalText(stmt, 14) != nil { filled += 1 }   // lensModel
                if columnOptionalText(stmt, 15) != nil { filled += 1 }   // city

                rows.append(DupeScanRow(
                    id: columnText(stmt, 0),
                    type: AssetType(rawValue: columnText(stmt, 1)) ?? .image,
                    timestamp: Int(sqlite3_column_int64(stmt, 3)),
                    fileName: columnText(stmt, 2),
                    fileSize: size,
                    width: width,
                    height: height,
                    thumbhash: hashBytes,
                    durationMs: Self.durationMilliseconds(columnOptionalText(stmt, 8)),
                    isFavorite: sqlite3_column_int(stmt, 9) != 0,
                    hasCoordinates: latitude != nil && longitude != nil,
                    exifCompleteness: filled / Self.dupeExifFieldCount,
                    checksum: columnOptionalText(stmt, 17)
                ))
            }

            snapshot = DupeIndexSnapshot(
                rows: rows,
                rowsWithoutThumbhash: withoutThumbhash,
                rowsWithoutSize: withoutSize,
                unparsableTimestampCount: unparsable
            )
        }

        return snapshot
    }

    /// Der Abfrageplan der Duplikatsuche.
    ///
    /// Bewusst `internal`, aus demselben Grund wie `geoScanQueryPlan`: Die Tests
    /// weisen damit nach, dass die Abfrage tatsächlich über den gefilterten
    /// Tabellenscan läuft und nicht versehentlich auf einen unpassenden Index
    /// fällt, der Zeilen ausließe.
    func dupeScanQueryPlan() -> [String] {
        var plan: [String] = []
        readQueue.sync {
            guard let db = readDB else { return }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "EXPLAIN QUERY PLAN \(Self.dupeScanSQL)", -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                plan.append(columnText(stmt, 3))
            }
        }
        return plan
    }

    /// Base64 → Bytes. `nil`, sobald der Wert fehlt oder sich nicht lesen lässt —
    /// für solche Zeilen greifen im Matcher nur die exakten Regeln.
    static func decodeThumbhash(_ base64: String?) -> [UInt8]? {
        guard let base64, !base64.isEmpty,
              let data = Data(base64Encoded: base64), !data.isEmpty
        else { return nil }
        return [UInt8](data)
    }

    /// `"HH:MM:SS.mmm"` → Millisekunden. Immich liefert die Laufzeit als Text.
    static func durationMilliseconds(_ text: String?) -> Int? {
        guard let text, !text.isEmpty else { return nil }
        let parts = text.split(separator: ":")
        guard parts.count == 3,
              let hours = Int(parts[0]),
              let minutes = Int(parts[1]),
              let seconds = Double(parts[2]),
              // `Double("nan")`, `Double("inf")` und `Double("1e30")` parsen
              // alle erfolgreich, die Umwandlung nach `Int` unten bricht auf
              // ihnen mit SIGTRAP ab.
              seconds.isFinite, seconds >= 0, hours >= 0, minutes >= 0
        else { return nil }
        let milliseconds = (Double(hours) * 3600 + Double(minutes) * 60 + seconds) * 1000
        // Auch die Stundenstelle kann überlaufen: `Int(parts[0])` nimmt
        // `Int.max` klaglos an, mal 3 600 000 liegt das weit jenseits von
        // `Int`. Hier steht bewusst keine inhaltliche Obergrenze wie die
        // 86 400 s auf der Sekundenstelle — dieser Wert wandert in den Index,
        // nicht auf den Bildschirm, und soll nicht beschnitten werden.
        guard milliseconds < Double(Int.max) else { return nil }
        return Int(milliseconds.rounded())
    }

    /// Setzt oder löscht die Koordinaten der übergebenen Assets.
    ///
    /// Bewusst **ohne** den `latitude IS NULL`-Schutz aus `writeExifV8`: Dieser Schreibvorgang
    /// spiegelt eine bereits erfolgreiche Server-Antwort, ist also autoritativ — und das
    /// Rückgängigmachen muss die eben gesetzten Werte überschreiben können.
    ///
    /// Rührt `exifCheckedAt` nicht an: Der Prüfvermerk ist eine Aussage darüber, ob der
    /// Server gefragt wurde, nicht darüber, was in den Spalten steht.
    ///
    /// - Returns: `false`, sobald ein Schritt fehlschlägt — der Aufrufer soll das
    ///   protokollieren statt Erfolg anzunehmen.
    @discardableResult
    func updateLocation(ids: [String], latitude: Double?, longitude: Double?) -> Bool {
        guard !ids.isEmpty else { return true }

        var success = false
        writeQueue.sync {
            guard let db else { return }
            guard exec("BEGIN TRANSACTION") == SQLITE_OK else {
                AppLogger.app.error("GPS-Schreiben: BEGIN fehlgeschlagen: \(String(cString: sqlite3_errmsg(db)))")
                return
            }

            var offset = 0
            while offset < ids.count {
                let chunk = Array(ids[offset..<min(offset + 900, ids.count)])
                offset += chunk.count

                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                let sql = "UPDATE grid_assets SET latitude = ?, longitude = ? WHERE id IN (\(placeholders))"

                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                    AppLogger.app.error("GPS-Schreiben: UPDATE konnte nicht vorbereitet werden: \(String(cString: sqlite3_errmsg(db)))")
                    exec("ROLLBACK")
                    return
                }
                defer { sqlite3_finalize(stmt) }

                bindOptionalDouble(stmt, 1, latitude)
                bindOptionalDouble(stmt, 2, longitude)
                for (index, id) in chunk.enumerated() {
                    bindText(stmt, Int32(index + 3), id)
                }

                let stepResult = sqlite3_step(stmt)
                guard stepResult == SQLITE_DONE else {
                    AppLogger.app.error("GPS-Schreiben: UPDATE-step fehlgeschlagen (code=\(stepResult)): \(String(cString: sqlite3_errmsg(db)))")
                    exec("ROLLBACK")
                    return
                }
            }

            guard exec("COMMIT") == SQLITE_OK else {
                AppLogger.app.error("GPS-Schreiben: COMMIT fehlgeschlagen: \(String(cString: sqlite3_errmsg(db)))")
                exec("ROLLBACK")
                return
            }
            success = true
        }
        return success
    }

    /// Wie `updateLocation(ids:latitude:longitude:)`, aber mit **eigener** Koordinate je
    /// Asset — der Paar-Modus interpoliert für jede Waise einen anderen Punkt.
    ///
    /// Alles in einer Transaktion: bei mehreren hundert Vorschlägen wären Einzelaufrufe
    /// ebenso viele `BEGIN`/`COMMIT`-Paare.
    @discardableResult
    func updateLocations(_ entries: [(id: String, latitude: Double?, longitude: Double?)]) -> Bool {
        guard !entries.isEmpty else { return true }

        var success = false
        writeQueue.sync {
            guard let db else { return }
            guard exec("BEGIN TRANSACTION") == SQLITE_OK else {
                AppLogger.app.error("GPS-Schreiben: BEGIN fehlgeschlagen: \(String(cString: sqlite3_errmsg(db)))")
                return
            }

            let sql = "UPDATE grid_assets SET latitude = ?, longitude = ? WHERE id = ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                AppLogger.app.error("GPS-Schreiben: UPDATE konnte nicht vorbereitet werden: \(String(cString: sqlite3_errmsg(db)))")
                exec("ROLLBACK")
                return
            }
            defer { sqlite3_finalize(stmt) }

            for entry in entries {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                bindOptionalDouble(stmt, 1, entry.latitude)
                bindOptionalDouble(stmt, 2, entry.longitude)
                bindText(stmt, 3, entry.id)

                let stepResult = sqlite3_step(stmt)
                guard stepResult == SQLITE_DONE else {
                    AppLogger.app.error("GPS-Schreiben: UPDATE-step fehlgeschlagen (code=\(stepResult)): \(String(cString: sqlite3_errmsg(db)))")
                    exec("ROLLBACK")
                    return
                }
            }

            guard exec("COMMIT") == SQLITE_OK else {
                AppLogger.app.error("GPS-Schreiben: COMMIT fehlgeschlagen: \(String(cString: sqlite3_errmsg(db)))")
                exec("ROLLBACK")
                return
            }
            success = true
        }
        return success
    }

    /// Load panorama assets directly from SQLite using aspect ratio filtering.
    /// Panoramas are defined as images with width/height >= 2.0.
    /// Much faster than a full SwiftData scan — no ORM overhead.
    /// Note: assets synced via SyncAsset (no EXIF) may have NULL width/height
    /// and won't appear here; they are caught by the SwiftData fallback.
    func loadPanoramas() -> [Asset] {
        var result: [Asset] = []
        readQueue.sync {
            guard let db = readDB else { return }

            // A true panorama must pass the aspect-ratio test (≥2:1) AND at least one
            // "real camera" signal to weed out screenshots that happen to share the ratio:
            //
            //  • lensModel IS NOT NULL  → EXIF from a real camera lens (iPhone, DSLR, …)
            //  • width >= 4000          → raw resolution typical of stitched panoramas
            //
            // Additionally, filename patterns that are dead giveaways for screenshots are
            // excluded regardless of dimensions.
            //
            // Die Namen kommen aus `ScreenshotDetector.filenameMarkers` — hier stand eine
            // eigene Liste aus fünf Mustern, und der fehlte „bildschirmfoto". Auf einem
            // deutschen System heißen Bildschirmfotos genau so, und ein breites
            // (Ultrawide, 5K → über 4000 px) landete damit in „Panoramen".
            //
            // `screen-%` bleibt zusätzlich stehen: Das ist ein reines Präfixmuster ohne
            // Entsprechung im Detektor — dort würde ein unverankertes „screen-" auch
            // „Familie_am_Screen-Abend.jpg" treffen.
            let sql = """
                SELECT \(Self.selectColumns)
                FROM grid_assets
                WHERE isTrashed = 0 AND isArchived = 0 AND isHidden = 0
                  AND width IS NOT NULL AND height IS NOT NULL AND height > 0
                  AND (CAST(width AS REAL) / CAST(height AS REAL)) >= 2.0
                  AND (lensModel IS NOT NULL OR width >= 4000)
                  \(ScreenshotDetector.screenshotNameExclusionSQL)
                  AND originalFileName NOT LIKE 'screen-%' COLLATE NOCASE
                ORDER BY fileCreatedAt DESC
            """

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }

            result.reserveCapacity(500)
            while sqlite3_step(stmt) == SQLITE_ROW {
                result.append(assetFromRow(stmt))
            }
        }
        return result
    }



    /// Delete the entire grid index (for full re-sync).

    func deleteAll() {
        writeQueue.sync {
            guard db != nil else { return }
            exec("DELETE FROM grid_assets")
        }
    }

    // `populateFromSwiftData(modelContext:)` stand hier: eine „einmalige Migration",
    // die seit ihrem Einführungs-Commit (4b5095d) nie aufgerufen wurde. Gefüllt wird
    // der Index tatsächlich über `upsertFromCache` aus `AssetRepository` und über die
    // Sync-Upserts.
    //
    // Entfernt, weil ihr Wächter `guard existingCount == 0 else { return } // Already
    // populated` beim Lesen eine Zusicherung suggeriert, die es nicht gibt — „Index
    // nicht leer" hieße dort „Index vollständig". Beim Durchsehen der Schreibpfade
    // habe ich genau daraus beinahe einen Fehlerbefund abgeleitet, bevor auffiel, dass
    // die Funktion tot ist.

    // MARK: - Helpers

    /// Execute a statement on the write connection (must be called from writeQueue).
    ///
    /// `@discardableResult`, weil fast alle Aufrufer den Rückgabewert bewusst ignorieren
    /// (siehe Klassenkommentar zur Fehlerkonvention). `writeExifV8` und
    /// `clearExifChecked` sind die einzigen beiden Stellen, die ihn prüfen — kleinerer
    /// Eingriff als eine separate geprüfte Exec-Variante nur für diese zwei Aufrufer.
    @discardableResult
    private func exec(_ sql: String) -> Int32 {
        sqlite3_exec(writeDB, sql, nil, nil, nil)
    }

    /// Execute a statement on an explicit connection handle.
    private func execOn(_ conn: OpaquePointer?, _ sql: String) {
        sqlite3_exec(conn, sql, nil, nil, nil)
    }

    private func columnText(_ stmt: OpaquePointer?, _ col: Int32) -> String {
        if let cStr = sqlite3_column_text(stmt, col) {
            return String(cString: cStr)
        }
        return ""
    }

    private func columnOptionalText(_ stmt: OpaquePointer?, _ col: Int32) -> String? {
        if sqlite3_column_type(stmt, col) == SQLITE_NULL { return nil }
        if let cStr = sqlite3_column_text(stmt, col) {
            return String(cString: cStr)
        }
        return nil
    }

    private func columnOptionalInt(_ stmt: OpaquePointer?, _ col: Int32) -> Int? {
        if sqlite3_column_type(stmt, col) == SQLITE_NULL { return nil }
        return Int(sqlite3_column_int64(stmt, col))
    }

    private func columnOptionalDouble(_ stmt: OpaquePointer?, _ col: Int32) -> Double? {
        if sqlite3_column_type(stmt, col) == SQLITE_NULL { return nil }
        return sqlite3_column_double(stmt, col)
    }

    private func bindText(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String) {
        _ = value.withCString { cStr in
            sqlite3_bind_text(stmt, idx, cStr, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
    }

    private func bindOptionalText(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String?) {
        if let value {
            bindText(stmt, idx, value)
        } else {
            sqlite3_bind_null(stmt, idx)
        }
    }

    private func bindOptionalInt(_ stmt: OpaquePointer?, _ idx: Int32, _ value: Int?) {
        if let value {
            sqlite3_bind_int64(stmt, idx, Int64(value))
        } else {
            sqlite3_bind_null(stmt, idx)
        }
    }

    /// `REAL`-Binder für die v8-Spalten `latitude`/`longitude`. Genutzt von `upsert`,
    /// `upsertFromCache` und dem einmaligen `backfillExifV8`.
    private func bindOptionalDouble(_ stmt: OpaquePointer?, _ idx: Int32, _ value: Double?) {
        if let value {
            sqlite3_bind_double(stmt, idx, value)
        } else {
            sqlite3_bind_null(stmt, idx)
        }
    }

    private func assetFromRow(_ stmt: OpaquePointer?) -> Asset {
        let lensModel    = columnOptionalText(stmt, 13)
        let cameraModel  = columnOptionalText(stmt, 14)
        let city         = columnOptionalText(stmt, 15)
        let country      = columnOptionalText(stmt, 16)
        return Asset(
            id: columnText(stmt, 0),
            type: AssetType(rawValue: columnText(stmt, 1)) ?? .other,
            originalFileName: columnText(stmt, 11),
            fileCreatedAt: columnText(stmt, 2),
            fileModifiedAt: columnText(stmt, 12),
            isFavorite: sqlite3_column_int(stmt, 3) != 0,
            isArchived: sqlite3_column_int(stmt, 4) != 0,
            duration: columnOptionalText(stmt, 7),
            thumbhash: columnOptionalText(stmt, 8),
            isTrashed: sqlite3_column_int(stmt, 5) != 0,
            exifInfo: ExifInfo(
                make: columnOptionalText(stmt, 20), model: cameraModel,
                exifImageWidth: columnOptionalInt(stmt, 9),
                exifImageHeight: columnOptionalInt(stmt, 10),
                fileSizeInByte: columnOptionalInt(stmt, 21),
                city: city, state: nil, country: country,
                latitude: columnOptionalDouble(stmt, 18),
                longitude: columnOptionalDouble(stmt, 19),
                focalLength: nil, fNumber: nil, iso: nil, exposureTime: nil,
                lensModel: lensModel
            ),
            width: columnOptionalInt(stmt, 9),
            height: columnOptionalInt(stmt, 10),
            livePhotoVideoId: columnOptionalText(stmt, 17)
        )
    }
}
