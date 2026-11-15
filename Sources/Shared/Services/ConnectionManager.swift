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

/// Aktive Verbindungsroute bei konfigurierter Dual-URL („Home & Away").
enum ServerRouteKind: String, Equatable, Sendable {
    case primary
    case external

    var kurzName: String {
        switch self {
        case .primary: return "Lokal"
        case .external: return "Remote"
        }
    }

    var beschreibung: String {
        switch self {
        case .primary: return "Primär-URL (Lokal)"
        case .external: return "Externe URL (Remote)"
        }
    }
}

/// Normiert Bild-Cache-Schlüssel der externen URL auf die kanonische Primär-URL,
/// sodass der 2-GB-Platten- und 500-MB-Speichercache beim Wechsel zwischen Heimnetz
/// und Unterwegs ohne erneuten Download zu 100 % weitertrifft.
final class ImmichImageCacheKeyDelegate: ImagePipelineDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var primaryURL: URL?
    private var externalURL: URL?

    init(primaryURL: URL? = nil, externalURL: URL? = nil) {
        self.primaryURL = primaryURL
        self.externalURL = externalURL
    }

    func updateEndpoints(primary: URL?, external: URL?) {
        lock.lock()
        self.primaryURL = primary
        self.externalURL = (external == primary) ? nil : external
        lock.unlock()
    }

    func canonicalCacheKey(for url: URL, processorIdentifiers: [String] = []) -> String? {
        lock.lock()
        let primary = primaryURL
        let external = externalURL
        lock.unlock()

        guard let primary, let external,
              let rewritten = ImmichAPIClient.rewriteOrigin(of: url, from: external, to: primary) else {
            return nil
        }
        if processorIdentifiers.isEmpty {
            return rewritten.absoluteString
        }
        return rewritten.absoluteString + processorIdentifiers.joined()
    }

    func cacheKey(for request: ImageRequest, pipeline: ImagePipeline) -> String? {
        guard let url = request.url else { return nil }
        return canonicalCacheKey(for: url, processorIdentifiers: request.processors.map(\.identifier))
    }
}

@Observable
@MainActor
final class ConnectionManager {
    var state: ConnectionState = .disconnected
    var apiClient: ImmichAPIClient?
    var imagePipeline: ImagePipeline?
    /// Aktive Route (`Lokal` vs. `Remote`), relevant sobald eine externe Fallback-URL hinterlegt ist.
    private(set) var activeRoute: ServerRouteKind = .primary
    private let cacheKeyDelegate = ImmichImageCacheKeyDelegate()
    private var routeProbeTask: Task<Void, Never>?
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
    /// Kaltstart mit gespeicherten Zugangsdaten und Cache: sofort `.offline` zeigen
    /// und im Hintergrund verbinden, statt bis zur Frist auf „Verbinde…“ zu stehen.
    var sofortOfflineBeimKaltstart = false
    /// Wahr, solange die erste Hintergrund-Verbindungsprüfung nach einem optimistischen
    /// Kaltstart noch läuft — unterdrückt das kurzzeitige Aufblitzen des Offline-Banners,
    /// wenn der Server erreichbar ist.
    private(set) var prueftKaltstartVerbindung = false
    /// Aus `.offline` von selbst wieder verbinden: mit wachsenden Pausen
    /// (``wiederverbindenPause(versuch:)``) und bei jeder Pfadänderung.
    var wiederholtVerbindenWennOffline = false
    private var wiederverbindenTask: Task<Void, Never>?
    private var verbindetAutomatisch = false
    /// Basis aller Clients, die `connect` anlegt. Injizierbar für Tests.
    var sitzungsKonfiguration: URLSessionConfiguration = .default
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

    var externalServerURL: String {
        KeychainStore.read(key: "externalServerURL") ?? ""
    }

    var activeServerURL: String {
        apiClient?.baseURL.absoluteString ?? serverURL
    }

    var hasDualURLs: Bool {
        guard let primary = Self.normalizeServerURL(serverURL),
              let external = Self.normalizeServerURL(externalServerURL) else {
            return false
        }
        return primary != external
    }

    /// Speichert (oder löscht bei leerem String) die optionale externe Fallback-URL
    /// und aktualisiert den kanonischen Bild-Cache-Delegaten.
    func saveExternalServerURL(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            KeychainStore.delete(key: "externalServerURL")
        } else if let normalized = Self.normalizeServerURL(trimmed) {
            KeychainStore.save(key: "externalServerURL", value: normalized.absoluteString)
        } else {
            KeychainStore.save(key: "externalServerURL", value: trimmed)
        }
        cacheKeyDelegate.updateEndpoints(
            primary: Self.normalizeServerURL(serverURL),
            external: Self.normalizeServerURL(externalServerURL)
        )
    }

    nonisolated static func normalizeServerURL(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") {
            s = "http://\(s)"
        }
        while s.hasSuffix("/") && s.count > 8 {
            s.removeLast()
        }
        guard let url = URL(string: s), let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    /// Ermittelt parallel die schnellste erreichbare Route:
    /// - Antwortet die Primär-URL (`Lokal`) zuerst, gewinnt sie sofort.
    /// - Antwortet die externe URL zuerst, erhält `Lokal` noch ein kurzes Vorzugsfenster
    ///   (`lanPreferenceGrace`, Standard 150 ms), damit im Heimnetz 10-GbE-LAN Vorrang vor
    ///   Hairpin-Proxy/Tailscale behält — unterwegs fällt die Entscheidung trotzdem in ~200 ms
    ///   statt auf den vollen LAN-Timeout zu warten.
    nonisolated static func chooseBestRoute(
        primaryURL: URL,
        externalURL: URL?,
        lanPreferenceGrace: Duration = .milliseconds(150),
        ping: @Sendable @escaping (URL, ServerRouteKind) async -> Bool
    ) async -> (url: URL, route: ServerRouteKind)? {
        guard let extURL = externalURL, extURL != primaryURL else {
            return await ping(primaryURL, .primary) ? (primaryURL, .primary) : nil
        }

        return await withTaskGroup(of: (ServerRouteKind?, Bool).self) { group in
            group.addTask { (.primary, await ping(primaryURL, .primary)) }
            group.addTask { (.external, await ping(extURL, .external)) }

            var primaryResult: Bool?
            var externalResult: Bool?

            while let (kind, ok) = await group.next() {
                guard let kind else {
                    // Grace-Timer abgelaufen, während `externalResult == true` bereits vorlag
                    if externalResult == true {
                        group.cancelAll()
                        return (extURL, .external)
                    }
                    continue
                }
                switch kind {
                case .primary:
                    primaryResult = ok
                    if ok {
                        group.cancelAll()
                        return (primaryURL, .primary)
                    }
                    if externalResult == true {
                        group.cancelAll()
                        return (extURL, .external)
                    }
                case .external:
                    externalResult = ok
                    if ok {
                        if primaryResult == false {
                            group.cancelAll()
                            return (extURL, .external)
                        }
                        // Kurzes Vorzugsfenster für LAN direkt in derselben TaskGroup planen
                        group.addTask {
                            try? await Task.sleep(for: lanPreferenceGrace)
                            return (nil, false)
                        }
                    }
                }
            }
            return nil
        }
    }

    init() {
        // Load credentials synchronously during init so isConfigured is correct
        // before ContentView.body is ever evaluated by SwiftUI.
        // (applicationDidFinishLaunching fires after the first SwiftUI render pass,
        //  so relying on it alone causes a race where isConfigured reads an empty dict.)
        KeychainStore.loadAll()
        isConfigured = KeychainStore.read(key: "serverURL") != nil
            && KeychainStore.read(key: "apiKey") != nil
        cacheKeyDelegate.updateEndpoints(
            primary: Self.normalizeServerURL(KeychainStore.read(key: "serverURL") ?? ""),
            external: Self.normalizeServerURL(KeychainStore.read(key: "externalServerURL") ?? "")
        )
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

    /// Ob die aktuelle Netzwerkverbindung als teuer (z. B. persönlicher Hotspot)
    /// oder im Datensparmodus (`isConstrained`) eingestuft ist.
    var isExpensiveOrConstrainedNetwork: Bool {
        guard let path = networkMonitor?.currentPath else { return false }
        return path.isExpensive || path.isConstrained
    }

    // MARK: - Connect

    /// Bereitet schon vor dem ersten SwiftUI-Renderpass den optimistischen lokalen
    /// Browsing-Zustand vor, sofern Zugangsdaten und lokaler Cache vorhanden sind.
    func vorbereiteKaltstartMitCache() {
        guard sofortOfflineBeimKaltstart, isConfigured, !state.canBrowse, hasCachedData() else { return }
        prueftKaltstartVerbindung = true
        goOfflineIfCached()
    }

    func connect(
        serverURL: String,
        externalServerURL: String? = nil,
        apiKey: String,
        email: String? = nil,
        password: String? = nil,
        isAutoReconnect: Bool = false
    ) async {
        // Sichtbar „Verbinde…“ nur beim manuellen Verbinden und beim Kaltstart ohne
        // Inhalt. Ein automatisches Wiederverbinden aus `.offline`/`.connected` lässt
        // den Zustand stehen, bis Erfolg oder Fehler feststeht — sonst risse die
        // Wurzelansicht alle NavigationStacks und Player ab (`canBrowse` kurz falsch).
        if !isAutoReconnect {
            state = .connecting
        } else if !state.canBrowse {
            if sofortOfflineBeimKaltstart, hasCachedData() {
                prueftKaltstartVerbindung = true
                goOfflineIfCached()
            } else {
                state = .connecting
            }
        }
        defer { prueftKaltstartVerbindung = false }
        AppLogger.connection.debug("Connecting to: \(serverURL)")

        // Normalize URL
        var urlString = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !urlString.hasPrefix("http") {
            urlString = "http://\(urlString)"
        }
        if urlString.hasSuffix("/") {
            urlString = String(urlString.dropLast())
        }

        guard let primaryURL = URL(string: urlString) else {
            state = .error("Invalid URL: \(urlString)")
            return
        }

        let rawExternal = externalServerURL ?? KeychainStore.read(key: "externalServerURL")
        let normalizedExternal: URL? = {
            guard let rawExternal, !rawExternal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let candidate = Self.normalizeServerURL(rawExternal),
                  candidate != primaryURL else { return nil }
            return candidate
        }()
        cacheKeyDelegate.updateEndpoints(primary: primaryURL, external: normalizedExternal)

        let sessionCfg = sitzungsKonfiguration

        do {
            let activeURL: URL
            let chosenRoute: ServerRouteKind
            let pruefer: ImmichAPIClient

            if let extURL = normalizedExternal {
                // Dual-URL Race-Ping: schneller Timeout auf Lokal (1,8 s), reguläre Kurzfrist auf Remote (6 s)
                let winner = await Self.chooseBestRoute(
                    primaryURL: primaryURL,
                    externalURL: extURL
                ) { candidateURL, routeKind in
                    let timeout: TimeInterval = (routeKind == .primary) ? 1.8 : ImmichAPIClient.kurzeFrist
                    let probe = ImmichAPIClient(
                        baseURL: candidateURL,
                        canonicalBaseURL: primaryURL,
                        apiKey: apiKey,
                        sessionConfiguration: sessionCfg,
                        anfrageFrist: timeout
                    )
                    return (try? await probe.ping()) == true
                }

                if let winner {
                    activeURL = winner.url
                    chosenRoute = winner.route
                    pruefer = ImmichAPIClient(
                        baseURL: activeURL,
                        canonicalBaseURL: primaryURL,
                        apiKey: apiKey,
                        sessionConfiguration: sessionCfg,
                        anfrageFrist: ImmichAPIClient.kurzeFrist
                    )
                    AppLogger.connection.info("Dual-URL: Route \(chosenRoute.kurzName) gewählt (\(activeURL.absoluteString))")
                } else if isAutoReconnect {
                    bleibOfflineOderGehOffline()
                    return
                } else {
                    // Beide Routen still — einmal regulär gegen Primär-URL prüfen, um klaren Fehlertext zu liefern
                    let diagClient = ImmichAPIClient(
                        baseURL: primaryURL,
                        canonicalBaseURL: primaryURL,
                        apiKey: apiKey,
                        sessionConfiguration: sessionCfg,
                        anfrageFrist: 2.5
                    )
                    do {
                        let pong = try await diagClient.ping()
                        if !pong {
                            state = .error("Weder Lokal (\(primaryURL.host ?? urlString)) noch Externe URL antwortet")
                            return
                        }
                        activeURL = primaryURL
                        chosenRoute = .primary
                        pruefer = diagClient
                    } catch is DecodingError {
                        throw APIError.keinImmich
                    }
                }
            } else {
                // Klassischer Einzel-URL-Pfad
                activeURL = primaryURL
                chosenRoute = .primary
                pruefer = ImmichAPIClient(
                    baseURL: primaryURL,
                    canonicalBaseURL: primaryURL,
                    apiKey: apiKey,
                    sessionConfiguration: sessionCfg,
                    anfrageFrist: ImmichAPIClient.kurzeFrist
                )
                let pong: Bool
                do {
                    pong = try await pingWithRetry(client: pruefer)
                } catch is DecodingError {
                    // 200 mit HTML (Proxy-Startseite, falscher Dienst): kein Immich.
                    throw APIError.keinImmich
                }
                AppLogger.connection.info("Ping result: \(pong)")
                guard pong else {
                    if isAutoReconnect { bleibOfflineOderGehOffline() }
                    else { state = .error("Server did not respond to ping") }
                    return
                }
            }

            let client: ImmichAPIClient
            if let existing = self.apiClient, existing.apiKey == apiKey {
                existing.updateBaseURL(activeURL, canonicalURL: primaryURL)
                client = existing
            } else {
                client = ImmichAPIClient(
                    baseURL: activeURL,
                    canonicalBaseURL: primaryURL,
                    apiKey: apiKey,
                    sessionConfiguration: sessionCfg
                )
            }

            // Version + API-Key-Gültigkeit parallel prüfen statt nacheinander.
            async let versionTask = pruefer.getServerVersion()
            async let keyTask: Void = pruefer.pruefeSchluessel()
            let version: String
            do {
                version = try await versionTask
            } catch is DecodingError {
                throw APIError.keinImmich
            }
            // Vor dem Speichern: Ping und Version gehen auch ohne gültigen Schlüssel.
            try await keyTask

            // Rechte des Keys + ggf. Session-Token-Validierung parallel ausführen.
            let savedToken = KeychainStore.read(key: "sessionToken")
            let shouldValidateSession = (email != nil && !(email?.isEmpty ?? true) && password != nil && !(password?.isEmpty ?? true) && savedToken != nil)

            async let gemeldeteRechteTask: Set<String>? = try? await client.eigeneKeyRechte()
            async let validatedSessionResult: Result<String?, Error>? = shouldValidateSession
                ? await Result { try await ImmichAPIClient.validateSessionToken(baseURL: activeURL, sessionToken: savedToken!) }
                : nil

            var rechte = KeyRechte(abgelehnt: KeyRechteSpeicher.ladeAbgelehnt(apiKey: apiKey))
            if let gemeldet = await gemeldeteRechteTask {
                rechte.uebernimmMeldung(gemeldet)
                KeyRechteSpeicher.speichereAbgelehnt(rechte.abgelehnt, apiKey: apiKey)
            }
            keyRechte = rechte

            // Kontowechsel erkennen, bevor der neue Client die Oberfläche erreicht.
            // Nur wenn jemand aufräumen will (iOS) — der Mac spart sich die Anfrage.
            if let beiKontoWechsel {
                let konto = await client.kontoKennung()
                let defaults = AppEnvironment.defaults
                let zugang = KontoWechsel.zugang(serverURL: urlString, apiKey: apiKey)
                if KontoWechsel.istWechsel(bisher: KontoWechsel.bisher(defaults), neu: konto,
                                           bisherZugang: KontoWechsel.bisherZugang(defaults), neuZugang: zugang) {
                    AppLogger.connection.info("Anderes Konto angemeldet — lokale Daten des vorigen werden geleert")
                    await beiKontoWechsel()
                    NotificationCenter.default.post(name: .kontoGewechselt, object: nil)
                    // Unbekanntes neues Konto: die alte Kennung gehört nicht mehr zu
                    // diesen Daten — sonst meldete der nächste Start erneut „Wechsel“.
                    if konto == nil { defaults.removeObject(forKey: KontoWechsel.schluessel) }
                }
                KontoWechsel.merke(konto, in: defaults)
                KontoWechsel.merkeZugang(zugang, in: defaults)
            }

            // Save credentials and update observable state
            KeychainStore.save(key: "serverURL", value: urlString)
            if let externalServerURL {
                saveExternalServerURL(externalServerURL)
            }
            KeychainStore.save(key: "apiKey", value: apiKey)
            refreshConfiguredState()

            // Attempt session login for Sync Stream API (optional)
            let sessionValidation = await validatedSessionResult
            if let email, !email.isEmpty, let password, !password.isEmpty {
                // Die Sync-Stream-Checkpoints hängen serverseitig an der Session.
                // Ein frischer Login bei jedem Verbinden würde eine neue Session
                // anlegen und damit bei jedem App-Start einen kompletten
                // Stream-Replay (~155k Zeilen, ~80 s) erzwingen. Deshalb zuerst
                // den gespeicherten Token validieren und nur bei 401 neu einloggen.
                var reusedToken: String?
                if let sessionValidation {
                    switch sessionValidation {
                    case .success(let tokenEmail):
                        if let tokenEmail {
                            if tokenEmail.caseInsensitiveCompare(email) == .orderedSame {
                                reusedToken = savedToken
                            } else {
                                AppLogger.connection.info("Saved session token belongs to \(tokenEmail), logging in as \(email)")
                            }
                        } else {
                            AppLogger.connection.info("Saved session token rejected by server (401) — fresh login")
                        }
                    case .failure(let error):
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
                            baseURL: activeURL, email: email, password: password
                        )
                        // Verwaiste Session des alten Tokens serverseitig aufräumen,
                        // damit sich Sessions + Checkpoints nicht ansammeln.
                        if let savedToken, savedToken != loginResponse.accessToken {
                            await ImmichAPIClient.logout(baseURL: activeURL, sessionToken: savedToken)
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
                self.sessionToken = savedToken
                if sessionToken != nil {
                    AppLogger.connection.debug("Restored session token from saved credentials")
                }
            }

            // Set up image pipeline with API key header (wiederverwenden, wenn bereits im
            // optimistischen Kaltstart mit identischen Zugangsdaten aufgebaut).
            let previousRoute = self.activeRoute
            if self.imagePipeline == nil || self.apiClient !== client {
                self.imagePipeline = Self.makeImagePipeline(
                    apiKey: apiKey,
                    delegate: cacheKeyDelegate,
                    cacheSetup: { thumb in
                        self.thumbnailCache = thumb
                    }
                )
                applySavedCacheLimits()
            }
            self.apiClient = client
            self.activeRoute = chosenRoute
            self.state = .connected(version: version)
            stoppeWiederverbinden()
            if previousRoute != chosenRoute {
                NotificationCenter.default.post(name: .serverRouteDidChange, object: nil)
            }
            AppLogger.connection.info("Connected to \(activeURL.absoluteString) [\(chosenRoute.kurzName)] (v\(version))")

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
                bleibOfflineOderGehOffline()
            } else if let apiFehler = error as? APIError, let text = apiFehler.errorDescription {
                state = .error(text)
            } else {
                let nsErr = error as NSError
                AppLogger.connection.error("Connection error: domain=\(nsErr.domain) code=\(nsErr.code) msg=\(nsErr.localizedDescription)")
                state = .error("Connection failed: \(error.localizedDescription)")
            }
        }
    }

    /// Automatisches Wiederverbinden gescheitert: Ist die App schon offline, bleibt
    /// alles, wie es ist (kein neuer Client, keine neue Pipeline — die Ansichten
    /// hängen daran). Sonst in den Offline-Modus, falls es Daten gibt.
    private func bleibOfflineOderGehOffline() {
        if state.isOffline { return }
        goOfflineIfCached()
    }

    /// Wechselt in den Offline-Modus wenn ein initialer Sync bereits abgeschlossen wurde.
    /// Baut dabei einen apiClient aus den gespeicherten Credentials (kein Ping), damit
    /// MainView (das apiClient: nicht-optional erwartet) funktioniert.
    private func goOfflineIfCached() {
        guard let rawURL = KeychainStore.read(key: "serverURL"),
              let apiKey = KeychainStore.read(key: "apiKey") else {
            state = .disconnected
            return
        }
        var urlString = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !urlString.hasPrefix("http") {
            urlString = "http://\(urlString)"
        }
        if urlString.hasSuffix("/") {
            urlString = String(urlString.dropLast())
        }
        guard let url = URL(string: urlString) else {
            state = .disconnected
            return
        }

        // Prüfe ob je ein initialer Sync stattgefunden hat
        let hasCache = hasCachedData()
        guard hasCache else {
            // Noch nie verbunden gewesen — Login-Screen zeigen. Den Netzmonitor
            // trotzdem starten: Kommt das Netz zurück, verbindet er selbst neu,
            // statt dass der Nutzer „Erneut versuchen“ finden muss.
            state = .disconnected
            startNetworkMonitoring()
            return
        }

        // apiClient ohne Ping aufbauen, damit das lokale Raster ohne Netzwerkwartezeit rendert
        let extURL = Self.normalizeServerURL(KeychainStore.read(key: "externalServerURL") ?? "")
        cacheKeyDelegate.updateEndpoints(primary: url, external: extURL)
        let client = ImmichAPIClient(baseURL: url, canonicalBaseURL: url, apiKey: apiKey, sessionConfiguration: sitzungsKonfiguration)
        self.imagePipeline = Self.makeImagePipeline(
            apiKey: apiKey,
            delegate: cacheKeyDelegate,
            cacheSetup: { thumb in
                self.thumbnailCache = thumb
            }
        )
        self.apiClient = client
        self.sessionToken = KeychainStore.read(key: "sessionToken")
        self.state = .offline
        applySavedCacheLimits()
        AppLogger.connection.info("Kaltstart mit lokalem Cache — zeige Raster sofort")
        startNetworkMonitoring()
        if !prueftKaltstartVerbindung && !verbindetAutomatisch {
            starteWiederverbinden()
        }
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
        // Wiederholung, Pfadwechsel und der Knopf können sich überschneiden: Zwei
        // `connect` zugleich bauten zwei Clients und Pipelines.
        guard !verbindetAutomatisch else { return }
        verbindetAutomatisch = true
        defer { verbindetAutomatisch = false }
        let email = KeychainStore.read(key: "email")
        let password = KeychainStore.read(key: "password")
        await connect(serverURL: urlString, apiKey: apiKey, email: email, password: password, isAutoReconnect: true)
        // Gescheitert (etwa „Erneut verbinden“ ohne Server): weiter versuchen.
        if state.isOffline, wiederverbindenTask == nil { starteWiederverbinden() }
    }

    // MARK: - Wiederverbinden aus dem Offline-Modus

    /// Pause vor dem `versuch`-ten automatischen Wiederverbinden (ab 0): 5 s, 15 s,
    /// 30 s, danach jede Minute.
    nonisolated static func wiederverbindenPause(versuch: Int) -> Duration {
        let stufen: [Duration] = [.seconds(5), .seconds(15), .seconds(30)]
        return versuch < stufen.count ? stufen[versuch] : .seconds(60)
    }

    /// Versucht aus `.offline` wiederholt neu zu verbinden, solange das Netz nutzbar
    /// ist. Vorher geschah das genau einmal, wenn das Netz wiederkam: Nach dem
    /// Flugmodus war WLAN schneller da als der Tailscale-Tunnel, der eine Versuch
    /// scheiterte, und die App blieb „Offline“ (Gerätebefund 26.10.2026).
    /// - Parameter sofort: ohne erste Pause (Rückkehr in den Vordergrund, Pfadwechsel).
    func starteWiederverbinden(sofort: Bool = false) {
        guard wiederholtVerbindenWennOffline, state.isOffline else { return }
        wiederverbindenTask?.cancel()
        wiederverbindenTask = Task { @MainActor [weak self] in
            var versuch = 0
            while !Task.isCancelled {
                if !(sofort && versuch == 0) {
                    try? await Task.sleep(for: Self.wiederverbindenPause(versuch: sofort ? versuch - 1 : versuch))
                }
                guard !Task.isCancelled, let self else { return }
                guard self.state.isOffline else { self.wiederverbindenTask = nil; return }
                if self.isNetworkAvailable {
                    AppLogger.connection.info("Offline — Wiederverbinden, Versuch \(versuch + 1)")
                    // Eigener Task: Ein Neustart der Schleife (Pfadwechsel) bräche sonst
                    // ein laufendes `connect` mitten in den Anfragen ab.
                    await Task { await self.reconnect() }.value
                    if !self.state.isOffline { return }
                }
                versuch += 1
            }
        }
    }

    private func stoppeWiederverbinden() {
        wiederverbindenTask?.cancel()
        wiederverbindenTask = nil
    }

    func disconnect() {
        // Zuerst: App-weite Hintergrundläufe anhalten, bevor ihnen der Schlüssel
        // unter den Händen wegbricht. Die Nachricht geht synchron raus.
        NotificationCenter.default.post(name: .connectionDidDisconnect, object: nil)
        KeychainStore.deleteAll()
        KeyRechteSpeicher.vergiss()
        keyRechte = KeyRechte()
        routeProbeTask?.cancel()
        routeProbeTask = nil
        apiClient = nil
        imagePipeline = nil
        thumbnailCache = nil
        activeRoute = .primary
        cacheKeyDelegate.updateEndpoints(primary: nil, external: nil)
        isLockedFolderUnlocked = false
        stopNetworkMonitoring()
        stoppeWiederverbinden()
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
            starteWiederverbinden()
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
                self.isNetworkAvailable = Self.netzNutzbar(path)

                if !self.isNetworkAvailable && wasAvailable {
                    // Network dropped
                    self.goOffline()
                    AppLogger.connection.info("Network lost — switching to offline mode")
                } else if self.isNetworkAvailable && !wasAvailable {
                    // Network returned — try to reconnect
                    AppLogger.connection.info("Network returned — attempting reconnect")
                    await self.reconnect()
                    self.starteWiederverbinden()
                } else if self.isNetworkAvailable, self.state.isOffline {
                    // Anderer Pfad bei gleicher Verfügbarkeit, etwa Tailscale an:
                    // Der Server kann jetzt erreichbar sein.
                    self.starteWiederverbinden(sofort: true)
                } else if self.isNetworkAvailable, self.state.isConnected, self.hasDualURLs {
                    // Pfadwechsel bei bestehender Verbindung (z. B. Rückkehr ins Heim-WLAN
                    // oder Wechsel auf Hotspot): im Hintergrund prüfen, ob Lokal/Remote jetzt
                    // besser erreichbar ist.
                    self.planeHintergrundRoutenPruefung()
                }
            }
        }
        monitor.start(queue: monitorQueue)
        self.networkMonitor = monitor
    }

    /// Entprellte Hintergrund-Routenprüfung bei Netzwerkpfadwechseln (`NWPathMonitor`),
    /// damit kurz aufeinanderfolgende Interface-Events nur einen einzigen Race-Ping auslösen.
    private func planeHintergrundRoutenPruefung() {
        routeProbeTask?.cancel()
        routeProbeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled, let self else { return }
            await self.pruefeOptimaleRoute()
        }
    }

    /// Prüft im laufenden Betrieb (ohne `state` auf `.connecting` zu setzen), ob zwischen
    /// Primär-URL (`Lokal`) und externer URL (`Remote`) gewechselt werden sollte.
    @discardableResult
    func pruefeOptimaleRoute() async -> ServerRouteKind? {
        guard let primaryURL = Self.normalizeServerURL(serverURL),
              let apiKey = KeychainStore.read(key: "apiKey") else {
            return nil
        }
        let extURL = Self.normalizeServerURL(externalServerURL)
        cacheKeyDelegate.updateEndpoints(primary: primaryURL, external: extURL)

        let sessionCfg = sitzungsKonfiguration
        let winner = await Self.chooseBestRoute(
            primaryURL: primaryURL,
            externalURL: extURL
        ) { candidateURL, routeKind in
            let timeout: TimeInterval = (routeKind == .primary) ? 1.5 : 4.0
            let probe = ImmichAPIClient(
                baseURL: candidateURL,
                canonicalBaseURL: primaryURL,
                apiKey: apiKey,
                sessionConfiguration: sessionCfg,
                anfrageFrist: timeout
            )
            return (try? await probe.ping()) == true
        }

        guard let winner else {
            if state.isConnected {
                goOffline()
            }
            return nil
        }

        if state.isOffline {
            await reconnect()
            return activeRoute
        }

        let changed = (winner.route != activeRoute) || (apiClient?.baseURL != winner.url)
        apiClient?.updateBaseURL(winner.url, canonicalURL: primaryURL)
        activeRoute = winner.route
        if changed {
            AppLogger.connection.info("Dual-URL Roaming: gewechselt auf \(winner.route.kurzName) (\(winner.url.absoluteString))")
            NotificationCenter.default.post(name: .serverRouteDidChange, object: nil)
        }
        return winner.route
    }

    /// Ob der Pfad wirklich ins Netz führt. **`.satisfied` allein reicht nicht:**
    /// Im Flugmodus bleibt die Tunnel-Schnittstelle eines VPN (Tailscale, `utun`)
    /// bestehen, und der Pfad gilt weiter als erfüllt — die App blieb „Verbunden“,
    /// während jede Anfrage scheiterte (Gerätebefund 26.10.2026). Darum zählt nur
    /// ein Pfad über WLAN, Mobilfunk oder Kabel; ein VPN darüber meldet diese
    /// Schnittstelle mit (`usesInterfaceType` sieht durch den Tunnel).
    nonisolated static func netzNutzbar(_ path: NWPath) -> Bool {
        netzNutzbar(
            erfuellt: path.status == .satisfied,
            physisch: [.wifi, .cellular, .wiredEthernet].contains { path.usesInterfaceType($0) }
        )
    }

    nonisolated static func netzNutzbar(erfuellt: Bool, physisch: Bool) -> Bool {
        erfuellt && physisch
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
        delegate: (any ImagePipelineDelegate)? = nil,
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
        #if os(iOS)
        // iOS: 460 MB Footprint schon bei 133 Assets gemessen — die Einzelbild-
        // Vorschauen (1440 px, dekodiert ~8–11 MB je Stück) landen im selben
        // Speicher-Cache. 160 MB halten weiter mehrere Bildschirme Thumbnails;
        // Nukes Eintragsgrenze (10 % davon) lässt einzelne Riesenbilder draußen.
        imageCache.costLimit = 160 * 1024 * 1024
        #else
        imageCache.costLimit = 500 * 1024 * 1024
        #endif
        config.imageCache = imageCache

        // Disk cache: single cache for both thumbnails and full-size images
        var thumbCache: DataCache?
        if let dataCache = try? DataCache(name: "com.immichmac.thumbnails") {
            dataCache.sizeLimit = 2 * 1024 * 1024 * 1024
            config.dataCache = dataCache
            thumbCache = dataCache
        }

        cacheSetup(thumbCache)

        return ImagePipeline(configuration: config, delegate: delegate)
    }

    // MARK: - Cache Management (for Settings UI)

    var thumbnailCacheUsageString: String {
        guard let cache = thumbnailCache else { return "N/A" }
        return ByteCountFormatter.string(fromByteCount: Int64(cache.totalSize), countStyle: .file)
    }

    /// Beide Nuke-Caches, festgehalten vor `disconnect()` (das sie auf `nil` setzt),
    /// damit ``AccountDataPurge`` sie nach dem Abmelden noch räumen kann.
    var bildCaches: (pipeline: ImagePipeline?, platte: DataCache?) {
        (imagePipeline, thumbnailCache)
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
