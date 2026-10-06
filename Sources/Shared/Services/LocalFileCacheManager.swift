import Foundation
import SwiftData
import os

/// Manages local caching of original asset files.
/// Files are stored under ~/Library/Application Support/ImmichMac/OriginalCache/YYYY-MM/assetId.ext
actor LocalFileCacheManager {

    // MARK: - Singleton

    static let shared = LocalFileCacheManager()

    /// Obergrenze je Datei für das Zeitfenster (`cacheDays`). Offline gepinnte Alben
    /// umgehen sie wie die Längengrenze — dort hat der Nutzer ausdrücklich gewählt.
    static let maxWindowFileBytes: Int64 = 500 * 1024 * 1024

    // MARK: - Cache Directory

    static let cacheDirectory: URL = legeCacheVerzeichnisAn(
        AppEnvironment.supportDirectory.appending(path: "OriginalCache", directoryHint: .isDirectory)
    )

    /// Legt das Verzeichnis an und nimmt es aus dem iCloud-/iTunes-Backup.
    ///
    /// Die Offline-Originale liegen unter Application Support (nicht Caches), damit
    /// iOS sie bei Platzmangel nicht still räumt — Application Support geht aber
    /// standardmäßig ins Backup. Gigabyte an Fotos, die ohnehin auf dem Server liegen,
    /// hätten dort das iCloud-Kontingent gefressen. Das Flag am Verzeichnis gilt für
    /// seinen ganzen Inhalt. Am Mac wirkt es auf Time Machine nicht, ist aber harmlos.
    @discardableResult
    nonisolated static func legeCacheVerzeichnisAn(_ dir: URL) -> URL {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var werte = URLResourceValues()
        werte.isExcludedFromBackup = true
        var ziel = dir
        do {
            try ziel.setResourceValues(werte)
        } catch {
            AppLogger.cache.error("OriginalCache nicht aus dem Backup genommen: \(error)")
        }
        return dir
    }

    // MARK: - Download (contextfrei)

    /// Lädt das Original eines Assets in den Cache und liefert den **relativen** Pfad
    /// (`YYYY-MM/assetId.ext`) zurück. Berührt SwiftData nicht.
    ///
    /// Bewusst `nonisolated static`: Der ``OfflineDownloadManager`` lädt mehrere Dateien
    /// gleichzeitig. Läge die Funktion auf dem Actor, serialisierte der Actor sie wieder
    /// — und genau die Serialisierung soll weg. Ohne SwiftData-Objekte im Spiel ist der
    /// Aufruf auch nebenläufig unbedenklich: Jeder Lauf schreibt unter seinem eigenen
    /// Asset-Namen.
    nonisolated static func downloadOriginalToCache(
        assetId: String,
        monthKey: String,
        apiClient: ImmichAPIClient
    ) async throws -> String {
        let dirURL = cacheDirectory.appending(path: monthKey, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

        // Erst unter .tmp streamen (kein Puffern im Speicher), dann auf die echte
        // Endung umbenennen — die steht erst in der Content-Disposition der Antwort.
        let tempDest = dirURL.appending(path: "\(assetId).tmp")
        let filename: String
        do {
            filename = try await apiClient.downloadOriginalToFile(
                assetId: assetId,
                destinationURL: tempDest
            )
        } catch {
            // Ein abgebrochener Download ließ seine .tmp sonst für immer liegen — bis
            // September 2026 hatten sich so 1 774 Dateien mit 15 GB angesammelt.
            try? FileManager.default.removeItem(at: tempDest)
            throw error
        }

        let fileExt = (filename as NSString).pathExtension
        let finalName = fileExt.isEmpty ? assetId : "\(assetId).\(fileExt)"
        let finalURL = dirURL.appending(path: finalName)
        if tempDest.path != finalURL.path {
            // moveItem überschreibt nicht. Liegt am Ziel noch eine Datei — etwa weil ein
            // Store-Reset die localFilePath-Referenzen verloren hat, die Dateien im
            // OriginalCache aber überlebt haben — schlüge der Move sonst fehl.
            try? FileManager.default.removeItem(at: finalURL)
            try FileManager.default.moveItem(at: tempDest, to: finalURL)
        }

        return "\(monthKey)/\(finalName)"
    }

    /// Lädt die gewünschte Fassung in den Offline-Speicher. Das Original geht den
    /// bisherigen Weg (`downloadOriginalToCache`), damit der Mac-Pfad Byte für Byte
    /// gleich bleibt. Die Fassung steht im Dateinamen, siehe ``OfflineFassung``.
    ///
    /// Transkodiert der Server ein Video nicht, liefert `video/playback` das Original —
    /// die Datei heißt trotzdem `.klein.mp4`: abspielbar, nur größer als geschätzt.
    nonisolated static func downloadToCache(
        assetId: String,
        monthKey: String,
        fassung: OfflineFassung,
        apiClient: ImmichAPIClient
    ) async throws -> String {
        if fassung == .original {
            return try await downloadOriginalToCache(assetId: assetId, monthKey: monthKey, apiClient: apiClient)
        }
        let dirURL = cacheDirectory.appending(path: monthKey, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

        let tempDest = dirURL.appending(path: "\(assetId).\(fassung.rawValue).tmp")
        let quelle = fassung == .vorschau
            ? apiClient.thumbnailURL(assetId: assetId, size: .preview)
            : apiClient.playbackURL(assetId: assetId)
        let contentType: String?
        do {
            contentType = try await apiClient.downloadToFile(url: quelle, destinationURL: tempDest)
        } catch {
            try? FileManager.default.removeItem(at: tempDest)
            throw error
        }

        let endung = fassung == .klein ? "mp4" : OfflineFassung.endung(contentType: contentType)
        let finalName = fassung.dateiname(assetId: assetId, endung: endung)
        let finalURL = dirURL.appending(path: finalName)
        try? FileManager.default.removeItem(at: finalURL)
        try FileManager.default.moveItem(at: tempDest, to: finalURL)
        return "\(monthKey)/\(finalName)"
    }

    // MARK: - Public API

    /// Download the original file for an asset if it's within the cache window and not yet cached.
    ///
    /// Nimmt die **assetId**, nicht das `CachedAsset`, und den `ModelContainer`, nicht
    /// den `ModelContext`. Beides aus demselben Grund wie bei ``localFileURL(forPath:)``:
    /// Ein SwiftData-`@Model` ist nicht `Sendable`, und ein `ModelContext` ist nicht
    /// threadsicher — beides von außen hereinzureichen und **hier drinnen** zu lesen, zu
    /// schreiben und zu sichern war ein Zugriff auf einen fremden Kontext von einem
    /// anderen Executor aus. `SWIFT_VERSION: "5"` verdeckt das beim Übersetzen; im
    /// Swift-6-Modus ist es ein Fehler.
    ///
    /// Der Kontext entsteht deshalb **im Aktor**, genau wie in ``downloadPendingAssets``.
    /// Folge fürs Verhalten: Der Pfad wird jetzt in einem Hintergrundkontext gesichert
    /// statt im Kontext des Aufrufers — dieselbe Lage wie beim Hintergrunddurchlauf nach
    /// dem Sync, den es längst gibt.
    /// - Parameters:
    ///   - assetId: Die ID des Assets, das geladen werden soll.
    ///   - container: Der Store; der Kontext dazu entsteht hier drinnen.
    ///   - apiClient: The API client for fetching the file.
    ///   - cacheDays: Number of days to cache (0 = disabled).
    func downloadIfNeeded(
        assetId: String,
        container: ModelContainer,
        apiClient: ImmichAPIClient,
        cacheDays: Int,
        forceBypassWindow: Bool = false
    ) async {
        // Vor dem Kontext geprüft: Ist der Cache aus, soll auch kein Fetch laufen.
        guard forceBypassWindow || cacheDays > 0 else { return }

        let bgContext = ModelContext(container)
        bgContext.autosaveEnabled = false

        var descriptor = FetchDescriptor<CachedAsset>(
            predicate: #Predicate<CachedAsset> { $0.assetId == assetId }
        )
        descriptor.fetchLimit = 1
        guard let asset = try? bgContext.fetch(descriptor).first else { return }

        await downloadIfNeeded(
            asset: asset,
            apiClient: apiClient,
            modelContext: bgContext,
            cacheDays: cacheDays,
            forceBypassWindow: forceBypassWindow
        )
    }

    /// Der eigentliche Ablauf. `private`, weil `asset` und `modelContext` beide aus einem
    /// **im Aktor** angelegten Kontext stammen müssen — von außen ist das nicht zu
    /// garantieren, und genau daran hing das Datenrennen.
    private func downloadIfNeeded(
        asset: CachedAsset,
        apiClient: ImmichAPIClient,
        modelContext: ModelContext,
        cacheDays: Int,
        forceBypassWindow: Bool
    ) async {
        guard forceBypassWindow || cacheDays > 0 else { return }
        guard asset.localFilePath == nil else { return }  // Already cached
        guard forceBypassWindow || isWithinWindow(asset: asset, cacheDays: cacheDays) else { return }
        // Skip videos longer than 5 minutes by default, unless forced
        if !forceBypassWindow && asset.isVideo, let durationStr = asset.duration, let durationSecs = parseDurationSeconds(durationStr), durationSecs > 300 {
            AppLogger.cache.debug("LocalFileCacheManager: skipping long video \(asset.assetId) (\(durationSecs)s)")
            return
        }
        // Ebenso sehr große Dateien: Ein einzelnes Video belegte fast 2 GB. Die Länge
        // allein fängt das nicht — ein 4K-Video mit 4 Minuten liegt schon darüber.
        if !forceBypassWindow, let bytes = asset.fileSizeInByte, Int64(bytes) > Self.maxWindowFileBytes {
            AppLogger.cache.debug("LocalFileCacheManager: skipping large file \(asset.assetId) (\(bytes) bytes)")
            return
        }

        AppLogger.cache.debug("LocalFileCacheManager: downloading \(asset.assetId)")

        do {
            // Scheitert der Download oder das Umbenennen, darf kein localFilePath gesetzt
            // werden: der Guard oben würde ihn sonst nie wiederholen.
            let relativePath = try await Self.downloadOriginalToCache(
                assetId: asset.assetId,
                monthKey: asset.monthKey,
                apiClient: apiClient
            )

            // Persist relative path in SwiftData
            asset.localFilePath = relativePath
            try? modelContext.save()

            AppLogger.cache.info("LocalFileCacheManager: cached \(asset.assetId) → \(relativePath)")
        } catch {
            AppLogger.cache.error("LocalFileCacheManager: download failed for \(asset.assetId): \(error)")
        }
    }

    /// Download all pending assets within the cache window (background pass after sync).
    func downloadPendingAssets(
        container: ModelContainer,
        apiClient: ImmichAPIClient,
        cacheDays: Int
    ) async {
        guard cacheDays > 0 else { return }

        let bgContext = ModelContext(container)
        bgContext.autosaveEnabled = false

        let cutoff = Calendar.current.date(byAdding: .day, value: -cacheDays, to: Date()) ?? Date()
        let cutoffStr = ISO8601DateFormatter().string(from: cutoff)

        let descriptor = FetchDescriptor<CachedAsset>(
            predicate: #Predicate<CachedAsset> {
                $0.isTrashed == false &&
                $0.localFilePath == nil &&
                $0.fileCreatedAt >= cutoffStr
            },
            sortBy: [SortDescriptor(\.fileCreatedAt, order: .reverse)]
        )

        guard let pending = try? bgContext.fetch(descriptor), !pending.isEmpty else { return }

        AppLogger.cache.info("LocalFileCacheManager: \(pending.count) assets to download in background")

        for asset in pending {
            guard !Task.isCancelled else { break }
            await downloadIfNeeded(asset: asset, apiClient: apiClient, modelContext: bgContext,
                                   cacheDays: cacheDays, forceBypassWindow: false)
            // Small pause between downloads to stay low-priority
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Evict files for given asset IDs and clear `localFilePath` in SwiftData.
    func evict(ids: [String], container: ModelContainer) async {
        guard !ids.isEmpty else { return }
        let bgContext = ModelContext(container)
        bgContext.autosaveEnabled = false

        for id in ids {
            // Find and delete file on disk
            removeFileForAssetId(id)

            // Clear localFilePath in SwiftData
            let predicate = #Predicate<CachedAsset> { $0.assetId == id }
            var descriptor = FetchDescriptor(predicate: predicate)
            descriptor.fetchLimit = 1
            if let cached = try? bgContext.fetch(descriptor).first {
                cached.localFilePath = nil
            }
        }
        try? bgContext.save()
        AppLogger.cache.info("LocalFileCacheManager: evicted \(ids.count) assets")
    }

    /// Remove files for all expired or trashed assets (safety net, runs after every sync).
    func evictExpired(container: ModelContainer, cacheDays: Int) async {
        Self.removeStaleTempFiles()

        let bgContext = ModelContext(container)
        bgContext.autosaveEnabled = false

        let cutoff = Calendar.current.date(byAdding: .day, value: -cacheDays, to: Date()) ?? Date()
        let cutoffStr = ISO8601DateFormatter().string(from: cutoff)

        // Alle Asset-IDs, die ein Offline-Vermerk hält — Alben und Smart Alben gemeinsam.
        // Sie dürfen nie weggeräumt werden, auch nicht außerhalb des Zeitfensters, sonst
        // lüde der OfflineDownloadManager sie in jedem 15-Minuten-Zyklus neu.
        let pinnedAssetIds = OfflinePinStore.allPinnedAssetIds(in: bgContext)

        // Evict trashed assets with local files (offline-pinned assets are NOT trashed,
        // so this loop is safe — but guard anyway for correctness).
        let trashedDescriptor = FetchDescriptor<CachedAsset>(
            predicate: #Predicate<CachedAsset> { $0.isTrashed == true && $0.localFilePath != nil }
        )
        if let trashed = try? bgContext.fetch(trashedDescriptor) {
            for asset in trashed {
                guard !pinnedAssetIds.contains(asset.assetId) else { continue }
                if let path = asset.localFilePath {
                    let fileURL = Self.cacheDirectory.appending(path: path)
                    try? FileManager.default.removeItem(at: fileURL)
                    asset.localFilePath = nil
                }
            }
        }

        // Evict assets older than the cache window — but never offline-pinned assets.
        if cacheDays > 0 {
            let expiredDescriptor = FetchDescriptor<CachedAsset>(
                predicate: #Predicate<CachedAsset> { $0.localFilePath != nil && $0.fileCreatedAt < cutoffStr }
            )
            if let expired = try? bgContext.fetch(expiredDescriptor) {
                var evictedCount = 0
                for asset in expired {
                    // Skip assets that belong to an offline album — they must stay on disk.
                    guard !pinnedAssetIds.contains(asset.assetId) else { continue }
                    if let path = asset.localFilePath {
                        let fileURL = Self.cacheDirectory.appending(path: path)
                        try? FileManager.default.removeItem(at: fileURL)
                        asset.localFilePath = nil
                        evictedCount += 1
                    }
                }
                if evictedCount > 0 {
                    AppLogger.cache.info("LocalFileCacheManager: evicted \(evictedCount) expired assets (\(expired.count - evictedCount) offline-pinned assets kept)")
                }
            }
        }

        try? bgContext.save()
        // Clean up empty month directories
        cleanEmptyDirectories()
    }

    /// Löscht Originale, die kein Offline-Vermerk mehr hält und die außerhalb des
    /// Zeitfensters liegen.
    ///
    /// Das ist der Weg, den das Entpinnen geht. Vorher setzte das Abschalten nur ein Flag
    /// und ließ die Dateien liegen — bei einem Album mit ein paar tausend Fotos also
    /// zweistellige Gigabyte, obwohl die Oberfläche „Fotos werden nicht mehr lokal
    /// vorgehalten" versprach.
    ///
    /// Das Zeitfenster bleibt maßgeblich: Ein entpinntes Album, dessen Fotos von letzter
    /// Woche sind, behält sie — dafür sorgt der normale Fenster-Cache, und ein Löschen
    /// wäre nur ein späteres Neuladen.
    /// - Returns: Anzahl der gelöschten Dateien.
    @discardableResult
    func evictUnpinned(container: ModelContainer, cacheDays: Int) async -> Int {
        let bgContext = ModelContext(container)
        bgContext.autosaveEnabled = false

        let pinnedAssetIds = OfflinePinStore.allPinnedAssetIds(in: bgContext)

        let descriptor = FetchDescriptor<CachedAsset>(
            predicate: #Predicate<CachedAsset> { $0.localFilePath != nil }
        )
        guard let cached = try? bgContext.fetch(descriptor) else { return 0 }

        var evicted = 0
        for asset in cached {
            guard !pinnedAssetIds.contains(asset.assetId) else { continue }
            guard !isWithinWindow(asset: asset, cacheDays: cacheDays) else { continue }
            if let path = asset.localFilePath {
                try? FileManager.default.removeItem(at: Self.cacheDirectory.appending(path: path))
                asset.localFilePath = nil
                evicted += 1
            }
        }

        if evicted > 0 {
            try? bgContext.save()
            cleanEmptyDirectories()
            AppLogger.cache.info("LocalFileCacheManager: \(evicted) nicht mehr gepinnte Originale gelöscht")
        }
        return evicted
    }

    /// Belegter Platz und Vollständigkeit eines Offline-Vermerks.
    ///
    /// Läuft über einen eigenen Hintergrund-Context, damit die Einstellungen die Zahlen
    /// nicht im View-Body berechnen.
    nonisolated static func status(
        forAssetIds ids: [String],
        container: ModelContainer
    ) -> (present: Int, expected: Int, bytes: Int64) {
        guard !ids.isEmpty else { return (0, 0, 0) }
        let context = ModelContext(container)
        let idSet = Set(ids)

        var present = 0
        var bytes: Int64 = 0
        // Ein Fetch über alle mit Datei, danach lokal filtern: `#Predicate` kann keine
        // Set-Mitgliedschaft über tausende IDs, und pro ID einzeln zu fetchen wären bei
        // einem großen Album ein paar tausend Abfragen.
        let descriptor = FetchDescriptor<CachedAsset>(
            predicate: #Predicate<CachedAsset> { $0.localFilePath != nil }
        )
        for asset in (try? context.fetch(descriptor)) ?? [] where idSet.contains(asset.assetId) {
            present += 1
            bytes += Int64(asset.fileSizeInByte ?? 0)
        }
        return (present, ids.count, bytes)
    }

    /// Wie ``status(forAssetIds:container:)``, aber mit den **Bytes auf dem Gerät**
    /// (Dateigröße, nicht `fileSizeInByte` vom Server — bei Vorschauen liegt das um
    /// den Faktor zehn daneben) und ohne Videos, die laut Wahl gar nicht geladen werden.
    /// Nur der iOS-Client ruft das; der Mac bleibt bei `status`.
    nonisolated static func statusAufPlatte(
        forAssetIds ids: [String],
        wahl: OfflineWahl?,
        container: ModelContainer
    ) -> (present: Int, expected: Int, bytes: Int64) {
        guard !ids.isEmpty else { return (0, 0, 0) }
        let context = ModelContext(container)
        let eindeutig = Array(Set(ids))
        var present = 0, ausgeschlossen = 0
        var bytes: Int64 = 0

        var start = 0
        while start < eindeutig.count {
            let teil = Set(eindeutig[start..<min(start + 500, eindeutig.count)])
            start += 500
            let descriptor = FetchDescriptor<CachedAsset>(predicate: #Predicate { teil.contains($0.assetId) })
            for asset in (try? context.fetch(descriptor)) ?? [] {
                let istVideo = asset.type == AssetType.video.rawValue
                if let wahl, wahl.ziel(istVideo: istVideo) == nil { ausgeschlossen += 1; continue }
                guard let url = localFileURL(forPath: asset.localFilePath) else { continue }
                present += 1
                let groesse = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                bytes += Int64(groesse)
            }
        }
        return (present, eindeutig.count - ausgeschlossen, bytes)
    }

    /// Clear the entire local file cache.
    func clearAll(container: ModelContainer) async {
        let bgContext = ModelContext(container)
        bgContext.autosaveEnabled = false

        // Delete all files on disk
        try? FileManager.default.removeItem(at: Self.cacheDirectory)
        Self.legeCacheVerzeichnisAn(Self.cacheDirectory)

        // Clear all localFilePath references
        let descriptor = FetchDescriptor<CachedAsset>(
            predicate: #Predicate<CachedAsset> { $0.localFilePath != nil }
        )
        if let allCached = try? bgContext.fetch(descriptor) {
            for asset in allCached {
                asset.localFilePath = nil
            }
        }
        try? bgContext.save()
        AppLogger.cache.info("LocalFileCacheManager: cleared all local file cache")
    }

    /// Returns the URL for a locally cached file, if it exists on disk.
    ///
    /// Nimmt bewusst den **Pfad**, nicht das `CachedAsset`. Ein SwiftData-`@Model`
    /// ist nicht `Sendable` und an den `ModelContext` gebunden, in dem es geholt
    /// wurde — meist den des Main-Actors. Es über die Aktorgrenze zu reichen und
    /// eine Eigenschaft **hier drinnen** zu lesen war genau das: ein Zugriff auf
    /// den Main-Kontext von einem anderen Executor aus. `SWIFT_VERSION: "5"`
    /// verdeckt das beim Übersetzen; im Swift-6-Modus ist es ein Fehler. Der
    /// Aufrufer liest `localFilePath` jetzt auf seinem eigenen Aktor und gibt nur
    /// die Zeichenfolge weiter.
    ///
    /// `nonisolated`, weil hier nichts vom Zustand des Aktors gebraucht wird —
    /// es ist reine Dateisystemarbeit.
    nonisolated static func localFileURL(forPath path: String?) -> URL? {
        guard let path else { return nil }
        let url = cacheDirectory.appending(path: path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Returns the total disk usage of the OriginalCache directory in bytes.
    nonisolated func totalDiskUsage() -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: Self.cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            total += Int64(size)
        }
        return total
    }

    /// Estimated cache size based on `fileSizeInByte` from SwiftData for assets within the window.
    nonisolated func estimatedSize(assets: [CachedAsset], cacheDays: Int) -> Int64 {
        guard cacheDays > 0 else { return 0 }
        let cutoff = Calendar.current.date(byAdding: .day, value: -cacheDays, to: Date()) ?? Date()
        return assets
            .filter { ($0.createdDate ?? .distantPast) >= cutoff && !$0.isTrashed }
            .compactMap { $0.fileSizeInByte }
            .reduce(0) { $0 + Int64($1) }
    }

    /// Check if an asset's creation date falls within the cache window.
    nonisolated func isWithinWindow(asset: CachedAsset, cacheDays: Int) -> Bool {
        guard cacheDays > 0, let createdDate = asset.createdDate else { return false }
        let cutoff = Calendar.current.date(byAdding: .day, value: -cacheDays, to: Date()) ?? Date()
        return createdDate >= cutoff
    }

    /// Löscht verwaiste `.tmp`-Dateien abgebrochener Downloads. Auf sie verweist kein
    /// `localFilePath`, deshalb sah keine der übrigen Aufräumfunktionen sie je.
    /// Die Altersgrenze schützt Downloads, die gerade laufen: Eine .tmp, in die
    /// noch gestreamt wird, hat ein frisches Änderungsdatum.
    /// - Returns: Anzahl der gelöschten Dateien.
    @discardableResult
    nonisolated static func removeStaleTempFiles(
        in directory: URL = cacheDirectory,
        olderThan maxAge: TimeInterval = 3600,
        now: Date = Date()
    ) -> Int {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var removed = 0
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "tmp" {
            let modified = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            guard now.timeIntervalSince(modified) > maxAge else { continue }
            if (try? fm.removeItem(at: fileURL)) != nil { removed += 1 }
        }
        if removed > 0 {
            AppLogger.cache.info("LocalFileCacheManager: \(removed) verwaiste .tmp-Dateien gelöscht")
        }
        return removed
    }

    // MARK: - Private Helpers

    private func removeFileForAssetId(_ assetId: String) {
        // Search in all month subdirectories for a file starting with assetId
        let fm = FileManager.default
        guard let months = try? fm.contentsOfDirectory(at: Self.cacheDirectory, includingPropertiesForKeys: nil) else { return }
        for monthDir in months {
            guard (try? monthDir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            guard let files = try? fm.contentsOfDirectory(at: monthDir, includingPropertiesForKeys: nil) else { continue }
            // Alle Fassungen: `a1.heic`, `a1.vorschau.jpg`, `a1.klein.mp4`.
            for file in files where OfflineFassung.gehoert(dateiname: file.lastPathComponent, zu: assetId) {
                try? fm.removeItem(at: file)
            }
        }
    }

    private func cleanEmptyDirectories() {
        let fm = FileManager.default
        guard let months = try? fm.contentsOfDirectory(at: Self.cacheDirectory, includingPropertiesForKeys: nil) else { return }
        for monthDir in months {
            let contents = (try? fm.contentsOfDirectory(at: monthDir, includingPropertiesForKeys: nil)) ?? []
            if contents.isEmpty {
                try? fm.removeItem(at: monthDir)
            }
        }
    }

    private func parseDurationSeconds(_ duration: String) -> Double? {
        // Format: "HH:MM:SS.mmm" or "MM:SS.mmm" or "SS.mmm"
        let components = duration.split(separator: ":").map(String.init)
        switch components.count {
        case 3:
            let h = Double(components[0]) ?? 0
            let m = Double(components[1]) ?? 0
            let s = Double(components[2]) ?? 0
            return h * 3600 + m * 60 + s
        case 2:
            let m = Double(components[0]) ?? 0
            let s = Double(components[1]) ?? 0
            return m * 60 + s
        case 1:
            return Double(components[0])
        default:
            return nil
        }
    }
}
