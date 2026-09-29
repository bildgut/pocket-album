import Foundation
import SwiftData
import os
import Network
import Observation

// MARK: - Fortschritt (MainActor)

/// Fortschritt des laufenden Offline-Laufs, direkt beobachtbar aus SwiftUI.
@MainActor
@Observable
final class OfflineSyncProgress {
    static let shared = OfflineSyncProgress()
    private init() {}

    /// Läuft gerade ein Durchgang?
    var isActive: Bool = false
    /// Name des Albums, das gerade an der Reihe ist.
    var currentPinName: String = ""
    /// Dateien, die dieser Durchgang insgesamt zu laden hat (über alle Alben).
    var total: Int = 0
    /// Bereits geladene Dateien in diesem Durchgang.
    var completed: Int = 0
    /// Dateien, die in diesem Durchgang fehlgeschlagen sind.
    var failed: Int = 0
    /// Der Nutzer hat Abbrechen gedrückt, der Lauf ebbt gerade aus.
    var isCancelling: Bool = false
    /// Vermerke (`pinId`), deren Lauf vor einer Datei anhielt, weil das Netz teuer ist
    /// und das Album nicht über Mobilfunk laden darf. **Nicht** Teil von `reset()`:
    /// Der Zustand muss den Lauf überdauern, sonst sähe die Ansicht ihn nie.
    var wartetAufWLAN: Set<String> = []

    var progress: Double {
        guard total > 0 else { return 0 }
        return Double(completed) / Double(total)
    }

    var labelText: String {
        guard isActive else { return "" }
        if isCancelling { return "Wird abgebrochen…" }
        guard total > 0 else { return "Vorbereitung…" }
        var text = "\(completed)/\(total) Dateien"
        if !currentPinName.isEmpty { text += " · \(currentPinName)" }
        if failed > 0 { text += " · \(failed) fehlgeschlagen" }
        return text
    }

    /// Bricht den laufenden Durchgang ab. Bereits geladene Dateien bleiben liegen.
    func cancel() {
        guard isActive, !isCancelling else { return }
        isCancelling = true
        Task { await OfflineDownloadManager.shared.cancel() }
    }

    fileprivate func reset() {
        isActive = false
        isCancelling = false
        currentPinName = ""
        total = 0
        completed = 0
        failed = 0
    }
}

// MARK: - Auflösung von Smart Alben

/// Löst die Mitgliedschaft gepinnter Smart Alben auf.
///
/// Eigener Typ auf dem MainActor, weil ``SmartAlbumMirrorService`` dort lebt und
/// SwiftData-Objekte ihren Context nicht verlassen dürfen: Der ``OfflineDownloadManager``
/// darf seine `SmartAlbum`-Instanzen nicht herüberreichen. Also läuft die Auflösung
/// vollständig hier — mit eigenem Context — und zurück gehen nur Zeichenketten.
@MainActor
enum OfflineSmartAlbumResolver {

    /// - Parameter smartAlbumIds: `SmartAlbum.id.uuidString` der gepinnten Smart Alben.
    /// - Returns: Ergebnis je `uuidString`. Fehlt ein Eintrag, gibt es das Album nicht mehr.
    static func resolve(
        smartAlbumIds: [String],
        container: ModelContainer,
        apiClient: ImmichAPIClient
    ) async -> [String: SmartAlbumResolution] {
        guard !smartAlbumIds.isEmpty else { return [:] }

        let context = ModelContext(container)
        let wanted = Set(smartAlbumIds)
        let albums = ((try? context.fetch(FetchDescriptor<SmartAlbum>())) ?? [])
            .filter { wanted.contains($0.id.uuidString) }
        guard !albums.isEmpty else { return [:] }

        // Der vollständige Bestand — nur so gilt `poolIsComplete`. Das Laden ist
        // SQLite-Arbeit und gehört nicht auf den MainActor.
        let pool = await Task.detached(priority: .utility) {
            GridIndexStore.shared.loadAll()
        }.value

        guard !pool.isEmpty else {
            let reason = "Der lokale Bildbestand ist noch leer — die Regeln lassen sich nicht auswerten."
            return albums.reduce(into: [:]) { $0[$1.id.uuidString] = .skipped(reason: reason) }
        }

        let service = SmartAlbumMirrorService(apiClient: apiClient)
        // Aus dem eigenen Context, nicht aus `albums`: Das sind nur die gepinnten
        // Smart Alben, ausgenommen gehören aber die Spiegel *aller*.
        let mirroredAlbumIds = SmartAlbum.mirroredServerAlbumIds(in: context)
        var results: [String: SmartAlbumResolution] = [:]
        for album in albums {
            results[album.id.uuidString] = await service.resolveTargetIds(
                for: album,
                basePool: pool,
                poolIsComplete: true,
                mirroredAlbumIds: mirroredAlbumIds
            )
        }
        return results
    }
}

/// Eine zu ladende Datei: welches Asset, in welchen Monatsordner, welche Fassung.
struct OfflineLadeposten: Equatable, Sendable {
    let assetId: String
    let monthKey: String
    let fassung: OfflineFassung
}

// MARK: - Download-Manager

/// Hält die Originale der offline gepinnten Alben und Smart Alben auf der Platte.
actor OfflineDownloadManager {
    static let shared = OfflineDownloadManager()

    /// Mindest-Pause zwischen automatischen Offline-Läufen (15 Minuten).
    /// Wird in UserDefaults persistiert — überlebt App-Neustarts.
    private static let cooldownInterval: TimeInterval = 15 * 60
    private static let lastSyncKey = "offlineSync.lastSyncDate"

    /// Wie viele Dateien gleichzeitig geladen werden. Drei ist der Kompromiss zwischen
    /// „der erste Lauf über ein paar tausend Fotos dauert ewig" und „der Server sowie die
    /// eigene Leitung bleiben für den Rest der App benutzbar".
    private static let maxConcurrentDownloads = 3
    /// Nach so vielen fertigen Dateien wird zwischengespeichert. Nicht nach jeder Datei
    /// (zu viele Schreibvorgänge) und nicht erst am Ende (ein Absturz verlöre alles).
    private static let persistBatchSize = 25

    private let monitor = NWPathMonitor()
    private var isMetered: Bool = false
    private var isSyncing: Bool = false
    private var cancelRequested: Bool = false

    private var lastSyncDate: Date? {
        get { AppEnvironment.defaults.object(forKey: Self.lastSyncKey) as? Date }
        set { AppEnvironment.defaults.set(newValue, forKey: Self.lastSyncKey) }
    }

    /// Welche Offline-Wahl ein Vermerk hat. Setzt nur der iOS-Client; ohne Quelle
    /// verhält sich der Lader exakt wie vor der Offline-Qualität (Mac).
    private var wahlQuelle: (@Sendable (String) -> OfflineWahl?)?

    func setzeWahlQuelle(_ quelle: @escaping @Sendable (String) -> OfflineWahl?) {
        wahlQuelle = quelle
    }

    /// - Parameter ueberwacheNetz: `false` nur in Tests, die die Netzlage selbst setzen.
    init(ueberwacheNetz: Bool = true) {
        guard ueberwacheNetz else { return }
        monitor.pathUpdateHandler = { [weak self] path in
            Task { [weak self] in
                await self?.updateMeteredStatus(path.isExpensive || path.isConstrained)
            }
        }
        monitor.start(queue: DispatchQueue.global(qos: .background))
    }

    func updateMeteredStatus(_ metered: Bool) {
        self.isMetered = metered
    }

    /// Bricht den laufenden Durchgang ab. Wirkt wie `Task.isCancelled`, überlebt aber die
    /// `Task.detached`-Grenzen, über die der Lauf aus dem Sync heraus gestartet wird.
    func cancel() {
        guard isSyncing else { return }
        cancelRequested = true
        AppLogger.cache.info("OfflineDownloadManager: Abbruch angefordert")
    }

    private var shouldStop: Bool {
        cancelRequested || Task.isCancelled
    }

    // MARK: - Hauptlauf

    /// Löst alle Offline-Vermerke auf und lädt fehlende Originale nach.
    /// - Parameter force: Ignoriert den 15-Minuten-Cooldown (manuell ausgelöst).
    /// - Parameter mobilfunkFreigabe: Vermerke (`pinId`), die in **diesem** Lauf auch
    ///   über eine teure Verbindung laden dürfen („Jetzt laden“ im Albumdetail). Gilt
    ///   nur mit Wahl-Quelle; alle anderen Vermerke behalten ihre eigene Wahl.
    func syncOfflineAlbums(
        container: ModelContainer,
        apiClient: ImmichAPIClient,
        respectMetered: Bool = true,
        force: Bool = false,
        mobilfunkFreigabe: Set<String> = []
    ) async {
        if isSyncing { return }

        if !force, let last = lastSyncDate,
           Date().timeIntervalSince(last) < Self.cooldownInterval {
            return
        }

        // Mit Wahl-Quelle entscheidet jedes Album selbst (Mobilfunk-Freigabe),
        // geprüft vor jeder Datei. Ohne Quelle (Mac) wie bisher: gar nicht erst anfangen.
        if respectMetered && isMetered && wahlQuelle == nil {
            AppLogger.cache.info("OfflineDownloadManager: Lauf übersprungen — getaktete Verbindung.")
            return
        }

        isSyncing = true
        cancelRequested = false
        defer {
            isSyncing = false
            cancelRequested = false
            Task { await MainActor.run { OfflineSyncProgress.shared.reset() } }
        }

        // `isActive` **hier**, nicht erst wenn die Dateiliste steht. Zwischen
        // diesen beiden Punkten löst der Lauf die Albumzugehörigkeit über die
        // API auf — bei einem Album mit vielen Assets sind das mehrere Sekunden
        // Netzverkehr. Solange `isActive` dabei `false` blieb, hielten die
        // Ansichten den Lauf für gar nicht gestartet: Auf dem Telefon stand
        // deshalb „Wartet auf WLAN oder auf den nächsten Durchgang", während
        // der Download in Wahrheit längst lief.
        //
        // `labelText` war für diese Phase schon vorbereitet: Bei `total == 0`
        // sagt es „Vorbereitung…". Diese Zeile ist also weniger eine Änderung
        // als das Nachholen dessen, was die Anzeige immer schon annahm. Das
        // `defer` oben setzt alles zurück, auch auf den frühen Rückwegen.
        await updateProgress { p in
            p.isActive = true
            p.total = 0
            p.completed = 0
            p.failed = 0
        }

        let bgContext = ModelContext(container)
        bgContext.autosaveEnabled = false

        // Alt-Markierungen an Alben übernehmen — einmalig, danach ein No-Op.
        OfflinePinStore.migrateLegacyFlags(in: bgContext)

        let pins = OfflinePinStore.allPins(in: bgContext)
        guard !pins.isEmpty else {
            // Ohne Vermerk bleibt das Cooldown-Fenster absichtlich unverbraucht: Sonst
            // blockierte ein Leerlauf genau den Lauf, der nach dem Pinnen etwas zu tun hätte.
            return
        }

        AppLogger.cache.info("OfflineDownloadManager: Lauf für \(pins.count) Vermerk(e) gestartet.")
        lastSyncDate = Date()

        // ── 1. Mitgliedschaft auflösen ────────────────────────────────────────
        let smartIds = pins.filter { $0.kind == .smartAlbum }.map(\.targetId)
        let smartResolutions = await OfflineSmartAlbumResolver.resolve(
            smartAlbumIds: smartIds,
            container: container,
            apiClient: apiClient
        )

        for pin in pins {
            guard !shouldStop else { break }
            switch pin.kind {
            case .album:
                await resolveAlbumPin(pin, apiClient: apiClient, bgContext: bgContext)
            case .smartAlbum:
                applySmartResolution(smartResolutions[pin.targetId], to: pin)
            }
        }
        try? bgContext.save()

        // ── 2. Arbeitsliste bilden ────────────────────────────────────────────
        // Als einfache Werte, nicht als SwiftData-Objekte: nur so lassen sich die
        // Downloads gefahrlos parallelisieren.
        var work: [(pin: OfflinePin, items: [OfflineLadeposten], mobilfunk: Bool)] = []
        for pin in pins {
            let wahl = wahlQuelle?(pin.pinId)
            let items: [OfflineLadeposten]
            if let wahl {
                items = Self.fehlendeDateien(for: pin.assetIds, in: bgContext, wahl: wahl)
            } else {
                items = missingDownloads(for: pin.assetIds, in: bgContext)
                    .map { OfflineLadeposten(assetId: $0.assetId, monthKey: $0.monthKey, fassung: .original) }
            }
            if items.isEmpty {
                await vermerkeWartend(pin.pinId, false)
                // Nichts zu tun heißt fertig — auch wenn ein anderer Vermerk noch
                // lädt oder auf WLAN wartet (sonst bliebe ein reines Videoalbum mit
                // „Videos: Keine“ ewig auf „wird geladen“). Nur mit Wahl: der Mac
                // bleibt, wie er war.
                if wahl != nil, pin.lastError == nil { pin.lastCompletedAt = Date() }
            } else {
                work.append((pin, items, wahl?.mobilfunk ?? false))
            }
        }
        // Die eben fertig gewordenen Vermerke sichern — ein Lauf, dessen übrige
        // Vermerke nur auf WLAN warten, erreicht sonst kein `save()` mehr.
        try? bgContext.save()

        let overallTotal = work.reduce(0) { $0 + $1.items.count }
        guard overallTotal > 0 else {
            for pin in pins where pin.lastError == nil {
                pin.lastCompletedAt = Date()
            }
            try? bgContext.save()
            AppLogger.cache.debug("OfflineDownloadManager: alles vollständig, nichts zu laden.")
            await evictNoLongerPinned(container: container)
            return
        }

        // `isActive` steht schon seit dem Beginn des Laufs; hier kommt nur die
        // nun bekannte Gesamtzahl dazu, womit `labelText` von „Vorbereitung…"
        // auf „0/N Dateien" wechselt.
        await updateProgress { p in
            p.total = overallTotal
            p.completed = 0
            p.failed = 0
        }

        // ── 3. Laden ──────────────────────────────────────────────────────────
        for entry in work {
            guard !shouldStop else { break }
            let netzPruefen = respectMetered && !entry.mobilfunk
                && !mobilfunkFreigabe.contains(entry.pin.pinId)
            if netzPruefen && isMetered {
                // Mac: wie bisher der ganze Lauf. iOS: nur dieses Album wartet,
                // ein anderes darf vielleicht über Mobilfunk.
                guard wahlQuelle != nil else { break }
                await vermerkeWartend(entry.pin.pinId, true)
                continue
            }

            let pinName = entry.pin.displayName
            await updateProgress { $0.currentPinName = pinName }
            AppLogger.cache.info("OfflineDownloadManager: \(entry.items.count) Datei(en) fehlen für '\(pinName)'.")

            let ergebnis = await download(
                items: entry.items,
                apiClient: apiClient,
                bgContext: bgContext,
                // Vor **jeder** Datei nur mit Wahl-Quelle — der Mac prüft wie bisher
                // nur zwischen Vermerken.
                netzPruefen: netzPruefen && wahlQuelle != nil
            )

            await vermerkeWartend(entry.pin.pinId, ergebnis.angehalten)
            if ergebnis.fehler > 0 {
                entry.pin.lastError = "\(ergebnis.fehler) von \(entry.items.count) Dateien konnten nicht geladen werden."
            } else if !ergebnis.angehalten {
                entry.pin.lastError = nil
                entry.pin.lastCompletedAt = Date()
            }
            try? bgContext.save()
        }

        await evictNoLongerPinned(container: container)
        AppLogger.cache.info("OfflineDownloadManager: Lauf beendet.")
    }

    // MARK: - Auflösung

    /// Holt die Mitgliedschaft eines echten Albums vom Server und legt neue Assets an.
    private func resolveAlbumPin(_ pin: OfflinePin, apiClient: ImmichAPIClient, bgContext: ModelContext) async {
        do {
            let detail = try await apiClient.getAlbumDetail(id: pin.targetId)

            for asset in detail.assets {
                let assetId = asset.id
                var descriptor = FetchDescriptor<CachedAsset>(predicate: #Predicate { $0.assetId == assetId })
                descriptor.fetchLimit = 1
                if let existing = try? bgContext.fetch(descriptor).first {
                    _ = existing.update(from: asset)
                } else {
                    bgContext.insert(CachedAsset(from: asset))
                }
            }

            pin.assetIds = detail.assets.map(\.id)
            pin.displayName = detail.albumName
            pin.lastResolvedAt = Date()
            pin.lastError = nil

            // Das alte Flag mitpflegen, solange es noch am Model steht — sonst zeigte ein
            // Downgrade auf eine ältere App-Version das Album als nicht offline an.
            let albumId = pin.targetId
            var albumDescriptor = FetchDescriptor<CachedAlbum>(predicate: #Predicate { $0.albumId == albumId })
            albumDescriptor.fetchLimit = 1
            if let cachedAlbum = try? bgContext.fetch(albumDescriptor).first {
                cachedAlbum.isMarkedForOffline = true
                cachedAlbum.assetIds = pin.assetIds
            }
        } catch {
            // Die zuletzt aufgelöste Liste bleibt stehen: Sie ist besser als keine, und
            // ohne sie flögen beim nächsten Aufräumen alle Dateien des Albums raus.
            pin.lastError = "Album konnte nicht vom Server geladen werden: \(error.localizedDescription)"
            AppLogger.cache.error("OfflineDownloadManager: Auflösung von '\(pin.displayName)' fehlgeschlagen: \(error)")
        }
    }

    private func applySmartResolution(_ resolution: SmartAlbumResolution?, to pin: OfflinePin) {
        switch resolution {
        case .resolved(let ids):
            pin.assetIds = Array(ids)
            pin.lastResolvedAt = Date()
            pin.lastError = nil
        case .skipped(let reason):
            // Wie oben: alte Liste behalten. Ein übersprungener Lauf ist keine Aussage
            // darüber, dass das Album leer wäre.
            pin.lastError = reason
            AppLogger.cache.info("OfflineDownloadManager: '\(pin.displayName)' übersprungen — \(reason)")
        case .none:
            pin.lastError = "Das Smart Album gibt es nicht mehr."
        }
    }

    // MARK: - Downloads

    /// Welche der IDs haben noch keine Datei auf der Platte?
    private func missingDownloads(
        for assetIds: [String],
        in bgContext: ModelContext
    ) -> [(assetId: String, monthKey: String)] {
        Self.fehlendeDateien(for: assetIds, in: bgContext)
    }

    /// Fragt nur die IDs des Vermerks ab, in 500er-Häppchen per `IN`.
    ///
    /// Vorher holte ein einziger Fetch **alle** Assets ohne lokale Datei und filterte
    /// danach im Speicher. Weil fast keines eine lokale Datei hat, waren das auf dem
    /// Bestand vom 21.09.2026 123 436 von 124 692 `CachedAsset`-Objekten — für einen
    /// Vermerk mit rund 240 Assets. Das kostete je Lauf (alle 15 min, solange die
    /// App offen ist) rund 10 s CPU am Stück und hob den Speicher kurz auf ~390 MB.
    /// Die Häppchengröße ist dieselbe wie im EXIF-Abgleich von `SyncEngine`.
    ///
    /// Reihenfolge wie im Vermerk, doppelte IDs einmal.
    static func fehlendeDateien(
        for assetIds: [String],
        in context: ModelContext
    ) -> [(assetId: String, monthKey: String)] {
        guard !assetIds.isEmpty else { return [] }
        var gesehen = Set<String>()
        let eindeutig = assetIds.filter { gesehen.insert($0).inserted }

        var fehlend: [String: String] = [:]   // assetId → monthKey
        var start = 0
        while start < eindeutig.count {
            let ids = Set(eindeutig[start..<min(start + 500, eindeutig.count)])
            start += 500
            let descriptor = FetchDescriptor<CachedAsset>(
                predicate: #Predicate<CachedAsset> {
                    ids.contains($0.assetId) && $0.localFilePath == nil && $0.isTrashed == false
                }
            )
            guard let treffer = try? context.fetch(descriptor) else { continue }
            for asset in treffer { fehlend[asset.assetId] = asset.monthKey }
        }
        return eindeutig.compactMap { id in fehlend[id].map { (assetId: id, monthKey: $0) } }
    }

    /// Fehlende Dateien eines Vermerks **mit** Offline-Wahl (iOS).
    ///
    /// Anders als ohne Wahl zählt hier auch ein Asset mit Datei als fehlend, wenn die
    /// vorhandene Fassung nicht reicht (Vorschau liegt da, Original ist gewünscht).
    /// Reihenfolge: erst Fotos, dann Videos, je neueste zuerst — so ist ein großes
    /// Album nach Minuten brauchbar, nicht erst nach dem letzten Video.
    static func fehlendeDateien(
        for assetIds: [String],
        in context: ModelContext,
        wahl: OfflineWahl
    ) -> [OfflineLadeposten] {
        guard !assetIds.isEmpty else { return [] }
        let eindeutig = Array(Set(assetIds))
        var fotos: [(datum: String, posten: OfflineLadeposten)] = []
        var videos: [(datum: String, posten: OfflineLadeposten)] = []

        var start = 0
        while start < eindeutig.count {
            let ids = Set(eindeutig[start..<min(start + 500, eindeutig.count)])
            start += 500
            let descriptor = FetchDescriptor<CachedAsset>(
                predicate: #Predicate<CachedAsset> { ids.contains($0.assetId) && $0.isTrashed == false }
            )
            guard let treffer = try? context.fetch(descriptor) else { continue }
            for asset in treffer {
                let istVideo = asset.type == AssetType.video.rawValue
                guard let ziel = wahl.ziel(istVideo: istVideo) else { continue }
                if let pfad = asset.localFilePath,
                   wahl.reicht(OfflineFassung.aus(pfad: pfad), istVideo: istVideo) { continue }
                let posten = OfflineLadeposten(assetId: asset.assetId, monthKey: asset.monthKey, fassung: ziel)
                if istVideo {
                    videos.append((asset.fileCreatedAt, posten))
                } else {
                    fotos.append((asset.fileCreatedAt, posten))
                }
            }
        }
        let neuesteZuerst: ((datum: String, posten: OfflineLadeposten), (datum: String, posten: OfflineLadeposten)) -> Bool = {
            $0.datum != $1.datum ? $0.datum > $1.datum : $0.posten.assetId < $1.posten.assetId
        }
        return fotos.sorted(by: neuesteZuerst).map(\.posten) + videos.sorted(by: neuesteZuerst).map(\.posten)
    }

    /// Lädt die Dateien mit begrenzter Parallelität und schreibt die Pfade gebündelt zurück.
    /// - Returns: Fehlschläge und ob der Lauf wegen teuren Netzes vor einer Datei anhielt.
    private func download(
        items: [OfflineLadeposten],
        apiClient: ImmichAPIClient,
        bgContext: ModelContext,
        netzPruefen: Bool
    ) async -> (fehler: Int, angehalten: Bool) {
        var failures = 0
        var angehalten = false
        var pending: [(assetId: String, path: String)] = []
        var index = 0

        await withTaskGroup(of: (String, String?).self) { group in
            func addNext() {
                guard index < items.count, !shouldStop else { return }
                // `isMetered` kann sich zwischen zwei Dateien ändern: Die Gruppe wartet
                // bei `for await`, dabei läuft `updateMeteredStatus` auf diesem Actor.
                if netzPruefen, isMetered { angehalten = true; return }
                let item = items[index]
                index += 1
                group.addTask {
                    do {
                        let path = try await LocalFileCacheManager.downloadToCache(
                            assetId: item.assetId,
                            monthKey: item.monthKey,
                            fassung: item.fassung,
                            apiClient: apiClient
                        )
                        return (item.assetId, path)
                    } catch {
                        AppLogger.cache.error("OfflineDownloadManager: Download von \(item.assetId) fehlgeschlagen: \(error)")
                        return (item.assetId, nil)
                    }
                }
            }

            for _ in 0..<Self.maxConcurrentDownloads { addNext() }

            for await (assetId, path) in group {
                if let path {
                    pending.append((assetId, path))
                } else {
                    failures += 1
                }

                await updateProgress { p in
                    p.completed += 1
                    if path == nil { p.failed += 1 }
                }

                if pending.count >= Self.persistBatchSize {
                    persist(pending, in: bgContext)
                    pending.removeAll(keepingCapacity: true)
                }

                addNext()
            }
        }

        persist(pending, in: bgContext)
        return (failures, angehalten)
    }

    private func persist(_ results: [(assetId: String, path: String)], in bgContext: ModelContext) {
        guard !results.isEmpty else { return }
        for result in results {
            let assetId = result.assetId
            var descriptor = FetchDescriptor<CachedAsset>(predicate: #Predicate { $0.assetId == assetId })
            descriptor.fetchLimit = 1
            guard let asset = try? bgContext.fetch(descriptor).first else { continue }
            // Zwei Vermerke mit verschiedener Wahl teilen sich ein Asset, und beide
            // Arbeitslisten entstanden, bevor etwas geladen war: Ein Original wird
            // nie gegen eine kleinere Fassung getauscht — die neue Datei geht.
            if let alt = asset.localFilePath, alt != result.path,
               OfflineFassung.aus(pfad: alt) == .original,
               OfflineFassung.aus(pfad: result.path) != .original,
               LocalFileCacheManager.localFileURL(forPath: alt) != nil {
                if let neuURL = LocalFileCacheManager.localFileURL(forPath: result.path) {
                    try? FileManager.default.removeItem(at: neuURL)
                }
                continue
            }
            // Aufgewertet (Vorschau → Original)? Sonst bliebe die alte Datei verwaist.
            // Ohne Wahl (Mac) kommt hier nur an, was vorher gar keine Datei hatte.
            if let alt = asset.localFilePath, alt != result.path,
               let altURL = LocalFileCacheManager.localFileURL(forPath: alt) {
                try? FileManager.default.removeItem(at: altURL)
            }
            asset.localFilePath = result.path
        }
        try? bgContext.save()
    }

    // MARK: - Aufräumen

    /// Räumt Dateien weg, die nach dieser Auflösung kein Vermerk mehr hält.
    ///
    /// Nötig, weil ein Smart Album seine Mitgliedschaft ändern kann: Was gestern noch
    /// „letzte 30 Tage" war, ist heute draußen. Ohne diesen Schritt wüchse der
    /// Offline-Bestand nur noch.
    private func evictNoLongerPinned(container: ModelContainer) async {
        let cacheDays = AppEnvironment.defaults.integer(forKey: "localFileCacheDays")
        await LocalFileCacheManager.shared.evictUnpinned(container: container, cacheDays: cacheDays)
    }

    // MARK: - Fortschritt

    private func vermerkeWartend(_ pinId: String, _ wartet: Bool) async {
        await updateProgress { p in
            if wartet { p.wartetAufWLAN.insert(pinId) } else { p.wartetAufWLAN.remove(pinId) }
        }
    }

    private func updateProgress(_ mutate: @escaping @MainActor (OfflineSyncProgress) -> Void) async {
        await MainActor.run { mutate(OfflineSyncProgress.shared) }
    }
}
