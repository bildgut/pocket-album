import Foundation

/// Lokale Sicherungskopien von `ImmichMac.store` und `grid_index.sqlite` im
/// Support-Verzeichnis — auflisten, messen, ausdünnen.
///
/// Vor jedem Store-Reset legt ``StoreBackupService`` eine Kopie an, räumte aber nie
/// eine weg. Dazu kommen Handkopien aus Migrationen (`ImmichMac.store.pre-v7-backup`,
/// `.resynced-partial`, `grid_index.backup-…`). Im September 2026 lagen so 14 Kopien
/// mit 1,2 GB neben einem 270-MB-Store.
///
/// Erkannt wird am Namen: alles, was mit `ImmichMac.store.` (Punkt!) oder
/// `grid_index.backup` beginnt. Der Punkt trennt die Kopien von den lebenden
/// Begleitdateien `ImmichMac.store-wal`/`-shm`.
enum LocalStoreBackups {

    struct Eintrag: Equatable {
        let url: URL
        let bytes: Int64
        let datum: Date
    }

    static func istBackup(name: String) -> Bool {
        name.hasPrefix("ImmichMac.store.") || name.hasPrefix("grid_index.backup")
    }

    /// Alle Sicherungskopien, jüngste zuerst.
    static func liste(in dir: URL = AppEnvironment.supportDirectory) -> [Eintrag] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let inhalt = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) else {
            return []
        }
        return inhalt
            .filter { istBackup(name: $0.lastPathComponent) }
            .map { url in
                let datum = (try? url.resourceValues(forKeys: Set(keys)))?.contentModificationDate ?? .distantPast
                return Eintrag(url: url, bytes: groesse(von: url), datum: datum)
            }
            .sorted { $0.datum > $1.datum }
    }

    /// Löscht alle Kopien bis auf die `behalte` jüngsten.
    /// - Returns: Anzahl und Bytes der gelöschten Kopien.
    @discardableResult
    static func ausduennen(in dir: URL = AppEnvironment.supportDirectory, behalte: Int) -> (anzahl: Int, bytes: Int64) {
        var anzahl = 0
        var bytes: Int64 = 0
        for eintrag in liste(in: dir).dropFirst(max(0, behalte)) {
            if (try? FileManager.default.removeItem(at: eintrag.url)) != nil {
                anzahl += 1
                bytes += eintrag.bytes
            }
        }
        if anzahl > 0 {
            AppLogger.app.info("LocalStoreBackups: \(anzahl) alte Sicherungskopien gelöscht (\(bytes) Bytes)")
        }
        return (anzahl, bytes)
    }

    /// Summe der lebenden Datenbanken samt WAL/SHM — ohne Sicherungskopien.
    static func datenbankBytes(in dir: URL = AppEnvironment.supportDirectory) -> Int64 {
        let fm = FileManager.default
        guard let inhalt = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return 0 }
        return inhalt
            .filter { url in
                let name = url.lastPathComponent
                guard !istBackup(name: name) else { return false }
                return name.hasPrefix("ImmichMac.store") || name.hasSuffix(".sqlite")
                    || name.hasSuffix(".sqlite-wal") || name.hasSuffix(".sqlite-shm")
            }
            .reduce(0) { $0 + groesse(von: $1) }
    }

    /// Größe einer Datei oder — rekursiv — eines Verzeichnisses (Store-Kopien sind Bündel).
    static func groesse(von url: URL) -> Int64 {
        let fm = FileManager.default
        var istVerzeichnis: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &istVerzeichnis) else { return 0 }
        guard istVerzeichnis.boolValue else {
            return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        guard let e = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var summe: Int64 = 0
        for case let datei as URL in e {
            summe += Int64((try? datei.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return summe
    }
}
