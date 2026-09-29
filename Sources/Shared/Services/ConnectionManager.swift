import Foundation
import Nuke
import Network

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected(version: String)
    case offline       // Has cached data but no server connection
    case error(String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var isOffline: Bool {
        if case .offline = self { return true }
        return false
    }

    var canBrowse: Bool {
        isConnected || isOffline
    }
}

@Observable
@MainActor
final class ConnectionManager {
    var state: ConnectionState = .disconnected
    var apiClient: ImmichAPIClient?
    var imagePipeline: ImagePipeline?
    /// Session-Flag: gesperrter Ordner ist entsperrt (nur für App-Laufzeit, kein Persist)
    var isLockedFolderUnlocked: Bool = false
    /// Session token for Sync Stream API (obtained via email/password login)
    var sessionToken: String?
    /// Was der API-Key darf (siehe ``KeyRechte``). Beim Verbinden vom Server
    /// gemeldet, ergänzt um gelernte 403 (``merkeAbgelehnt(_:)``).
    private(set) var keyRechte = KeyRechte()
    /// Aufräumen bei einem Kontowechsel (siehe ``KontoWechsel``). Setzt nur der
    /// iOS-Client; `nil` heißt: nicht prüfen.
    var beiKontoWechsel: (@MainActor () async -> Void)?
    private var networkMonitor: NWPathMonitor?
    private var monitorQueue = DispatchQueue(label: "com.immichmac.network")
    private var isNetworkAvailable = true

    // Cache references for settings UI
    private var thumbnailCache: DataCache?

    /// Stored as an @Observable property so SwiftUI re-renders correctly when
    /// credentials are loaded. Updated by refreshConfiguredState().
    private(set) var isConfigured: Bool = false

    var serverURL: String {
        KeychainStore.read(key: "serverURL") ?? ""
    }

    init() {
        // Load credentials synchronously during init so isConfigured is correct
        // before ContentView.body is ever evaluated by SwiftUI.
        // (applicationDidFinishLaunching fires after the first SwiftUI render pass,
        //  so relying on it alone causes a race where isConfigured reads an empty dict.)
        KeychainStore.loadAll()
        isConfigured = KeychainStore.read(key: "serverURL") != nil
            && KeychainStore.read(key: "apiKey") != nil
    }

    /// Re-evaluate isConfigured from the current credential store.
    /// Call after any save/delete operation to keep the observable state in sync.
    func refreshConfiguredState() {
        isConfigured = KeychainStore.read(key: "serverURL") != nil
            && KeychainStore.read(key: "apiKey") != nil
    }

    var isOnlineForSync: Bool {
        state.isConnected && isNetworkAvailable
    }

    // MARK: - Connect

    func connect(serverURL: String, apiKey: String, email: String? = nil, password: String? = nil, isAutoReconnect: Bool = false) async {
        state = .connecting
        AppLogger.connection.debug("Connecting to: \(serverURL)")

        // Normalize URL
        var urlString = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !urlString.hasPrefix("http") {
            urlString = "http://\(urlString)"
        }
        if urlString.hasSuffix("/") {
            urlString = String(urlString.dropLast())
        }

        guard let url = URL(string: urlString) else {
            state = .error("Invalid URL: \(urlString)")
            return
        }

        let client = ImmichAPIClient(baseURL: url, apiKey: apiKey)

        do {
            let pong = try await pingWithRetry(client: client)
            AppLogger.connection.info("Ping result: \(pong)")
            guard pong else {
                if isAutoReconnect { goOfflineIfCached() }
                else { state = .error("Server did not respond to ping") }
                return
            }

            let version = try await client.getServerVersion()
            // Vor dem Speichern: Ping und Version gehen auch ohne gültigen Schlüssel.
            try await client.pruefeSchluessel()

            // Rechte des Keys: gelernte Sperren dieses Keys laden, dann die frische
            // Meldung darüberlegen. Scheitert die Meldung (älterer Server), bleibt es
            // bei den gelernten Sperren — nichts Unbekanntes wird gesperrt.
            var rechte = KeyRechte(abgelehnt: KeyRechteSpeicher.ladeAbgelehnt(apiKey: apiKey))
            if let gemeldet = try? await client.eigeneKeyRechte() {
                rechte.uebernimmMeldung(gemeldet)
                KeyRechteSpeicher.speichereAbgelehnt(rechte.abgelehnt, apiKey: apiKey)
            }
            keyRechte = rechte

            // Kontowechsel erkennen, bevor der neue Client die Oberfläche erreicht.
            // Nur wenn jemand aufräumen will (iOS) — der Mac spart sich die Anfrage.
            if let beiKontoWechsel {
                let konto = await client.kontoKennung()
                let bisher = KontoWechsel.bisher(AppEnvironment.defaults)
                if KontoWechsel.istWechsel(bisher: bisher, neu: konto) {
                    AppLogger.connection.info("Anderes Konto angemeldet — lokale Daten des vorigen werden geleert")
                    await beiKontoWechsel()
                    NotificationCenter.default.post(name: .kontoGewechselt, object: nil)
                }
                KontoWechsel.merke(konto, in: AppEnvironment.defaults)
            }

            // Save credentials and update observable state
            KeychainStore.save(key: "serverURL", value: urlString)
            KeychainStore.save(key: "apiKey", value: apiKey)
            refreshConfiguredState()

            // Attempt session login for Sync Stream API (optional)
            if let email, !email.isEmpty, let password, !password.isEmpty {
                // Die Sync-Stream-Checkpoints hängen serverseitig an der Session.
                // Ein frischer Login bei jedem Verbinden würde eine neue Session
                // anlegen und damit bei jedem App-Start einen kompletten
                // Stream-Replay (~155k Zeilen, ~80 s) erzwingen. Deshalb zuerst
                // den gespeicherten Token validieren und nur bei 401 neu einloggen.
                var reusedToken: String?
                let savedToken = KeychainStore.read(key: "sessionToken")
                if let savedToken {
                    do {
                        if let tokenEmail = try await ImmichAPIClient.validateSessionToken(
                            baseURL: url, sessionToken: savedToken
                        ) {
                            if tokenEmail.caseInsensitiveCompare(email) == .orderedSame {
                                reusedToken = savedToken
                            } else {
                                AppLogger.connection.info("Saved session token belongs to \(tokenEmail), logging in as \(email)")
                            }
                        } else {
                            AppLogger.connection.info("Saved session token rejected by server (401) — fresh login")
                        }
                    } catch {
                        // Kein 401, sondern Netzwerk-/Serverfehler: Token behalten.
                        // Falls er doch tot ist, fällt der Sync auf Polling zurück
                        // und der nächste Connect loggt neu ein.
                        AppLogger.connection.warning("Session token validation errored (keeping saved token): \(error)")
                        reusedToken = savedToken
                    }
                }

                if let reusedToken {
                    self.sessionToken = reusedToken
                    KeychainStore.save(key: "email", value: email)
                    KeychainStore.save(key: "password", value: password)
                    AppLogger.connection.debug("Reusing validated session token (no fresh login)")
                } else {
                    do {
                        let loginResponse = try await ImmichAPIClient.login(
                            baseURL: url, email: email, password: password
                        )
                        // Verwaiste Session des alten Tokens serverseitig aufräumen,
                        // damit sich Sessions + Checkpoints nicht ansammeln.
                        if let savedToken, savedToken != loginResponse.accessToken {
                            await ImmichAPIClient.logout(baseURL: url, sessionToken: savedToken)
                        }
                        self.sessionToken = loginResponse.accessToken
                        KeychainStore.save(key: "sessionToken", value: loginResponse.accessToken)
                        KeychainStore.save(key: "email", value: email)
                        KeychainStore.save(key: "password", value: password)
                        AppLogger.connection.debug("Session token obtained for Sync Stream API")
                    } catch {
                        // Non-fatal: sync will fall back to polling
                        AppLogger.connection.warning("Session login failed (will use polling fallback): \(error)")
                        self.sessionToken = nil
                    }
                }
            } else {
                // Try restoring saved session token
                self.sessionToken = KeychainStore.read(key: "sessionToken")
                if sessionToken != nil {
                    AppLogger.connection.debug("Restored session token from saved credentials")
                }
            }

            // Set up image pipeline with API key header
            self.imagePipeline = Self.makeImagePipeline(apiKey: apiKey, cacheSetup: { thumb in
                self.thumbnailCache = thumb
            })
            self.apiClient = client
            self.state = .connected(version: version)
            applySavedCacheLimits()
            AppLogger.connection.info("Connected to \(urlString) (v\(version))")

            startNetworkMonitoring()

        } catch let fehler as APIError where fehler.betrifftSchluessel {
            // Auch beim automatischen Wiederverbinden kein stiller Offline-Modus: Ein
            // widerrufener Key käme sonst nie ans Licht, und die Daten veralteten still.
            AppLogger.connection.error("API key check failed: \(fehler)")
            state = .error(fehler.errorDescription ?? "API key rejected")
        } catch {
            AppLogger.connection.error("Connection error: \(error)")
            if isAutoReconnect {
                // Kaltstart ohne Netz: wenn bereits Daten lokal vorhanden → Offline-Modus
                goOfflineIfCached()
            } else {
                let nsErr = error as NSError
                AppLogger.connection.error("Connection error: domain=\(nsErr.domain) code=\(nsErr.code) msg=\(nsErr.localizedDescription)")
                state = .error("Connection failed: \(error.localizedDescription)")
            }
        }
    }

    /// Wechselt in den Offline-Modus wenn ein initialer Sync bereits abgeschlossen wurde.
    /// Baut dabei einen apiClient aus den gespeicherten Credentials (kein Ping), damit
    /// MainView (das apiClient: nicht-optional erwartet) funktioniert.
    private func goOfflineIfCached() {
        guard let urlString = KeychainStore.read(key: "serverURL"),
              let apiKey = KeychainStore.read(key: "apiKey"),
              let url = URL(string: urlString) else {
            state = .disconnected
            return
        }

        // Prüfe ob je ein initialer Sync stattgefunden hat
        let hasCache = hasCachedData()
        guard hasCache else {
            // Noch nie verbunden gewesen — Login-Screen zeigen
            state = .disconnected
            return
        }

        // apiClient ohne Ping aufbauen, nur für Offline-Betrieb
        let client = ImmichAPIClient(baseURL: url, apiKey: apiKey)
        self.imagePipeline = Self.makeImagePipeline(apiKey: apiKey, cacheSetup: { thumb in
            self.thumbnailCache = thumb
        })
        self.apiClient = client
        self.sessionToken = KeychainStore.read(key: "sessionToken")
        self.state = .offline
        applySavedCacheLimits()
        AppLogger.connection.info("Kaltstart offline — starte im Offline-Modus mit gecachten Daten")
        startNetworkMonitoring()
    }

    /// Prüft, ob es je etwas zu zeigen gab — ohne ModelContext, daher über UserDefaults.
    private func hasCachedData() -> Bool {
        Self.hasCachedData(defaults: AppEnvironment.defaults)
    }

    /// Zwei Kriterien, nicht eins: `hasCompletedInitialSync` setzt nur die SyncEngine
    /// nach dem vollständigen Erstsync (`SyncEngine.swift`, Ende von
    /// `performInitialSync`). Auf iOS läuft die Engine erst ab PR 2c, und selbst dann
    /// erst nach ~167k Assets — bis dahin wäre der Offline-Modus unerreichbar, obwohl
    /// die Albumliste längst im Cache liegt. `hasCachedAlbums` setzt der AlbumManager
    /// nach dem ersten erfolgreichen Serverabgleich (auch wenn der Server dabei null
    /// Alben lieferte — siehe Kommentar an der Setzstelle in `AlbumManager.swift`).
    /// Auf dem Mac ändert das **nicht nichts**: Im Regelfall ist dort
    /// `hasCompletedInitialSync` ohnehin zuerst gesetzt, das zweite Kriterium ist
    /// also meist redundant — außer für einen Mac, der Alben bereits geladen, den
    /// Erstsync aber nie beendet hat (z. B. Abbruch mitten in den rund 167k Assets).
    /// Der startet ab jetzt kalt in `.offline` statt in `.disconnected`. Vermutlich
    /// das bessere Verhalten, aber eine echte Verhaltensänderung gegenüber vorher.
    nonisolated static func hasCachedData(defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: "hasCompletedInitialSync")
            || defaults.bool(forKey: "hasCachedAlbums")
    }

    /// Reconnect using saved credentials (auto-reconnect — fällt auf Offline-Modus zurück wenn kein Netz)
    func reconnect() async {
        guard let urlString = KeychainStore.read(key: "serverURL"),
              let apiKey = KeychainStore.read(key: "apiKey") else {
            return
        }
        let email = KeychainStore.read(key: "email")
        let password = KeychainStore.read(key: "password")
        await connect(serverURL: urlString, apiKey: apiKey, email: email, password: password, isAutoReconnect: true)
    }

    func disconnect() {
        // Zuerst: App-weite Hintergrundläufe anhalten, bevor ihnen der Schlüssel
        // unter den Händen wegbricht. Die Nachricht geht synchron raus.
        NotificationCenter.default.post(name: .connectionDidDisconnect, object: nil)
        KeychainStore.deleteAll()
        KeyRechteSpeicher.vergiss()
        keyRechte = KeyRechte()
        apiClient = nil
        imagePipeline = nil
        thumbnailCache = nil
        isLockedFolderUnlocked = false
        stopNetworkMonitoring()
        state = .disconnected
        refreshConfiguredState()
    }

    /// Ein Aufruf ist mit 403 an `recht` gescheitert: für diesen Key merken, damit
    /// die Oberfläche die Aktion ab sofort ausblendet — auch nach einem Neustart.
    func merkeAbgelehnt(_ recht: String) {
        keyRechte.merkeAbgelehnt(recht)
        if let apiKey = KeychainStore.read(key: "apiKey") {
            KeyRechteSpeicher.speichereAbgelehnt(keyRechte.abgelehnt, apiKey: apiKey)
        }
    }

    /// Switch to offline mode when server is unreachable but we have cached data
    func goOffline() {
        if state.isConnected {
            state = .offline
        }
    }

    /// Return to connected state when server becomes reachable again
    func goOnline(version: String) {
        if state.isOffline {
            state = .connected(version: version)
        }
    }

    // MARK: - Network Monitoring

    private func startNetworkMonitoring() {
        stopNetworkMonitoring()
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let wasAvailable = self.isNetworkAvailable
                self.isNetworkAvailable = path.status == .satisfied

                if !self.isNetworkAvailable && wasAvailable {
                    // Network dropped
                    self.goOffline()
                    AppLogger.connection.info("Network lost — switching to offline mode")
                } else if self.isNetworkAvailable && !wasAvailable {
                    // Network returned — try to reconnect
                    AppLogger.connection.info("Network returned — attempting reconnect")
                    await self.reconnect()
                }
            }
        }
        monitor.start(queue: monitorQueue)
        self.networkMonitor = monitor
    }

    private func stopNetworkMonitoring() {
        networkMonitor?.cancel()
        networkMonitor = nil
    }

    // MARK: - Retry Logic

    /// Ping with automatic retry for transient local network errors.
    /// macOS sometimes blocks local network access briefly on cold start
    /// (error -1009 "Local network prohibited") before granting permission.
    private func pingWithRetry(client: ImmichAPIClient, maxRetries: Int = 3) async throws -> Bool {
        var lastError: Error?
        for attempt in 0..<maxRetries {
            do {
                return try await client.ping()
            } catch {
                let nsError = error as NSError
                // **-1009 gehört nicht hierher.** Es heißt „das Gerät hat gar
                // keine Internetverbindung" — im Flugmodus oder Funkloch ist
                // das nicht eine Störung, die vorbeigeht, sondern die endgültige
                // Antwort. Dreimal zu fragen kostete dort 1 s + 2 s Pause plus
                // drei Anfragezeitlimits: Der Kaltstart hing rund 15 Sekunden
                // auf „Verbinde…", bevor er in den Offlinemodus fiel, obwohl
                // schon die erste Antwort alles gesagt hatte.
                //
                // -1004 („could not connect to server") bleibt: Da **gibt** es
                // ein Netz, nur der Server antwortet gerade nicht — ein
                // aufwachender Server ist genau der Fall, für den die
                // Wiederholung gedacht war.
                let isTransient = nsError.code == -1004
                    && nsError.domain == NSURLErrorDomain
                if isTransient && attempt < maxRetries - 1 {
                    let delay = UInt64(pow(2.0, Double(attempt))) * 1_000_000_000 // 1s, 2s, 4s
                    AppLogger.connection.debug("Ping attempt \(attempt + 1) failed (transient), retrying in \(Int(pow(2.0, Double(attempt))))s…")
                    try await Task.sleep(nanoseconds: delay)
                    lastError = error
                } else {
                    throw error
                }
            }
        }
        throw lastError ?? NSError(domain: "ConnectionManager", code: -1)
    }

    // MARK: - Image Pipeline

    private static func makeImagePipeline(
        apiKey: String,
        cacheSetup: @escaping (DataCache?) -> Void
    ) -> ImagePipeline {
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.httpAdditionalHeaders = [
            "x-api-key": apiKey,
            "Accept": "image/*",
        ]
        // Kein HTTP-Cache: Nuke bringt mit ImageCache (Speicher) und DataCache (Platte,
        // 5 GB) bereits zwei Schichten mit, die `invalidateAssetCaches` gezielt räumen
        // kann. Der URLCache wäre eine dritte, die niemand räumt — und weil Immich
        // Bilder langlebig cachebar ausliefert, hat genau die nach einer Drehung das
        // alte Bild zurückgereicht, obwohl beide Nuke-Schichten geleert waren.
        sessionConfig.urlCache = nil
        sessionConfig.requestCachePolicy = .reloadIgnoringLocalCacheData

        var config = ImagePipeline.Configuration()
        let loader = DataLoader(configuration: sessionConfig)
        // Nuke reicht `willPerformHTTPRedirection` an diesen Delegaten weiter —
        // sonst folgte die Pipeline einer Weiterleitung samt `x-api-key` auf
        // einen fremden Host (belegt an `SichereWeiterleitung`).
        loader.delegate = SichereWeiterleitung.shared
        config.dataLoader = loader
        #if os(macOS)
        // Raster-Thumbnails im Hintergrund fertig dekodieren — sonst dekodiert Core
        // Animation sie beim Scrollen auf dem Hauptthread. Nur macOS: auf iOS
        // dekomprimiert Nuke selbst. Begründung und Grenzen am Typ.
        config.makeImageDecoder = ThumbnailVorDekodierer.fabrik
        #endif

        // Memory cache: ~500 MB for decoded thumbnails
        // At ~100KB per 150px thumbnail, this holds ~5000 decoded images,
        // enough for smooth scrolling through several screens without eviction.
        let imageCache = ImageCache()
        imageCache.costLimit = 500 * 1024 * 1024
        config.imageCache = imageCache

        // Disk cache: single cache for both thumbnails and full-size images
        var thumbCache: DataCache?
        if let dataCache = try? DataCache(name: "com.immichmac.thumbnails") {
            dataCache.sizeLimit = 2 * 1024 * 1024 * 1024
            config.dataCache = dataCache
            thumbCache = dataCache
        }

        cacheSetup(thumbCache)

        return ImagePipeline(configuration: config)
    }

    // MARK: - Cache Management (for Settings UI)

    var thumbnailCacheUsageString: String {
        guard let cache = thumbnailCache else { return "N/A" }
        return ByteCountFormatter.string(fromByteCount: Int64(cache.totalSize), countStyle: .file)
    }

    func clearThumbnailCache() {
        thumbnailCache?.removeAll()
        AppLogger.connection.debug("Thumbnail cache cleared")
    }

    /// Targeted invalidation for changed assets to avoid stale thumbnails/previews.
    /// Clears BOTH the disk DataCache AND the in-memory ImageCache.
    ///
    /// Geräumt werden **beide** Fassungen je Größe (mit und ohne `edited=true`) — die
    /// Liste liefert ``ImmichAPIClient/cacheKeyURLs(assetId:)``. Ein Asset, das gerade
    /// erst als bearbeitet markiert wurde, wechselt seine URL; unter der alten läge
    /// sonst weiterhin das alte Bild und käme zurück, sobald die Bearbeitung
    /// zurückgenommen wird.
    func invalidateAssetCaches(assetIds: [String], apiClient: ImmichAPIClient) {
        guard !assetIds.isEmpty else { return }

        // Capture thread-safe dependencies to use off the main actor
        let pipeline = imagePipeline
        let dataCache = thumbnailCache

        // `.utility`, nicht `.background`: Eine Hintergrundaufgabe kommt neben einem
        // laufenden Sync minutenlang nicht zum Zug — hier hängt aber die Anzeige daran.
        Task.detached(priority: .utility) {
            Self.purgeCaches(assetIds: assetIds, apiClient: apiClient,
                             pipeline: pipeline, dataCache: dataCache)
        }
    }

    /// Wie ``invalidateAssetCaches(assetIds:apiClient:)``, nur abwartbar.
    ///
    /// Wer unmittelbar danach dasselbe Bild neu anfordert, **muss** diese Fassung
    /// benutzen: Sonst überholt die Anfrage die Räumung, trifft den alten Eintrag und
    /// legt ihn gleich wieder ab — das Bild bliebe sichtbar alt, obwohl alles „geräumt"
    /// wurde. Beim Drehen ist genau das der Fall.
    func invalidateAssetCachesAndWait(assetIds: [String], apiClient: ImmichAPIClient) async {
        guard !assetIds.isEmpty else { return }
        let pipeline = imagePipeline
        let dataCache = thumbnailCache
        await Task.detached(priority: .userInitiated) {
            Self.purgeCaches(assetIds: assetIds, apiClient: apiClient,
                             pipeline: pipeline, dataCache: dataCache)
        }.value
    }

    nonisolated private static func purgeCaches(
        assetIds: [String],
        apiClient: ImmichAPIClient,
        pipeline: ImagePipeline?,
        dataCache: DataCache?
    ) {
        for id in assetIds {
            for url in apiClient.cacheKeyURLs(assetId: id) {
                dataCache?.removeData(for: url.absoluteString)
                // Nuke fragt zuerst den Speicher-Cache; ohne diese Zeile bliebe das
                // alte Bild sichtbar, obwohl die Platte längst geräumt ist.
                pipeline?.cache.removeCachedImage(for: ImageRequest(url: url))
            }
        }
        AppLogger.connection.debug("Invalidated caches (memory + disk) for \(assetIds.count) assets")
    }

    func setThumbnailCacheLimit(gb: Int) {
        if gb == 0 {
            thumbnailCache?.sizeLimit = Int.max  // "Unlimited"
        } else {
            thumbnailCache?.sizeLimit = gb * 1024 * 1024 * 1024
        }
    }



    /// Apply saved cache limits from UserDefaults on startup.
    func applySavedCacheLimits() {
        let thumbLimit = AppEnvironment.defaults.integer(forKey: "thumbnailCacheLimit")
        if thumbLimit != 0 || AppEnvironment.defaults.object(forKey: "thumbnailCacheLimit") != nil {
            setThumbnailCacheLimit(gb: thumbLimit)
        }
    }
}
