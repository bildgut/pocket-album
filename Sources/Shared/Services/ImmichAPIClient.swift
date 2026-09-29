import Foundation

final class ImmichAPIClient {
    let baseURL: URL
    let apiKey: String
    private let session: URLSession
    /// Session OHNE x-api-key Default-Header für Endpoints mit Session-Auth
    /// (z. B. ``unlockSession(password:sessionToken:)``) — Immich lehnt diese
    /// Calls mit 400 ab, wenn ein API-Key mitgesendet wird.
    private let sessionAuthSession: URLSession

    /// - Parameter sessionConfiguration: Basis-Configuration für alle URLSessions
    ///   des Clients. Injizierbar für Tests (z. B. mit `protocolClasses`).
    init(
        baseURL: URL,
        apiKey: String,
        sessionConfiguration: URLSessionConfiguration = .default,
        editedAssets: EditedAssetsStore = .shared
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.editedAssets = editedAssets
        self.assetBasePath = baseURL.appending(path: "api/assets")

        // URLSession kopiert die Configuration beim Erzeugen — die Session ohne
        // Header zuerst anlegen, bevor die Kopie für die Auth-Session mutiert wird.
        self.sessionAuthSession = URLSession.mitSichererWeiterleitung(sessionConfiguration)

        let config = sessionConfiguration.copy() as! URLSessionConfiguration
        config.httpAdditionalHeaders = [
            "x-api-key": apiKey,
            "Accept": "application/json",
        ]
        config.timeoutIntervalForRequest = 30
        // HTTP/2 multiplexing: URLSession enables it automatically when the server
        // supports it. HTTP/1.1 pipelining (`httpShouldUsePipelining`) is ignored by
        // the modern loader, so it is no longer set.
        self.session = URLSession.mitSichererWeiterleitung(config)
    }

    /// `URLSession` hält sich selbst, bis sie invalidiert wird — ohne das blieben
    /// beide Sessions jedes freigegebenen Clients liegen (im iOS-Onboarding entsteht
    /// je Tastendruck einer). `finishTasks…` lässt laufende Anfragen zu Ende laufen.
    deinit {
        session.finishTasksAndInvalidate()
        sessionAuthSession.finishTasksAndInvalidate()
    }

    // Cached base paths for URL construction (avoids per-call URLComponents parsing)
    private let assetBasePath: URL

    /// Entscheidet je Asset, ob die Bild-URLs die bearbeitete Fassung anfordern.
    /// Siehe ``EditedAssetsStore`` — ohne `edited=true` liefert Immich dauerhaft das
    /// unbearbeitete Bild, auch Stunden nach einer Drehung.
    private let editedAssets: EditedAssetsStore

    // Shared decoder/encoder — JSONDecoder/JSONEncoder are expensive to allocate.
    // Reusing one instance per client avoids 36+ allocations per sync cycle.
    private let jsonDecoder = JSONDecoder()
    private let jsonEncoder = JSONEncoder()

    // MARK: - Server

    /// Authenticate with email/password to obtain a session token.
    /// Required for Sync Stream API endpoints (which reject API keys).
    static func login(
        baseURL: URL, email: String, password: String,
        sessionConfiguration: URLSessionConfiguration = .default
    ) async throws -> LoginResponse {
        let url = baseURL.appending(path: "api/auth/login")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = ["email": email, "password": password]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let einweg = URLSession.mitSichererWeiterleitung(sessionConfiguration)
        defer { einweg.finishTasksAndInvalidate() }
        let (data, response) = try await einweg.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard httpResponse.statusCode == 201 || httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 401 {
                throw APIError.loginFailed("Incorrect email or password")
            }
            throw APIError.httpError(httpResponse.statusCode)
        }

        return try JSONDecoder().decode(LoginResponse.self, from: data)
    }

    /// Prüft einen gespeicherten Session-Token via GET /api/users/me.
    ///
    /// Die Sync-Stream-Checkpoints hängen serverseitig an der Session — ein
    /// frischer Login bei jedem Verbinden würde sie verwerfen und einen
    /// kompletten Stream-Replay erzwingen. Deshalb: Token wiederverwenden,
    /// solange der Server ihn akzeptiert.
    ///
    /// - Returns: Die E-Mail des Kontos, dem der Token gehört (zum Abgleich
    ///   mit den gespeicherten Credentials), oder `nil` bei 401/403
    ///   (Token ungültig/abgelaufen → Neu-Login nötig).
    /// - Throws: Bei Netzwerk-/Serverfehlern (kein Urteil über den Token möglich).
    static func validateSessionToken(
        baseURL: URL, sessionToken: String,
        sessionConfiguration: URLSessionConfiguration = .default
    ) async throws -> String? {
        let url = baseURL.appending(path: "api/users/me")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let einweg = URLSession.mitSichererWeiterleitung(sessionConfiguration)
        defer { einweg.finishTasksAndInvalidate() }
        let (data, response) = try await einweg.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            return nil
        }
        guard httpResponse.statusCode == 200 else {
            throw APIError.httpError(httpResponse.statusCode)
        }

        struct UserMeResponse: Decodable { let email: String }
        return try JSONDecoder().decode(UserMeResponse.self, from: data).email
    }

    /// Beendet eine Server-Session (POST /api/auth/logout) — Best Effort.
    /// Wird beim Neu-Login aufgerufen, damit sich verwaiste Sessions
    /// (samt ihrer Sync-Stream-Checkpoints) nicht auf dem Server ansammeln.
    static func logout(
        baseURL: URL, sessionToken: String,
        sessionConfiguration: URLSessionConfiguration = .default
    ) async {
        let url = baseURL.appending(path: "api/auth/logout")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        do {
            let einweg = URLSession.mitSichererWeiterleitung(sessionConfiguration)
            defer { einweg.finishTasksAndInvalidate() }
            let (_, response) = try await einweg.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            AppLogger.api.debug("[logout] Alte Session beendet (status=\(status))")
        } catch {
            AppLogger.api.debug("[logout] Best-Effort-Logout fehlgeschlagen (ignoriert): \(error)")
        }
    }

    /// Unlock the "Locked Folder" for the current session.
    /// - Parameter sessionToken: Bearer token aus dem Login (wird für Session-Auth benötigt).
    ///   Wenn nil, fällt die Funktion auf den API-Key zurück.
    func unlockSession(password: String, sessionToken: String?) async throws -> Bool {
        let url = baseURL.appending(path: "api/auth/session/unlock")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        // KRITISCH: Dieser Endpoint braucht Session-Auth, KEIN API-Key.
        // Wir nutzen eine eigene URLSession OHNE den x-api-key Default-Header,
        // sonst lehnt Immich den Call mit 400 ab.
        if let token = sessionToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            AppLogger.api.info("[unlockSession] Using Bearer session token (length=\(token.count))")
        } else {
            AppLogger.api.error("[unlockSession] Kein sessionToken verfügbar – dieser Endpoint benötigt E-Mail/Passwort-Login")
            throw APIError.httpError(401)
        }

        let body: [String: String] = ["pinCode": password]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        AppLogger.api.debug("[unlockSession] Sending body with pinCode (length=\(password.count))")

        // Session ohne Default-Headers (kein x-api-key!) — aus der injizierten
        // Configuration erzeugt, damit Tests sie mocken können.
        let (data, response) = try await sessionAuthSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        AppLogger.api.info("[unlockSession] status=\(httpResponse.statusCode), body=\(String(data: data, encoding: .utf8) ?? "<binary>")")

        guard httpResponse.statusCode == 200 || httpResponse.statusCode == 201 || httpResponse.statusCode == 204 else {
            if httpResponse.statusCode == 400 {
                // Immich returns 400 when the password is wrong
                return false
            }
            if httpResponse.statusCode == 401 {
                AppLogger.api.error("[unlockSession] 401 Unauthorized – sessionToken ungültig oder abgelaufen")
                throw APIError.httpError(401)
            }
            throw APIError.httpError(httpResponse.statusCode)
        }

        return true
    }

    /// Alle Assets des gesperrten Ordners (live, nicht gespeichert).
    /// Setzt eine entsperrte Sitzung voraus (``unlockSession(password:)``) — ohne sie
    /// lehnt der Server jede `visibility`-Bedingung ab, die `locked` treffen könnte.
    func fetchLockedAssets() async throws -> [Asset] {
        var filter = SearchFilter()
        filter.visibility = .equals(.locked)
        filter.trashedAt = .isNull
        return try await searchAllAssets(filter: filter)
    }

    func ping() async throws -> Bool {
        let url = baseURL.appending(path: "api/server/ping")
        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return false
        }
        let ping = try jsonDecoder.decode(ServerPing.self, from: data)
        return ping.res == "pong"
    }

    func getServerAbout() async throws -> ServerAbout {
        let url = baseURL.appending(path: "api/server/about")
        let (data, _) = try await session.data(from: url)
        return try jsonDecoder.decode(ServerAbout.self, from: data)
    }

    func getServerVersion() async throws -> String {
        let url = baseURL.appending(path: "api/server/version")
        let (data, _) = try await session.data(from: url)
        let sv = try jsonDecoder.decode(ServerVersion.self, from: data)
        return "\(sv.major).\(sv.minor).\(sv.patch)"
    }

    /// Prüft den API-Key mit einem Abruf, der ihn wirklich braucht.
    ///
    /// `ping` und `server/version` antworten auch ohne Schlüssel — ein vertippter
    /// oder zu schwach berechtigter Key sah danach "verbunden" aus, und alle Listen
    /// blieben leer. Abgefragt wird die Albumliste, weil `album.read` das eine Recht
    /// ist, ohne das keine Nutzung geht. Nur 401 und 403 zählen als Befund; andere
    /// Fehler sagen nichts über den Schlüssel und melden sich bei den eigentlichen
    /// Abrufen selbst.
    func pruefeSchluessel() async throws {
        let url = baseURL.appending(path: "api/albums")
        let (_, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        switch http.statusCode {
        case 401: throw APIError.apiKeyRejected
        case 403: throw APIError.apiKeyLacksPermission("album.read")
        default: return
        }
    }

    /// Legt mit einer Session (nicht mit einem API-Key) einen neuen API-Key an
    /// (`POST /api/api-keys`) und gibt dessen `secret` zurück — der einzige
    /// Moment, in dem Immich den Schlüssel im Klartext herausgibt.
    static func erstelleApiKey(
        baseURL: URL, sessionToken: String, name: String, rechte: [String],
        sessionConfiguration: URLSessionConfiguration = .default
    ) async throws -> String {
        struct Koerper: Encodable { let name: String; let permissions: [String] }
        struct Antwort: Decodable { let secret: String }
        var request = URLRequest(url: baseURL.appending(path: "api/api-keys"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(Koerper(name: name, permissions: rechte))
        let sitzung = URLSession.mitSichererWeiterleitung(sessionConfiguration)
        defer { sitzung.finishTasksAndInvalidate() }
        let (data, response) = try await sitzung.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...201).contains(status) else { throw APIError.httpError(status) }
        return try JSONDecoder().decode(Antwort.self, from: data).secret
    }

    /// Ob der Server Anmeldung per Passwort erlaubt (`GET /api/server/features`,
    /// ohne Schlüssel erreichbar). `false` bei reinen SSO-Servern.
    func passwortLoginErlaubt() async throws -> Bool {
        struct Antwort: Decodable { let passwordLogin: Bool }
        let (data, _) = try await session.data(from: baseURL.appending(path: "api/server/features"))
        return try jsonDecoder.decode(Antwort.self, from: data).passwordLogin
    }

    /// Die Rechte des eigenen API-Keys (`GET /api/api-keys/me`, verlangt selbst kein
    /// Recht). `["all"]` bei einem Vollzugriffs-Key.
    func eigeneKeyRechte() async throws -> Set<String> {
        struct Antwort: Decodable { let permissions: [String] }
        let url = baseURL.appending(path: "api/api-keys/me")
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return Set(try jsonDecoder.decode(Antwort.self, from: data).permissions)
    }

    // MARK: - Assets

    /// Alles, was in den letzten `lastDays` Tagen hochgeladen wurde, nach Upload-Datum
    /// (`createdAt`) sortiert statt nach Aufnahmedatum.
    func getRecentlyUploadedAssets(lastDays: Int = 30) async throws -> [Asset] {
        let startPeriod = Calendar.current.date(byAdding: .day, value: -lastDays, to: Date())!
        var filter = SearchFilter()
        filter.createdAt = .onOrAfter(startPeriod)
        filter.trashedAt = .isNull
        let assets = try await searchAllAssets(filter: filter, withExif: true)
        return assets.sorted {
            ($0.createdAt ?? $0.fileCreatedAt) > ($1.createdAt ?? $1.fileCreatedAt)
        }
    }

    /// Fetch full asset detail including exifInfo
    func getAssetDetail(id: String) async throws -> Asset {
        let url = baseURL.appending(path: "api/assets/\(id)")
        let (data, _) = try await session.data(from: url)
        return try jsonDecoder.decode(Asset.self, from: data)
    }

    /// Server-side liveness of a single asset, used by deletion reconciliation.
    enum AssetServerState: Equatable {
        case alive
        case trashed
        /// Permanently gone (or inaccessible) — the server answers 400/404/410
        /// for unknown asset IDs.
        case deleted
    }

    /// Check whether an asset still exists on the server before trusting a
    /// paginated-sweep miss. The sweep can skip rows when the dataset mutates
    /// mid-sweep, so reconciliation must confirm each miss individually.
    func fetchAssetServerState(id: String) async throws -> AssetServerState {
        try await fetchAssetForVerification(id: id).state
    }

    /// Wie `fetchAssetServerState`, liefert zusätzlich das dekodierte Asset — der
    /// Löschabgleich braucht aus derselben Antwort auch die `checksum`.
    /// - Returns: `asset` ist `nil`, wenn der Server das Asset nicht kennt.
    func fetchAssetForVerification(id: String) async throws -> (state: AssetServerState, asset: Asset?) {
        let url = baseURL.appending(path: "api/assets/\(id)")
        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        switch httpResponse.statusCode {
        case 200:
            let asset = try jsonDecoder.decode(Asset.self, from: data)
            return (asset.isTrashed ? .trashed : .alive, asset)
        case 400, 404, 410:
            return (.deleted, nil)
        default:
            throw APIError.httpError(httpResponse.statusCode)
        }
    }

    /// Eine Seite der ganzen Mediathek (ohne Papierkorb), mit EXIF — für den
    /// Sync-Sweep, das Nachladen im Raster und die EXIF-Reparatur.
    ///
    /// Seit Immich v3.2 über die strukturierte Suche; die Seitennummer übersetzt
    /// ``pagedSearch(filter:page:size:withExif:)``. Dieselben Standards wie die alte
    /// flache Suche: nur `trashedAt: null`, keine Sichtbarkeitsbedingung (die alte nahm
    /// alles außer `locked`).
    func searchAssets(page: Int = 1, size: Int = 200) async throws -> AssetPage {
        var filter = SearchFilter()
        filter.trashedAt = .isNull
        return try await pagedSearch(filter: filter, page: page, size: size, withExif: true)
    }

    /// Eine Seite der strukturierten Suche nach Seitennummer, im Format der alten
    /// flachen Suche (`nextPage` gesetzt, solange es weitergeht).
    ///
    /// Der Cursor der neuen Form ist ein verpackter Offset (``SearchCursor``). Liefert
    /// der Server einen anderen `nextCursor` als den für die nächste Seite erwarteten,
    /// bricht der Abruf ab — sonst blätterte die Seitenlogik still an falscher Stelle
    /// weiter, und der Sweep hielte fehlende Seiten für gelöschte Assets.
    ///
    /// Antworten ohne `nextCursor`, aber mit `nextPage` (Testattrappen der alten Form)
    /// gelten weiter.
    private func pagedSearch(filter: SearchFilter, page: Int, size: Int, withExif: Bool) async throws -> AssetPage {
        let query = AssetSearchQuery(
            filter: filter,
            orderBy: SearchOrder(field: .fileCreatedAt, direction: .desc),
            cursor: SearchCursor.forPage(page, size: size),
            size: size,
            withExif: withExif
        )
        let result = try await searchAssets(query: query)
        let hasMore: Bool
        if let next = result.nextCursor, !next.isEmpty {
            guard next == SearchCursor.forOffset(page * size) else {
                AppLogger.api.error("Suchcursor unerwartet: \(next, privacy: .public) statt Offset \(page * size)")
                throw APIError.operationFailed("Der Server blättert anders als erwartet (Suchcursor). Abgleich abgebrochen.")
            }
            hasMore = true
        } else {
            hasMore = result.nextPage.map { !$0.isEmpty } ?? false
        }
        return AssetPage(
            items: result.items,
            total: result.total,
            count: result.count,
            nextPage: hasMore ? String(page + 1) : nil,
            nextCursor: result.nextCursor
        )
    }

    /// Fetch archived assets using Immich v2.5+ timeline API.
    /// Uses `visibility=ARCHIVE` filter and parses columnar bucket responses.
    func searchArchivedAssets() async throws -> [Asset] {
        // Try visibility=ARCHIVE on timeline/buckets first
        let buckets: [TimelineBucket] = try await fetchArchiveBuckets()

        if buckets.isEmpty {
            AppLogger.api.info("No archive buckets found")
            return []
        }

        let totalCount = buckets.map(\.count).reduce(0, +)
        AppLogger.api.info("Found \(buckets.count) archive buckets, \(totalCount) total assets")

        // Fetch each bucket's columnar data and extract archived assets
        var allAssets: [Asset] = []
        var isDiagnosticLogged = false

        for bucket in buckets {
            let assets = try await fetchBucketAssets(timeBucket: bucket.timeBucket, visibility: "archive")

            // Diagnostic: dump visibility values from first bucket
            if !isDiagnosticLogged {
                isDiagnosticLogged = true
                let rawAssets = try await fetchBucketRawVisibility(timeBucket: bucket.timeBucket)
                AppLogger.api.info("Visibility values in first bucket: \(rawAssets)")
            }

            allAssets.append(contentsOf: assets)
        }

        AppLogger.api.info("Total archived assets loaded: \(allAssets.count)")
        return allAssets
    }

    private struct TimelineBucket: Decodable {
        let timeBucket: String
        let count: Int
    }

    /// Try to get archive-specific buckets, falling back to all buckets
    private func fetchArchiveBuckets() async throws -> [TimelineBucket] {
        // First try: visibility=ARCHIVE filter
        var components = URLComponents(url: baseURL.appending(path: "api/timeline/buckets"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "size", value: "MONTH"),
            URLQueryItem(name: "visibility", value: "archive")
        ]

        var request = URLRequest(url: components.url!)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")

        let (data, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
            let buckets = try jsonDecoder.decode([TimelineBucket].self, from: data)
            AppLogger.api.info("visibility=ARCHIVE filter worked, \(buckets.count) buckets")
            return buckets
        }

        // Second try: get ALL buckets (we'll filter by visibility column in each bucket)
        AppLogger.api.warning("visibility=ARCHIVE filter not supported, falling back to all buckets with client-side filter")
        components.queryItems = [
            URLQueryItem(name: "size", value: "MONTH")
        ]
        request = URLRequest(url: components.url!)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")

        let (allData, allResponse) = try await session.data(for: request)
        guard let allHttp = allResponse as? HTTPURLResponse, allHttp.statusCode == 200 else {
            throw APIError.httpError((allResponse as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return try jsonDecoder.decode([TimelineBucket].self, from: allData)
    }

    /// Fetch assets from a timeline bucket, parsing the columnar response format.
    /// If visibility filter is provided, only returns assets matching that visibility.
    private func fetchBucketAssets(timeBucket: String, visibility: String?) async throws -> [Asset] {
        var components = URLComponents(url: baseURL.appending(path: "api/timeline/bucket"), resolvingAgainstBaseURL: false)!
        var queryItems = [
            URLQueryItem(name: "size", value: "MONTH"),
            URLQueryItem(name: "timeBucket", value: timeBucket)
        ]
        if let visibility {
            queryItems.append(URLQueryItem(name: "visibility", value: visibility))
        }
        components.queryItems = queryItems

        var request = URLRequest(url: components.url!)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return []
        }

        // Parse columnar format: {"id": [...], "visibility": [...], "fileCreatedAt": [...], ...}
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ids = dict["id"] as? [String] else {
            return []
        }

        let visibilityCol   = dict["visibility"]   as? [String]   ?? []
        let fileCreatedAtCol = dict["fileCreatedAt"] as? [String]   ?? []
        let thumbhashCol    = dict["thumbhash"]    as? [String?]  ?? []
        let isFavoriteCol   = dict["isFavorite"]   as? [Bool]     ?? []
        let isImageCol      = dict["isImage"]      as? [Bool]     ?? []
        let isTrashedCol    = dict["isTrashed"]    as? [Bool]     ?? []
        // Stack columns — present in Immich ≥ 1.118
        let stackIdCol      = dict["stackId"]      as? [String?]  ?? []
        let stackCountCol   = dict["stackCount"]   as? [Int]      ?? []

        var assets: [Asset] = []

        for i in 0..<ids.count {
            // If visibility filter active, skip non-matching
            if let visibility, i < visibilityCol.count, visibilityCol[i] != visibility {
                continue
            }

            let isArchived = i < visibilityCol.count && visibilityCol[i] == "archive"
            let createdAt  = i < fileCreatedAtCol.count ? fileCreatedAtCol[i] : ""
            let isImage    = i < isImageCol.count ? isImageCol[i] : true
            let stackId    = i < stackIdCol.count ? stackIdCol[i] : nil
            let stackCount = i < stackCountCol.count ? stackCountCol[i] : nil

            let asset = Asset(
                id: ids[i],
                type: isImage ? .image : .video,
                originalFileName: "",
                fileCreatedAt: createdAt,
                fileModifiedAt: createdAt,
                isFavorite: i < isFavoriteCol.count ? isFavoriteCol[i] : false,
                isArchived: isArchived,
                thumbhash: i < thumbhashCol.count ? thumbhashCol[i] : nil,
                isTrashed: i < isTrashedCol.count ? isTrashedCol[i] : false,
                stackId: stackId,
                stackCount: stackCount
            )
            assets.append(asset)
        }

        return assets
    }

    /// Diagnostic: fetch raw visibility values from a bucket
    private func fetchBucketRawVisibility(timeBucket: String) async throws -> [String: Int] {
        var components = URLComponents(url: baseURL.appending(path: "api/timeline/bucket"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "size", value: "MONTH"),
            URLQueryItem(name: "timeBucket", value: timeBucket)
        ]

        var request = URLRequest(url: components.url!)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")

        let (data, _) = try await session.data(for: request)
        guard let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let visCol = dict["visibility"] as? [Any] else {
            return ["NO_VISIBILITY_COL": 0]
        }

        var counts: [String: Int] = [:]
        for v in visCol {
            let key = "\(v)"
            counts[key, default: 0] += 1
        }
        return counts
    }

    /// Eine Seite der seit `updatedAfter` geänderten Assets, **einschließlich
    /// Papierkorb** (Löschen ändert `updatedAt`) — für den Delta-Abgleich des Pollings.
    ///
    /// Wie die alte flache Suche: `updatedAt >= updatedAfter` (`updatedAfter` war
    /// `>=`), `withDeleted: true` ⇒ keine Papierkorb-Bedingung, mit EXIF.
    func searchAssets(updatedAfter: Date, page: Int = 1, size: Int = 1000) async throws -> AssetPage {
        var filter = SearchFilter()
        filter.updatedAt = .onOrAfter(updatedAfter)
        return try await pagedSearch(filter: filter, page: page, size: size, withExif: true)
    }

    /// Get asset counts from server statistics
    func getAssetStatistics() async throws -> AssetStatistics {
        let url = baseURL.appending(path: "api/assets/statistics")
        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw APIError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return try jsonDecoder.decode(AssetStatistics.self, from: data)
    }

    // MARK: - URLs (sync, for Nuke image loading)

    func thumbnailURL(assetId: String, size: ThumbnailSize = .thumbnail) -> URL {
        thumbnailURL(assetId: assetId, size: size, edited: editedAssets.contains(assetId))
    }

    /// Dieselbe URL mit ausdrücklich gewählter Fassung — für die Cache-Räumung, die
    /// beide Schlüssel treffen muss, und für die Wartelogik nach einer Bearbeitung.
    func thumbnailURL(assetId: String, size: ThumbnailSize, edited: Bool) -> URL {
        var items = [URLQueryItem(name: "size", value: size.rawValue)]
        if edited { items.append(URLQueryItem(name: "edited", value: "true")) }
        return assetBasePath.appending(path: "\(assetId)/thumbnail").appending(queryItems: items)
    }

    func originalURL(assetId: String) -> URL {
        assetBasePath.appending(path: "\(assetId)/original")
    }

    /// Die Volldarstellung fürs **Anzeigen** — `edited=true` nur, wenn das Asset
    /// wirklich bearbeitet ist (genau wie ``thumbnailURL(assetId:size:)``).
    ///
    /// **Nicht bedingungslos `edited=true` anhängen.** Die Annahme, Immich falle bei
    /// einem unbearbeiteten Asset auf das Original zurück, ist falsch: Am 06.09.2026
    /// gemessen lieferte derselbe Beschnitt unter `original` 1.628.073 Bytes mit
    /// `Orientation`, `{Exif}`, `{GPS}` und `{TIFF}` — unter `original?edited=true`
    /// dagegen 969.636 Bytes **ohne Orientierung und ohne jede Metadatengruppe**. Ein
    /// hochkant aufgenommenes iPhone-Foto erschien dadurch um 90° gedreht, während
    /// Immichs eigene Vorschau es richtig zeigte.
    ///
    /// Für Downloads und zum Bearbeiten bleibt ``originalURL(assetId:)`` richtig: Dort
    /// will man die unveränderte Datei.
    func originalDisplayURL(assetId: String) -> URL {
        let url = originalURL(assetId: assetId)
        guard editedAssets.contains(assetId) else { return url }
        return url.appending(queryItems: [URLQueryItem(name: "edited", value: "true")])
    }

    /// Alle Bild-URLs eines Assets, unter denen etwas im Nuke-Cache liegen kann —
    /// jeweils beide Fassungen. Wird ein Asset gerade erst als bearbeitet markiert,
    /// wechselt seine Kachel-URL; der Eintrag unter der alten bliebe sonst liegen und
    /// wäre nach einem Zurücksetzen der Bearbeitung wieder sichtbar.
    func cacheKeyURLs(assetId: String) -> [URL] {
        let original = originalURL(assetId: assetId)
        return [
            thumbnailURL(assetId: assetId, size: .thumbnail, edited: false),
            thumbnailURL(assetId: assetId, size: .thumbnail, edited: true),
            thumbnailURL(assetId: assetId, size: .preview, edited: false),
            thumbnailURL(assetId: assetId, size: .preview, edited: true),
            original,
            original.appending(queryItems: [URLQueryItem(name: "edited", value: "true")]),
        ]
    }

    func playbackURL(assetId: String) -> URL {
        assetBasePath.appending(path: "\(assetId)/video/playback")
    }

    /// Download the original asset file, streaming directly to disk to avoid RAM spikes.
    /// Returns the file data (read from the temp file) and the suggested filename.
    /// Using session.download() means the OS buffers to disk — a 4 GB video never
    /// fully enters process memory, preventing OOM crashes on large files.
    func downloadOriginal(assetId: String) async throws -> (data: Data, filename: String) {
        let url = originalURL(assetId: assetId)
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")

        // Stream to a temp file — zero in-memory buffering of the full body
        let (tempURL, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            throw APIError.httpError(httpResponse.statusCode)
        }

        // Extract filename from Content-Disposition header
        var filename = "\(assetId).jpg"
        if let httpResponse = response as? HTTPURLResponse,
           let disposition = httpResponse.value(forHTTPHeaderField: "Content-Disposition"),
           let range = disposition.range(of: "filename=\""),
           let endRange = disposition[range.upperBound...].range(of: "\"") {
            filename = String(disposition[range.upperBound..<endRange.lowerBound])
        } else if let suggestedName = response.suggestedFilename {
            filename = suggestedName
        }

        // Read from the temp file — only at this point does the data enter memory.
        // Callers that only write to disk (LocalFileCacheManager) should be refactored
        // to accept a URL instead; this keeps the existing (data, filename) API intact.
        let data = try Data(contentsOf: tempURL)
        return (data, filename)
    }

    /// Download the original asset file directly to a destination URL (zero RAM spike).
    /// Used by LocalFileCacheManager so large videos never enter process memory at all.
    /// Returns the suggested filename extracted from Content-Disposition.
    @discardableResult
    func downloadOriginalToFile(assetId: String, destinationURL: URL) async throws -> String {
        let url = originalURL(assetId: assetId)
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")

        let (tempURL, response) = try await session.download(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            try? FileManager.default.removeItem(at: tempURL)
            throw APIError.httpError(httpResponse.statusCode)
        }

        var filename = "\(assetId).jpg"
        if let httpResponse = response as? HTTPURLResponse,
           let disposition = httpResponse.value(forHTTPHeaderField: "Content-Disposition"),
           let range = disposition.range(of: "filename=\""),
           let endRange = disposition[range.upperBound...].range(of: "\"") {
            filename = String(disposition[range.upperBound..<endRange.lowerBound])
        } else if let suggestedName = response.suggestedFilename {
            filename = suggestedName
        }

        // Remove any leftover file at the destination (e.g. from a previously
        // interrupted download) — moveItem does not overwrite automatically.
        try? FileManager.default.removeItem(at: destinationURL)
        // Move temp file to final destination (atomic, no copy)
        try FileManager.default.moveItem(at: tempURL, to: destinationURL)
        return filename
    }

    /// Lädt eine beliebige Asset-URL (Vorschau, abspielbare Fassung) direkt auf die
    /// Platte. Liefert den `Content-Type`, aus dem der Aufrufer die Endung bildet.
    @discardableResult
    func downloadToFile(url: URL, destinationURL: URL) async throws -> String? {
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        let (tempURL, response) = try await session.download(for: request)
        let http = response as? HTTPURLResponse
        if let http, http.statusCode != 200 {
            try? FileManager.default.removeItem(at: tempURL)
            throw APIError.httpError(http.statusCode)
        }
        try? FileManager.default.removeItem(at: destinationURL)
        try FileManager.default.moveItem(at: tempURL, to: destinationURL)
        return http?.value(forHTTPHeaderField: "Content-Type")
    }

    // MARK: - Upload Checks

    /// Preflight check for duplicate files using their SHA-1 checksum.
    func checkBulkUpload(assets: [AssetBulkUploadCheckItem]) async throws -> [AssetBulkUploadCheckResult] {
        let url = baseURL.appending(path: "api/assets/bulk-upload-check")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        
        let body = ["assets": assets]
        request.httpBody = try jsonEncoder.encode(body)
        
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw APIError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        
        let decoded = try jsonDecoder.decode(AssetBulkUploadCheckResponse.self, from: data)
        return decoded.results
    }
    
    // MARK: - Albums

    func getAlbums() async throws -> [Album] {
        let url = baseURL.appending(path: "api/albums")
        let (data, _) = try await session.data(from: url)
        return try jsonDecoder.decode([Album].self, from: data)
    }

    /// Liefert alle Alben, in denen das Asset mit der angegebenen ID enthalten ist.
    func getAlbumsForAsset(assetId: String) async throws -> [Album] {
        var components = URLComponents(url: baseURL.appending(path: "api/albums"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "assetId", value: assetId)]
        var request = URLRequest(url: components.url!)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        let (data, response) = try await session.data(for: request)
        // Wirft statt eine leere Liste zu melden: „In keinem Album" ist eine Aussage,
        // und aus einem HTTP-Fehler lässt sie sich nicht ableiten.
        //
        // Die Aufrufer benutzen das Ergebnis, um Albumzugehörigkeit zu **erhalten**:
        // `DuplicateActionService.mergeAlbums` nimmt den Keeper in die Alben der
        // Aussortierten auf, bevor diese gelöscht werden („ohne diesen Schritt verlöre
        // der Keeper jede Albumzugehörigkeit der Aussortierten"), und die beiden
        // Bild-Editoren merken sich die Alben vor der Bearbeitung. Eine
        // vorgetäuschte leere Liste lief dort still durch — das Album verlor sein Foto,
        // ohne dass etwas fehlschlug.
        //
        // Dass Werfen der erwartete Vertrag ist, zeigt der dritte Aufrufer:
        // `PhotoGridView.populateAlbumMembership` fängt einen Fehler ab und zeigt
        // „Alben nicht ladbar" — ein Zustand, der bisher nie eintreten konnte.
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            AppLogger.api.error("getAlbumsForAsset(\(assetId)) fehlgeschlagen (\(httpResponse.statusCode))")
            throw APIError.httpError(httpResponse.statusCode)
        }
        return try jsonDecoder.decode([Album].self, from: data)
    }

    func getSharedAlbums() async throws -> [Album] {
        var components = URLComponents(url: baseURL.appending(path: "api/albums"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "shared", value: "true"),
            URLQueryItem(name: "isShared", value: "true")
        ]
        let (data, _) = try await session.data(from: components.url!)
        return try jsonDecoder.decode([Album].self, from: data)
    }

    /// Alle Assets eines Albums mit EXIF.
    ///
    /// Die strukturierte Suche durchsucht ein Album unabhängig vom Eigentümer der Assets
    /// — bei geteilten Alben also auch die Fotos der anderen.
    func getAlbumAssets(albumId: String) async throws -> [Asset] {
        var filter = SearchFilter()
        filter.albumIds = .anyOf([albumId])
        filter.trashedAt = .isNull
        return try await searchAllAssets(filter: filter, withExif: true)
    }

    /// Asset IDs of an album — nothing else.
    ///
    /// Deliberately not `getAlbumAssets(albumId:)`: that one asks for `withExif: true`
    /// and decodes full `Asset` objects. The membership index only needs UUIDs, and it
    /// fetches every album in the library, so the wasted payload would be enormous.
    func getAlbumAssetIds(albumId: String) async throws -> [String] {
        var filter = SearchFilter()
        filter.albumIds = .anyOf([albumId])
        filter.trashedAt = .isNull
        return try await searchAllAssetIds(filter: filter)
    }

    func getAlbumDetail(id: String, fastFail: Bool = false) async throws -> AlbumDetail {
        let url = baseURL.appending(path: "api/albums/\(id)")
        var request = URLRequest(url: url)
        if fastFail {
            request.timeoutInterval = 3
        }
        let (data, _) = try await session.data(for: request)
        var detail = try jsonDecoder.decode(AlbumDetail.self, from: data)
        
        if detail.assets.isEmpty && detail.assetCount > 0 {
            detail.assets = try await getAlbumAssets(albumId: id)
        }
        
        return detail
    }

    /// Setzt das Cover-Asset eines Albums (Immich Server ≥ v2.6.0)
    /// PATCH /api/albums/{albumId}   body: { "albumThumbnailAssetId": "<assetId>" }
    func setAlbumCover(albumId: String, assetId: String) async throws {
        let url = baseURL.appending(path: "api/albums/\(albumId)")
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ["albumThumbnailAssetId": assetId]
        request.httpBody = try jsonEncoder.encode(body)

        // Die Antwort wurde hier verworfen — damit konnte der Aufruf gar nicht
        // scheitern. Das Kontextmenü „Als Album-Cover setzen" fängt einen Fehler
        // ausdrücklich ab und meldete bei Ablehnung trotzdem Erfolg: Die
        // Albumliste lud neu und zeigte weiter das alte Cover, ohne Fehler und
        // ohne Logzeile. Erreichbar mit 403 bei einem geteilten Album und mit 400
        // bei einer Aufnahme, die dem Album nicht angehört.
        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...204).contains(statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? "nil"
            AppLogger.api.error("setAlbumCover(\(albumId), \(assetId)) fehlgeschlagen (\(statusCode)): \(bodyStr)")
            throw APIError.httpError(statusCode)
        }
    }

    /// Alle verfügbaren Tags von der Immich-Instanz laden (Immich Server ≥ v2.6.0)
    /// GET /api/tags
    func getTags() async throws -> [TagInfo] {
        let url = baseURL.appending(path: "api/tags")
        let (data, _) = try await session.data(from: url)
        return try jsonDecoder.decode([TagInfo].self, from: data)
    }

    /// Legt einen Tag an — oder findet ihn, falls es ihn schon gibt — und liefert den
    /// Blatt-Tag des Pfads zurück.
    /// PUT /api/tags   body: { "tags": ["reise/berlin"] }
    ///
    /// Bewusst nicht `POST /api/tags`: Das verlangt `name` statt `value` (der Client
    /// schickte bis Sept. 2026 `value` und scheiterte damit an jedem Server) und lehnt
    /// seit v3.2.0 Schrägstriche im Namen ab. Der Upsert legt fehlende Elternteile an.
    @discardableResult
    func createTag(path: String) async throws -> TagInfo {
        guard let normalized = TagPath.normalized(path) else {
            throw APIError.operationFailed("Der Tag-Name ist leer.")
        }
        let url = baseURL.appending(path: "api/tags")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.httpBody = try jsonEncoder.encode(["tags": [normalized]])

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...201).contains(httpResponse.statusCode) else {
            throw APIError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        guard let tag = try jsonDecoder.decode([TagInfo].self, from: data).first else {
            throw APIError.invalidResponse
        }
        return tag
    }

    /// Benennt einen Tag um; der Server ersetzt nur das letzte Pfadsegment und zieht
    /// die Pfade aller Kinder in derselben Transaktion nach.
    /// PUT /api/tags/{id}   body: { "name": "Paris" }   (ab Server v3.2.0)
    func renameTag(_ tag: TagInfo, to newName: String) async throws -> TagInfo {
        guard let name = TagPath.validatedName(newName) else {
            throw APIError.operationFailed("Ein Tag-Name darf nicht leer sein und keinen „/“ enthalten.")
        }
        let expected = TagPath.renamedValue(tag.value, to: name)
        guard expected != tag.value else { return tag }

        let url = baseURL.appending(path: "api/tags/\(tag.id)")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.httpBody = try jsonEncoder.encode(["name": name])

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...201).contains(httpResponse.statusCode) else {
            throw APIError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let updated = try jsonDecoder.decode(TagInfo.self, from: data)
        // Vor v3.2.0 kennt `TagUpdateDto` nur `color`: 200 mit unverändertem Wert.
        guard updated.value != tag.value else {
            throw APIError.operationFailed(TagPath.renameUnsupportedMessage)
        }
        return updated
    }

    /// Hängt Tags an Assets.
    /// PUT /api/tags/{tagId}/assets   body: { "ids": [...assetIds] }
    func tagAssets(tagId: String, assetIds: [String]) async throws {
        guard !assetIds.isEmpty else { return }
        let url = baseURL.appending(path: "api/tags/\(tagId)/assets")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.httpBody = try jsonEncoder.encode(["ids": assetIds])

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...204).contains(httpResponse.statusCode) else {
            throw APIError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }

    /// Entfernt Tags von Assets.
    /// DELETE /api/tags/{tagId}/assets   body: { "ids": [...assetIds] }
    func untagAssets(tagId: String, assetIds: [String]) async throws {
        guard !assetIds.isEmpty else { return }
        let url = baseURL.appending(path: "api/tags/\(tagId)/assets")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.httpBody = try jsonEncoder.encode(["ids": assetIds])

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...204).contains(httpResponse.statusCode) else {
            throw APIError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }

    /// Alle Assets eines Tags, Unter-Tags eingeschlossen.
    /// POST /api/search/metadata   body: { "filter": { "tagIds": { "all": [tagId] }, … } }
    func getAssetsForTag(_ tagId: String) async throws -> [Asset] {
        var filter = SearchFilter()
        filter.tagIds = .allOf([tagId])
        filter.trashedAt = .isNull
        return try await searchAllAssets(filter: filter)
    }

    // MARK: - Search

    /// CLIP-Suche mit serverseitigem Filter, eine Anfrage (ab Server v3.2.0).
    /// POST /api/search/smart   body: { "query": …, "filter": {…}, "size": … }
    ///
    /// Die strukturierte Form blättert nicht — `size` (höchstens 1000) ist zugleich
    /// der Deckel. CLIP kennt keine Trefferschwelle, die Wahl des Deckels steht deshalb
    /// in ``SearchQueryPlanner/resultCap(for:)``. Die Chips übersetzt
    /// ``ServerFilters/searchFilter``; beides lag früher hier, einmal doppelt.
    func smartSearch(query: String, filter: SearchFilter, size: Int) async throws -> [Asset] {
        struct Body: Encodable {
            let query: String
            let filter: SearchFilter
            let size: Int
        }
        let url = baseURL.appending(path: "api/search/smart")
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.httpBody = try jsonEncoder.encode(Body(query: query, filter: filter, size: min(max(size, 1), 1000)))

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard statusCode == 200 else {
            if statusCode == 400 {
                AppLogger.api.error("smartSearch abgelehnt: \(String(decoding: data, as: UTF8.self), privacy: .public)")
            }
            throw APIError.httpError(statusCode)
        }
        let items = try jsonDecoder.decode(AssetSearchResponse.self, from: data).assets.items ?? []
        AppLogger.api.info("smartSearch '\(query)' + Filter: \(items.count) Treffer")
        return items
    }

    /// Alle Treffer eines Filters als volle Assets, über alle Seiten (ab Server v3.2.0).
    func searchAllAssets(filter: SearchFilter, withExif: Bool? = nil, withPeople: Bool? = nil) async throws -> [Asset] {
        var assets: [Asset] = []
        var cursor: String?
        var seenCursors = Set<String>()
        repeat {
            try Task.checkCancellation()
            let page = try await searchAssets(query: AssetSearchQuery(filter: filter, cursor: cursor, size: 1000, withExif: withExif, withPeople: withPeople))
            let items = page.items ?? []
            assets.append(contentsOf: items)
            cursor = page.nextCursor.flatMap { $0.isEmpty ? nil : $0 }
            if items.isEmpty { cursor = nil }
            // Ein Server, der denselben Cursor wiederholt, ließe die Schleife endlos laufen.
            if let cursor, !seenCursors.insert(cursor).inserted {
                throw APIError.operationFailed("Die Suche lieferte denselben Cursor zweimal.")
            }
        } while cursor != nil
        return assets
    }

    /// Eine Seite der strukturierten Metadatensuche (ab Server v3.2.0).
    /// POST /api/search/metadata   body: { "filter": {…}, "cursor": …, "size": … }
    ///
    /// Weiterblättern über `AssetPage.nextCursor`; `nextPage` bleibt in dieser Form
    /// `nil`. Fallen der Filterform stehen an ``SearchFilter``.
    func searchAssets(query: AssetSearchQuery) async throws -> AssetPage {
        let url = baseURL.appending(path: "api/search/metadata")
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.httpBody = try jsonEncoder.encode(query)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            if statusCode == 400 {
                AppLogger.api.error("searchAssets(query:) abgelehnt: \(String(decoding: data, as: UTF8.self), privacy: .public)")
            }
            throw APIError.httpError(statusCode)
        }
        return try jsonDecoder.decode(AssetSearchResponse.self, from: data).assets
    }

    /// Alle Treffer eines Filters als schlanke `(id, ownerId)`-Paare, über alle Seiten.
    ///
    /// Für Mengenfragen (Spiegel-Abgleich), nicht für die Anzeige: Der Server liefert
    /// zwar volle `AssetResponseDto`s, dekodiert werden aber nur zwei Felder.
    /// `ownerId` ist Pflicht — die Suche umfasst auch Partner-Assets, und wer sie
    /// aussortieren muss, darf nicht raten.
    func searchAllAssetRefs(filter: SearchFilter) async throws -> [AssetRef] {
        var refs: [AssetRef] = []
        var cursor: String?
        var seenCursors = Set<String>()
        repeat {
            try Task.checkCancellation()
            let url = baseURL.appending(path: "api/search/metadata")
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.httpBody = try jsonEncoder.encode(AssetSearchQuery(filter: filter, cursor: cursor, size: 1000))

            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                throw APIError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
            }
            let page = try jsonDecoder.decode(AssetRefSearchResponse.self, from: data).assets
            refs.append(contentsOf: page.items)
            cursor = page.nextCursor.flatMap { $0.isEmpty ? nil : $0 }
            if page.items.isEmpty { cursor = nil }
            // Ein Server, der denselben Cursor wiederholt, ließe die Schleife endlos laufen.
            if let cursor, !seenCursors.insert(cursor).inserted {
                throw APIError.operationFailed("Die Suche lieferte denselben Cursor zweimal.")
            }
        } while cursor != nil
        return refs
    }

    /// Alle Treffer eines Filters als volle Assets, aber nur die des Kontos `ownerId`.
    ///
    /// Die Suche umfasst Partner-Assets. Für die Anzeige eines Smart Albums sollen
    /// es dieselben Fotos sein, die der Spiegel hineinlegt — und der nimmt nur
    /// eigene. `Asset` kennt keinen Eigentümer, deshalb wird dieselbe Antwort ein
    /// zweites Mal als `AssetRef` gelesen; beide Listen haben dieselbe Reihenfolge.
    func searchAllOwnAssets(filter: SearchFilter, ownerId: String) async throws -> [Asset] {
        var own: [Asset] = []
        var cursor: String?
        var seenCursors = Set<String>()
        repeat {
            let url = baseURL.appending(path: "api/search/metadata")
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.httpBody = try jsonEncoder.encode(AssetSearchQuery(filter: filter, cursor: cursor, size: 1000))

            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                throw APIError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
            }
            let assets = try jsonDecoder.decode(AssetSearchResponse.self, from: data).assets
            let refs = try jsonDecoder.decode(AssetRefSearchResponse.self, from: data).assets
            let items = assets.items ?? []
            guard items.count == refs.items.count else { throw APIError.invalidResponse }
            for (asset, ref) in zip(items, refs.items) where ref.ownerId == ownerId {
                own.append(asset)
            }
            cursor = refs.nextCursor.flatMap { $0.isEmpty ? nil : $0 }
            if items.isEmpty { cursor = nil }
            // Ein Server, der denselben Cursor wiederholt, ließe die Schleife endlos laufen.
            if let cursor, !seenCursors.insert(cursor).inserted {
                throw APIError.operationFailed("Die Suche lieferte denselben Cursor zweimal.")
            }
        } while cursor != nil
        return own
    }

    /// Nur die IDs aller Treffer, über alle Seiten.
    ///
    /// Eigenes schlankes Dekodieren wie früher `IdOnlyPage`: Ein Eigentümer wird hier
    /// nicht gebraucht und darf deshalb auch nicht vorausgesetzt werden (anders als bei
    /// ``searchAllAssetRefs(filter:)``).
    func searchAllAssetIds(filter: SearchFilter) async throws -> [String] {
        struct IdOnlyPage: Decodable {
            struct Assets: Decodable {
                struct Item: Decodable { let id: String }
                let items: [Item]?
                let nextCursor: String?
            }
            let assets: Assets
        }
        var ids: [String] = []
        var cursor: String?
        var seenCursors = Set<String>()
        repeat {
            try Task.checkCancellation()
            let url = baseURL.appending(path: "api/search/metadata")
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.httpBody = try jsonEncoder.encode(AssetSearchQuery(filter: filter, cursor: cursor, size: 1000))

            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                throw APIError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
            }
            let page = try jsonDecoder.decode(IdOnlyPage.self, from: data).assets
            let items = page.items ?? []
            ids.append(contentsOf: items.map(\.id))
            cursor = page.nextCursor.flatMap { $0.isEmpty ? nil : $0 }
            if items.isEmpty { cursor = nil }
            // Ein Server, der denselben Cursor wiederholt, ließe die Schleife endlos laufen.
            if let cursor, !seenCursors.insert(cursor).inserted {
                throw APIError.operationFailed("Die Suche lieferte denselben Cursor zweimal.")
            }
        } while cursor != nil
        return ids
    }

    /// Werteliste für Such-Vorschläge.
    /// GET /api/search/suggestions?type=country|state|city|camera-model
    ///
    /// `country` und `state` schränken die Liste ein — `type=city&country=Japan`
    /// liefert nur japanische Städte (am Server nachgemessen am 12.09.2026).
    func searchSuggestions(type: String, country: String? = nil, state: String? = nil) async throws -> [String] {
        var components = URLComponents(url: baseURL.appending(path: "api/search/suggestions"), resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "type", value: type)]
        if let country { items.append(URLQueryItem(name: "country", value: country)) }
        if let state { items.append(URLQueryItem(name: "state", value: state)) }
        components.queryItems = items
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw APIError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        // Der Server nimmt auch `null` in die Liste auf (Assets ohne den Wert).
        return try jsonDecoder.decode([String?].self, from: data).compactMap { $0 }
    }

    /// Anzahl der Treffer eines Filters, ohne Assets zu übertragen (~30 ms).
    /// POST /api/search/statistics   body: { "filter": {…} }  →  { "total": N }
    ///
    /// Nicht `AssetPage.total` nehmen: In der strukturierten Suche ist das nur die
    /// Größe der gelieferten Seite (nachgemessen: `size: 1` → `total: 1`).
    func searchStatistics(filter: SearchFilter) async throws -> Int {
        struct Koerper: Encodable { let filter: SearchFilter }
        struct Antwort: Decodable { let total: Int }

        let url = baseURL.appending(path: "api/search/statistics")
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.httpBody = try jsonEncoder.encode(Koerper(filter: filter))

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw APIError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return try jsonDecoder.decode(Antwort.self, from: data).total
    }

    /// ID des angemeldeten Kontos. GET /api/users/me
    func getMyUserId() async throws -> String {
        let url = baseURL.appending(path: "api/users/me")
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw APIError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        struct Me: Decodable { let id: String }
        return try jsonDecoder.decode(Me.self, from: data).id
    }

    /// Kennung des Kontos hinter dem Schlüssel, oder `nil`, wenn sie sich nicht
    /// ermitteln lässt.
    ///
    /// Zuerst `GET /api/users/me`; das verlangt aber `user.read`, und die Schlüssel,
    /// die das iOS-Onboarding anlegt, haben dieses Recht nicht. Dann die eigenen Alben
    /// (`shared=false` liefert nur Alben, die dem Konto gehören, `album.read` hat
    /// jeder Schlüssel dieser App) — deren `owner.id` ist das Konto. Wer weder das
    /// eine darf noch ein eigenes Album hat, bekommt `nil`: lieber keine Aussage als
    /// eine geratene, an der ein Löschen hängt.
    func kontoKennung() async -> String? {
        if let id = try? await getMyUserId() { return id }
        var components = URLComponents(url: baseURL.appending(path: "api/albums"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "shared", value: "false")]
        guard let (data, response) = try? await session.data(from: components.url!),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let alben = try? jsonDecoder.decode([Album].self, from: data) else { return nil }
        return alben.lazy.compactMap(\.owner?.id).first
    }

    /// Assets, deren Dateiname `originalFileName` enthält — höchstens `size`, auch aus
    /// dem Papierkorb. Die Aufrufer (Apple-Fotos-Abgleich) prüfen danach selbst per
    /// Datum und Kennung.
    ///
    /// Wie die alte flache Suche: `like` ist „enthält" ohne Groß-/Kleinschreibung und
    /// Akzente, `_` und `%` im Namen wirken als Platzhalter; keine
    /// Papierkorb-Bedingung (die alte schickte `withDeleted: true`).
    func searchByOriginalFilename(_ originalFileName: String, size: Int = 100) async throws -> [Asset] {
        var filter = SearchFilter()
        filter.originalFileName = .contains(originalFileName)
        return try await searchAssets(query: AssetSearchQuery(filter: filter, size: size)).items ?? []
    }

    // MARK: - People

    func getPerson(id: String) async throws -> Person {
        let url = baseURL.appending(path: "api/people/\(id)")
        let (data, _) = try await session.data(from: url)
        return try jsonDecoder.decode(Person.self, from: data)
    }

    /// Alle Personen, serverseitig paginiert.
    ///
    /// Die frühere Fassung filterte versteckte Personen **clientseitig** heraus. Damit
    /// wäre „Verstecken" eine Einbahnstraße gewesen: die Person verschwände aus der App
    /// und ließe sich dort nie wieder hervorholen. Der Server kann das über `withHidden`
    /// korrekt, also übernimmt er es.
    func getPeople(withHidden: Bool = false) async throws -> [Person] {
        var all: [Person] = []
        var page = 1
        let pageSize = 1000

        while true {
            var components = URLComponents(
                url: baseURL.appending(path: "api/people"),
                resolvingAgainstBaseURL: false
            )
            components?.queryItems = [
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "size", value: String(pageSize)),
                URLQueryItem(name: "withHidden", value: withHidden ? "true" : "false")
            ]
            guard let url = components?.url else { throw APIError.invalidResponse }

            let (data, _) = try await session.data(from: url)
            let response = try jsonDecoder.decode(PeopleResponse.self, from: data)
            all.append(contentsOf: response.people)

            if response.hasNextPage != true || response.people.count < pageSize { break }
            page += 1
        }
        return all
    }

    /// Führt `sourceIds` in die Person `targetId` zusammen.
    ///
    /// Die Antwort trägt pro ID ein eigenes Ergebnis — Teilerfolge sind möglich und
    /// müssen ausgewertet werden.
    @discardableResult
    func mergePeople(into targetId: String, sourceIds: [String]) async throws -> [BulkIdResponse] {
        let url = baseURL.appending(path: "api/people/\(targetId)/merge")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["ids": sourceIds])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...201).contains(http.statusCode) else {
            throw APIError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        // Ein leerer Body ist zulässig (nichts zusammengeführt). Ein *nicht leerer*, aber
        // unlesbarer Body wird bewusst nicht mehr zu `[]` verschluckt: der Aufrufer läse
        // daraus „alles erfolgreich, null Ergebnisse" und würde stillschweigend weder eine
        // Teilfehler-Meldung zeigen noch die Smart-Album-Regeln umschreiben.
        guard !data.isEmpty else { return [] }
        return try jsonDecoder.decode([BulkIdResponse].self, from: data)
    }

    /// Aktualisiert eine Person. Nur übergebene Felder werden gesendet.
    @discardableResult
    func updatePerson(
        id: String,
        name: String? = nil,
        birthDate: PersonBirthDateUpdate = .unchanged,
        isHidden: Bool? = nil,
        isFavorite: Bool? = nil
    ) async throws -> Person? {
        var body: [String: Any] = [:]
        if let name { body["name"] = name }
        if let value = birthDate.jsonValue { body["birthDate"] = value }
        if let isHidden { body["isHidden"] = isHidden }
        if let isFavorite { body["isFavorite"] = isFavorite }
        guard !body.isEmpty else { return nil }

        let url = baseURL.appending(path: "api/people/\(id)")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return try? jsonDecoder.decode(Person.self, from: data)
    }

    /// Alle Assets, auf denen die Person erkannt ist.
    func getPersonAssets(id: String) async throws -> [Asset] {
        var filter = SearchFilter()
        filter.personIds = .allOf([id])
        filter.trashedAt = .isNull
        return try await searchAllAssets(filter: filter)
    }

    /// Bleibt als schmale Fassade über `updatePerson`, damit bestehende Aufrufer
    /// unverändert weiterlaufen.
    func renamePerson(id: String, name: String) async throws {
        try await updatePerson(id: id, name: name)
    }

    func personThumbnailURL(personId: String) -> URL {
        baseURL.appending(path: "api/people/\(personId)/thumbnail")
    }

    // MARK: - Memories

    /// Erinnerungen. GET /api/memories?for=YYYY-MM-DD&isSaved=…
    ///
    /// **Ohne Parameter liefert der Server alle** — auch längst abgelaufene und
    /// künftige (am 11.09.2026: 445, davon 10 für heute). Für die heutigen gehört
    /// `for` dazu, und zwar als **lokaler** Tag ohne Uhrzeit: Mit Uhrzeit antwortet
    /// der Server 400, und um 00:30 in Berlin ist in UTC noch gestern.
    func getMemories(for day: Date? = nil, isSaved: Bool? = nil, calendar: Calendar = .current) async throws -> [Memory] {
        var components = URLComponents(url: baseURL.appending(path: "api/memories"), resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = []
        if let day { items.append(URLQueryItem(name: "for", value: Self.memoryDay(day, calendar: calendar))) }
        if let isSaved { items.append(URLQueryItem(name: "isSaved", value: isSaved ? "true" : "false")) }
        components.queryItems = items.isEmpty ? nil : items
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw APIError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return try jsonDecoder.decode([Memory].self, from: data)
    }

    /// Der Kalendertag im Format `YYYY-MM-DD`, in der Zone des Kalenders.
    static func memoryDay(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Merkt eine Erinnerung oder nimmt das Merken zurück. Gemerkte löscht der Server
    /// nie. PUT /api/memories/{id}   body: { "isSaved": true }
    func setMemorySaved(id: String, isSaved: Bool) async throws {
        let url = baseURL.appending(path: "api/memories/\(id)")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.httpBody = try jsonEncoder.encode(["isSaved": isSaved])

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }

    func updateMemory(id: String, showAt: Date? = nil, hideAt: Date? = nil) async throws {
        let url = baseURL.appending(path: "api/memories/\(id)")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        
        var body: [String: String] = [:]
        let formatter = ISO8601DateFormatter()
        
        if let show = showAt {
            body["showAt"] = formatter.string(from: show)
        }
        if let hide = hideAt {
            body["hideAt"] = formatter.string(from: hide)
        }
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw APIError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }

    // MARK: - Map

    func getMapMarkers() async throws -> [MapMarker] {
        let url = baseURL.appending(path: "api/map/markers")
        let (data, _) = try await session.data(from: url)
        return try jsonDecoder.decode([MapMarker].self, from: data)
    }

    /// Alle Assets einer Stadt (exakter Vergleich, wie die alte flache Suche).
    func getAssetsForCity(_ city: String) async throws -> [Asset] {
        var filter = SearchFilter()
        filter.city = .equals(city)
        filter.trashedAt = .isNull
        return try await searchAllAssets(filter: filter)
    }


    // MARK: - Stacks

    /// Retrieve all stacks (series) from Immich
    func getStacks() async throws -> [Stack] {
        let url = baseURL.appending(path: "api/stacks")
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw APIError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return try jsonDecoder.decode([Stack].self, from: data)
    }

    /// Create a new stack with `assetIds`, where `primaryAssetId` is the cover.
    /// POST /api/stacks  { "assetIds": [...] }
    /// Returns the newly created stack id.
    func createStack(primaryAssetId: String, childAssetIds: [String]) async throws -> String {
        let url = baseURL.appending(path: "api/stacks")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")

        // Immich expects all asset ids in one flat array; the first becomes primary
        let allIds = [primaryAssetId] + childAssetIds
        let body: [String: Any] = ["assetIds": allIds]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...201).contains(statusCode) else {
            throw APIError.httpError(statusCode)
        }

        struct StackResponse: Decodable { let id: String }
        let result = try jsonDecoder.decode(StackResponse.self, from: data)
        return result.id
    }

    // MARK: - Asset Mutations

    func addAssetsToAlbum(albumId: String, assetIds: [String]) async throws {
        let url = baseURL.appending(path: "api/albums/assets")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")

        let body: [String: Any] = ["albumIds": [albumId], "assetIds": assetIds]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        AppLogger.api.debug("addAssetsToAlbum: albumId=\(albumId) assetCount=\(assetIds.count)")

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        let responseText = String(data: data, encoding: .utf8) ?? "<no body>"
        AppLogger.api.debug("addAssetsToAlbum: status=\(statusCode) response=\(responseText)")
        guard let httpResponse = response as? HTTPURLResponse, (200...201).contains(httpResponse.statusCode) else {
            throw APIError.httpError(statusCode)
        }

        // Validate bulk operation response body for success
        struct AddAssetsResponse: Decodable {
            let success: Bool
            let error: String?
        }
        if let apiResponse = try? jsonDecoder.decode(AddAssetsResponse.self, from: data) {
            if !apiResponse.success {
                throw APIError.operationFailed(apiResponse.error ?? "unknown")
            }
        }

        // Write-through to the membership index. This sits in the networking layer on
        // purpose: it is the one choke point that none of the ~8 call sites can bypass,
        // so the cache cannot drift as new callers appear.
        AlbumMembershipStore.shared.addMembership(albumId: albumId, assetIds: assetIds)
    }

    func toggleFavorite(assetId: String, isFavorite: Bool) async throws {
        let url = baseURL.appending(path: "api/assets/\(assetId)")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")

        let body = ["isFavorite": isFavorite]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let bodyStr = String(data: data, encoding: .utf8) ?? "nil"
            AppLogger.api.error("toggleFavorite(\(assetId), \(isFavorite)) failed (\(statusCode)): \(bodyStr)")
            throw APIError.httpError(statusCode)
        }
        AppLogger.api.info("toggleFavorite(\(assetId), \(isFavorite)) → 200 OK")
    }

    func toggleArchive(assetId: String, isArchived: Bool) async throws {
        let url = baseURL.appending(path: "api/assets/\(assetId)")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")

        // Newer Immich uses "visibility" field: "archive" or "timeline"
        // Also send legacy "isArchived" for backwards compatibility
        let body: [String: Any] = [
            "visibility": isArchived ? "archive" : "timeline",
            "isArchived": isArchived
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await session.data(for: request)
        guard let httpResponse = resp as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let bodyStr = String(data: data, encoding: .utf8) ?? "nil"
            AppLogger.api.error("toggleArchive failed (\(statusCode)): \(bodyStr)")
            throw APIError.httpError(statusCode)
        }
    }

    // MARK: - Koordinaten

    /// Der Rumpf für beide Koordinaten-Endpunkte.
    ///
    /// `NSNull()` statt eines fehlenden Schlüssels ist hier tragend, nicht kosmetisch:
    /// `JSONSerialization` nimmt kein `[String: Any?]`, und ein nil-Wert fiele beim
    /// Aufbau des Dictionary einfach heraus. Aus „Koordinaten löschen" würde damit ein
    /// leeres PUT, das der Server mit 200 quittiert — das Rückgängigmachen bliebe
    /// wirkungslos und sähe trotzdem erfolgreich aus.
    private static func locationBody(latitude: Double?, longitude: Double?) -> [String: Any] {
        var body: [String: Any] = [:]
        if let latitude { body["latitude"] = latitude } else { body["latitude"] = NSNull() }
        if let longitude { body["longitude"] = longitude } else { body["longitude"] = NSNull() }
        return body
    }

    /// `PUT /api/assets/{id}` — setzt oder löscht die Koordinaten eines Assets.
    ///
    /// Für den Paar-Modus des GPS-Abgleichs, wo jede Aufnahme ihre eigene
    /// interpolierte Koordinate bekommt und der Sammel-Endpunkt deshalb nicht passt.
    ///
    /// - Parameters:
    ///   - latitude: `nil` sendet JSON-`null` und entfernt die Koordinate.
    ///   - longitude: dito.
    func updateAssetLocation(assetId: String, latitude: Double?, longitude: Double?) async throws {
        let url = baseURL.appending(path: "api/assets/\(assetId)")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: Self.locationBody(latitude: latitude, longitude: longitude))

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...204).contains(statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? "nil"
            AppLogger.api.error("updateAssetLocation(\(assetId)) fehlgeschlagen (\(statusCode)): \(bodyStr)")
            throw APIError.httpError(statusCode)
        }
    }

    /// `PUT /api/assets` (`AssetBulkUpdateDto`) — ein Koordinatenpaar für viele Assets.
    ///
    /// Für den Cluster-Modus (ein Median für die ganze Session) und fürs
    /// Rückgängigmachen (ein `null`-Paar für den ganzen Stapel).
    ///
    /// Antwortet mit **204 No Content** — ein `== 200` würde jeden erfolgreichen
    /// Aufruf als Fehler werten.
    func bulkUpdateAssetLocation(ids: [String], latitude: Double?, longitude: Double?) async throws {
        guard !ids.isEmpty else { return }

        var request = URLRequest(url: assetBasePath)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")

        var body = Self.locationBody(latitude: latitude, longitude: longitude)
        body["ids"] = ids
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...204).contains(statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? "nil"
            AppLogger.api.error("bulkUpdateAssetLocation(\(ids.count) Assets) fehlgeschlagen (\(statusCode)): \(bodyStr)")
            throw APIError.httpError(statusCode)
        }
    }

    /// `PUT /api/assets/{id}` — überträgt Nutzer-Metadaten auf ein Asset.
    ///
    /// Für die Duplikatsuche: Bevor ein Exemplar in den Papierkorb wandert, wird
    /// hierüber gerettet, was sonst mit ihm verschwände.
    ///
    /// Grenze, die die Oberfläche benennen muss: **Kamera-EXIF ist nicht
    /// schreibbar.** Hersteller, Modell, ISO, Objektiv und Blende leitet der Server
    /// beim Import aus der Datei ab; die Spalten nimmt kein Endpunkt entgegen.
    /// Übertragbar ist allein, was Immich als Nutzerdaten führt.
    ///
    /// Nur gesetzte Parameter landen im Body — ein leerer Body wäre eine Anfrage
    /// ohne Aussage und würde je nach Serverfassung als Fehler gewertet.
    func updateAssetMetadata(
        assetId: String,
        description: String? = nil,
        dateTimeOriginal: String? = nil,
        rating: Int? = nil
    ) async throws {
        var body: [String: Any] = [:]
        if let description { body["description"] = description }
        if let dateTimeOriginal { body["dateTimeOriginal"] = dateTimeOriginal }
        if let rating { body["rating"] = rating }
        guard !body.isEmpty else { return }

        let url = baseURL.appending(path: "api/assets/\(assetId)")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...204).contains(statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? "nil"
            AppLogger.api.error("updateAssetMetadata(\(assetId)) fehlgeschlagen (\(statusCode)): \(bodyStr)")
            throw APIError.httpError(statusCode)
        }
    }

    /// `PUT /api/assets/{id}` (`UpdateAssetDto.livePhotoVideoId`) — paart einen
    /// nachträglich hochgeladenen Videoteil mit seinem bereits vorhandenen Standbild.
    ///
    /// Gesetzt wird die Paarung am **Standbild**: Es trägt das Feld, das Video ist
    /// nur das Ziel. Andersherum entstünde ein Video, das auf ein Foto zeigt.
    ///
    /// Ausdrücklich einzeln, obwohl es hunderte Fotos betrifft: `AssetBulkUpdateDto`
    /// trägt `livePhotoVideoId` nicht — eine Bündelvariante gibt es nicht.
    func setzeLivePhotoVideo(standbildId: String, videoAssetId: String) async throws {
        let url = baseURL.appending(path: "api/assets/\(standbildId)")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["livePhotoVideoId": videoAssetId])

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...204).contains(statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? "nil"
            AppLogger.api.error("setzeLivePhotoVideo(\(standbildId) → \(videoAssetId)) fehlgeschlagen (\(statusCode)): \(bodyStr)")
            throw APIError.httpError(statusCode)
        }
    }

    /// Was nach einer Drehung auf dem Server steht.
    struct AssetRotationResult {
        /// Der neue absolute Winkel, 0…<360.
        let angle: Double
        /// Ob das Asset danach überhaupt noch Bearbeitungen trägt. Bei `false` ist es
        /// wieder unbearbeitet und braucht kein `edited=true` mehr an seinen Bild-URLs.
        let hasEdits: Bool
    }

    /// Dreht das Asset um `delta` Grad weiter — **relativ**, nicht absolut.
    ///
    /// Der Endpunkt selbst kennt nur absolute Zustände und **ersetzt** die
    /// Bearbeitungsliste bei jedem Aufruf (am 06.09.2026 nachgemessen, siehe
    /// ``AssetEditPlan``). Wer hier zweimal 90° schickt, setzt zweimal 90° — das Foto
    /// dreht sich dann genau einmal und danach nie wieder. Deshalb wird der bestehende
    /// Zustand erst gelesen und fortgeschrieben.
    ///
    /// GET und PUT laufen bewusst dicht beieinander in einer Funktion: Zwischen beiden
    /// liegt ein Lese-Ändere-Schreibe-Fenster, das eine zweite gleichzeitige Bearbeitung
    /// überschreiben würde. Die UI verhindert das über `isRotating`.
    @discardableResult
    func rotateAsset(assetId: String, angle delta: Double) async throws -> AssetRotationResult {
        let url = baseURL.appending(path: "api/assets/\(assetId)/edits")

        // 1. Bestehende Bearbeitungen lesen. Die Antwort ist ein Objekt mit `edits`,
        //    kein nacktes Array.
        var getRequest = URLRequest(url: url)
        getRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        getRequest.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        var bestehend: [[String: Any]] = []
        if let (data, response) = try? await session.data(for: getRequest),
           (response as? HTTPURLResponse)?.statusCode == 200,
           let objekt = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let liste = objekt["edits"] as? [[String: Any]] {
            bestehend = liste
        } else {
            // Kein Grund abzubrechen: Ein Asset ohne Bearbeitungen ist der Normalfall,
            // und ältere Server kennen den Endpunkt womöglich nicht. Dann wird eben von
            // 0° aus gedreht.
            AppLogger.api.info("rotateAsset: bestehende Bearbeitungen nicht lesbar — es gilt 0°")
        }

        let neueListe = AssetEditPlan.rotating(by: delta, in: bestehend)
        let vorher = AssetEditPlan.currentRotation(in: bestehend)
        let nachher = AssetEditPlan.normalized(vorher + delta)

        // 2a. Zurück in der Ausgangslage: Die Bearbeitungen einzeln löschen.
        //     Ein leeres `edits`-Array lehnt der Server mit HTTP 400 ab (am 06.09.2026
        //     gemessen, als die vierte Drehung genau daran scheiterte) — „keine
        //     Bearbeitung" lässt sich also nicht setzen, nur löschen.
        if neueListe.isEmpty {
            // Zurück in der Ausgangslage. Zwei Sackgassen, beide am 06.09.2026 gemessen:
            // ein leeres `edits`-Array quittiert der Server mit HTTP 400, und
            // `DELETE /api/assets/edits/{editId}` gibt es gar nicht (404). Was geht, ist
            // `DELETE /api/assets/{id}/edits` → 204, danach meldet der Server `edits: []`.
            //
            // Das löscht **alle** Bearbeitungen des Assets — hier unbedenklich, weil
            // dieser Zweig nur läuft, wenn nach dem Zurückdrehen ohnehin nichts übrig
            // bliebe. Gäbe es noch Belichtung oder Beschnitt, wäre `neueListe` nicht leer
            // und der PUT unten würde sie mitschicken.
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            let (data, resp) = try await session.data(for: request)
            let statusCode = (resp as? HTTPURLResponse)?.statusCode ?? -1
            guard (200...204).contains(statusCode) else {
                let bodyStr = String(data: data, encoding: .utf8) ?? "nil"
                AppLogger.api.error("rotateAsset: Bearbeitungen löschen fehlgeschlagen (\(statusCode)): \(bodyStr)")
                throw APIError.httpError(statusCode)
            }
            AppLogger.api.info("rotateAsset(\(assetId)): \(vorher)° → 0°, Bearbeitungen entfernt")
            return AssetRotationResult(angle: 0, hasEdits: false)
        }

        // 2b. Die vollständige neue Liste setzen.
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["edits": neueListe])

        let (data, resp) = try await session.data(for: request)
        let statusCode = (resp as? HTTPURLResponse)?.statusCode ?? -1

        guard (200...299).contains(statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? "nil"
            AppLogger.api.error("rotateAsset failed (\(statusCode)): \(bodyStr)")
            throw APIError.httpError(statusCode)
        }
        AppLogger.api.info("rotateAsset(\(assetId)): \(vorher)° → \(nachher)°, \(neueListe.count) Bearbeitung(en)")
        return AssetRotationResult(angle: nachher, hasEdits: true)
    }

    // MARK: - Album CRUD

    func createAlbum(name: String, description: String? = nil) async throws -> Album {
        let url = baseURL.appending(path: "api/albums")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        
        var body: [String: Any] = ["albumName": name]
        if let desc = description, !desc.isEmpty {
            body["description"] = desc
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...201).contains(httpResponse.statusCode) else {
            throw APIError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return try jsonDecoder.decode(Album.self, from: data)
    }

    func renameAlbum(id: String, name: String) async throws {
        try await updateAlbum(id: id, name: name, description: nil)
    }

    /// Aktualisiert Name und/oder Beschreibung eines Albums.
    /// PATCH /api/albums/{albumId}  body: { "albumName": "...", "description": "..." }
    func updateAlbum(id: String, name: String, description: String?) async throws {
        let url = baseURL.appending(path: "api/albums/\(id)")
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")

        var body: [String: Any] = ["albumName": name]
        // `nil` heißt **unverändert lassen**, ein leerer String heißt **löschen**.
        //
        // Zuvor wurde `nil` zu `""` — und damit löschte jedes Umbenennen die
        // Beschreibung mit: `renameAlbum` reicht `description: nil` durch, und der
        // einzige Aufrufer davon ist „Album umbenennen" in der Seitenleiste.
        //
        // Wer löschen will, schickt den leeren String ausdrücklich; genau das tut
        // `EditAlbumSheet`, wenn der Nutzer das Feld geleert hat.
        if let description {
            body["description"] = description
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw APIError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        AppLogger.api.info("updateAlbum(\(id)): name='\(name)' description='\(description ?? "")'")
    }

    /// Remove specific assets from an album without deleting the assets themselves.
    /// DELETE /api/albums/{albumId}/assets  body: { "ids": [...] }
    func removeAssetsFromAlbum(albumId: String, assetIds: [String]) async throws {
        guard !assetIds.isEmpty else { return }
        let url = baseURL.appending(path: "api/albums/\(albumId)/assets")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["ids": assetIds])

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...204).contains(httpResponse.statusCode) else {
            throw APIError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        // See addAssetsToAlbum — same choke-point rationale.
        AlbumMembershipStore.shared.removeMembership(albumId: albumId, assetIds: assetIds)
    }

    func deleteAlbum(id: String) async throws {
        let url = baseURL.appending(path: "api/albums/\(id)")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...204).contains(httpResponse.statusCode) else {
            throw APIError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        AlbumMembershipStore.shared.removeAlbum(albumId: id)
    }

    // MARK: - Trash

    /// Soft-delete (force: false) moves to trash; hard-delete (force: true) permanently removes.
    func deleteAssets(ids: [String], force: Bool = false) async throws {
        let url = baseURL.appending(path: "api/assets")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")

        let body: [String: Any] = ["ids": ids, "force": force]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...204).contains(httpResponse.statusCode) else {
            throw APIError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }

    /// Fetch all trashed asset IDs via the timeline API
    /// (GET /api/timeline/buckets + /api/timeline/bucket with isTrashed=true).
    ///
    /// Die flache Metadatensuche ignoriert `isTrashed` und lieferte die ganze
    /// Mediathek. Die strukturierte Form (ab v3.2.0) könnte es mit
    /// `trashedAt: .isNotNull` — am Server nachgezählt: 40 591 gegenüber 40 588 hier,
    /// die Differenz sind `hidden`-Bewegtbild-Anteile. Sie bleibt trotzdem draußen:
    /// Die Suche liefert je Treffer das volle `AssetResponseDto` (grob 2 KB), bei
    /// 40 000 Einträgen also um 80 MB JSON; die Zeitleiste liefert hier nur die
    /// ID-Spalte.
    func getTrashIds() async throws -> [String] {
        var components = URLComponents(url: baseURL.appending(path: "api/timeline/buckets"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "size", value: "MONTH"),
            URLQueryItem(name: "isTrashed", value: "true")
        ]

        var request = URLRequest(url: components.url!)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw APIError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        let buckets = try jsonDecoder.decode([TimelineBucket].self, from: data)

        var allIds: [String] = []
        for bucket in buckets {
            allIds.append(contentsOf: try await fetchTrashBucketIds(timeBucket: bucket.timeBucket))
        }

        AppLogger.api.info("getTrashIds: \(allIds.count) trashed assets in \(buckets.count) buckets")
        return allIds
    }

    /// Fetch the id column of one trash timeline bucket (columnar response).
    private func fetchTrashBucketIds(timeBucket: String) async throws -> [String] {
        var components = URLComponents(url: baseURL.appending(path: "api/timeline/bucket"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "size", value: "MONTH"),
            URLQueryItem(name: "timeBucket", value: timeBucket),
            URLQueryItem(name: "isTrashed", value: "true")
        ]

        var request = URLRequest(url: components.url!)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            // A failed bucket must throw: silently returning [] would make the
            // SyncEngine trash reconcile purge assets that still exist on the server.
            throw APIError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ids = dict["id"] as? [String] else {
            return []
        }
        return ids
    }

    /// Restore specific assets from trash back to library.
    func restoreFromTrash(ids: [String]) async throws {
        let url = baseURL.appending(path: "api/trash/restore/assets")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")

        let body = ["ids": ids]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...204).contains(httpResponse.statusCode) else {
            throw APIError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }

    /// Permanently delete all trashed assets.
    func emptyTrash() async throws {
        let url = baseURL.appending(path: "api/trash/empty")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...204).contains(httpResponse.statusCode) else {
            throw APIError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }
}

// MARK: - Data Models: Dedup
struct AssetBulkUploadCheckItem: Codable {
    let id: String
    let checksum: String // SHA-1 hex
}

struct AssetBulkUploadCheckResult: Codable {
    let id: String
    let action: String   // "accept" or "reject"
    let assetId: String? // the asset ID on the server if rejected/duplicate
    let isTrashed: Bool?
    let reason: String?
}

struct AssetBulkUploadCheckResponse: Codable {
    let results: [AssetBulkUploadCheckResult]
}

// MARK: - Errors

enum APIError: LocalizedError, Equatable {
    case httpError(Int)
    case invalidResponse
    case loginFailed(String)
    case operationFailed(String)
    /// Der Server kennt den API-Key nicht (401).
    case apiKeyRejected
    /// Der Key ist gültig, aber ihm fehlt die genannte Berechtigung (403).
    case apiKeyLacksPermission(String)

    var errorDescription: String? {
        switch self {
        case .httpError(let code): return "Server returned HTTP \(code)"
        case .invalidResponse: return "Invalid response from server"
        case .loginFailed(let msg): return msg
        case .operationFailed(let msg): return msg
        case .apiKeyRejected: return "The server doesn't accept this API key."
        case .apiKeyLacksPermission(let recht): return "This API key is missing the permission \(recht)."
        }
    }

    /// Ein Befund über den Schlüssel selbst — dann hilft kein Offline-Modus,
    /// der Nutzer muss den Key ändern.
    var betrifftSchluessel: Bool {
        switch self {
        case .apiKeyRejected, .apiKeyLacksPermission: true
        default: false
        }
    }
}

/// Response from POST /api/auth/login
struct LoginResponse: Decodable {
    let accessToken: String
    let userId: String?
    let userEmail: String?
    let name: String?
}
