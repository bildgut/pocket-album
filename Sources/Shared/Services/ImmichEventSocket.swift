import Foundation

/// A single parsed Socket.IO frame (Engine.IO v4 text framing).
///
/// Immich's realtime gateway is a plain socket.io server. Over the WebSocket
/// transport every text message is `<engine.io type><payload>`:
///   `0{json}`  open (handshake, contains pingInterval/pingTimeout)
///   `2` / `3`  ping / pong (server pings, client must pong)
///   `4…`       socket.io message; second digit: 0=connect-ack, 2=event, 4=error
/// Event frames carry a JSON array whose first element is the event name:
///   `42["on_asset_update",{…}]`
enum SocketIOFrame: Equatable {
    case open(pingIntervalMs: Int, pingTimeoutMs: Int)
    case ping
    case namespaceConnected
    case namespaceError(String)
    case event(name: String)
    case close
    case other

    static func parse(_ text: String) -> SocketIOFrame {
        guard let first = text.first else { return .other }
        switch first {
        case "0":
            let json = String(text.dropFirst())
            guard let data = json.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .open(pingIntervalMs: 25_000, pingTimeoutMs: 20_000)
            }
            let interval = (dict["pingInterval"] as? Int) ?? 25_000
            let timeout = (dict["pingTimeout"] as? Int) ?? 20_000
            return .open(pingIntervalMs: interval, pingTimeoutMs: timeout)
        case "1":
            return .close
        case "2":
            return .ping
        case "4":
            let rest = text.dropFirst()
            guard let socketType = rest.first else { return .other }
            switch socketType {
            case "0":
                return .namespaceConnected
            case "4":
                return .namespaceError(String(rest.dropFirst()))
            case "2":
                return parseEvent(payload: rest.dropFirst())
            default:
                return .other
            }
        default:
            return .other
        }
    }

    /// Extract the event name from a socket.io EVENT payload. The payload may be
    /// prefixed with a namespace (`/ns,`) and/or an ack id (digits) before the
    /// JSON array: `[/ns,][<ackId>]["name", …]`.
    private static func parseEvent(payload: Substring) -> SocketIOFrame {
        guard let arrayStart = payload.firstIndex(of: "[") else { return .other }
        let json = payload[arrayStart...]
        guard let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let name = array.first as? String else {
            return .other
        }
        return .event(name: name)
    }
}

/// Maps Immich websocket event names to the coarse "something changed" categories
/// the app reacts to. Payloads are intentionally ignored — the checkpoint-based
/// sync stream stays the single source of truth; events are only a wake-up signal.
enum ImmichEventClassifier {
    enum Category {
        case assets
        case albums
    }

    /// Die Namen stehen im `ClientEventMap` des Servers (`websocket.repository.ts`,
    /// gleich in v3.1.0 und v3.2.0). `AssetUploadReadyV1`, `AlbumUpdateV1` und
    /// `on_album_delete` standen hier, sendet der Server aber nicht.
    private static let assetEvents: Set<String> = [
        "on_upload_success",
        "on_asset_update",
        "on_asset_trash",
        "on_asset_delete",
        "on_asset_restore",
        "on_asset_hidden",
        "on_asset_stack_update",
        "AssetUploadReadyV2",
        // Eine bearbeitete Fassung ist fertig gerechnet — die Kachel soll sie zeigen.
        "AssetEditReadyV2",
    ]

    private static let albumEvents: Set<String> = [
        "on_album_update",
    ]

    static func classify(_ eventName: String) -> Category? {
        if assetEvents.contains(eventName) { return .assets }
        if albumEvents.contains(eventName) { return .albums }
        return nil
    }
}

/// Wartezeiten zwischen zwei Verbindungsversuchen.
///
/// Der Zurücksetzer hängt an der **Dauer** einer Verbindung, nicht daran, dass sie
/// zustande kam. Zuvor genügte ein erreichter Namespace: Ein Gegenüber, das die
/// Verbindung annimmt und sofort wieder schließt — ein Proxy ohne
/// Websocket-Durchreichung etwa, oder ein neustartender Server — bekam damit einen
/// Ein-Sekunden-Takt, endlos und jedes Mal mit vollem Handshake samt Zugangsdaten.
///
/// Eigener Typ statt zweier Felder im Actor, damit die Entscheidung ohne Netz
/// prüfbar ist.
struct ReconnectBackoff: Equatable {
    /// Wartezeiten in Sekunden; der letzte Wert gilt ab dann dauerhaft.
    static let steps: [Double] = [1, 2, 5, 10, 30]

    /// Ab dieser Verbindungsdauer gilt ein Versuch als geglückt. Länger als der
    /// größte Schritt, damit dauerndes Flattern nicht doch wieder in den
    /// Ein-Sekunden-Takt kippt.
    static let stableAfter: TimeInterval = 60

    private(set) var index = 0

    /// Nächste Wartezeit; rückt den Zähler eine Stufe weiter.
    mutating func nextDelay() -> Double {
        let delay = Self.steps[index]
        index = min(index + 1, Self.steps.count - 1)
        return delay
    }

    /// Meldet das Ende eines Versuchs.
    /// - Parameter connectedFor: Wie lange die Verbindung stand, oder `nil`, wenn
    ///   sie nie zustande kam. Nur eine ausreichend lange Verbindung setzt zurück.
    mutating func noteAttemptEnded(connectedFor duration: TimeInterval?) {
        guard let duration, duration >= Self.stableAfter else { return }
        index = 0
    }

    /// Setzt zurück, wenn der Anlass von außen kommt — Netz wieder da, Aufwachen
    /// aus dem Ruhezustand. Dort ist ein sofortiger Versuch gewollt.
    mutating func reset() { index = 0 }
}

/// Persistent Socket.IO connection to the Immich server's realtime gateway.
///
/// Purpose: turn server-side changes (made in Immich Web or other clients) into
/// immediate local syncs instead of waiting for the 30–60 s poll interval. The
/// poll loop keeps running as fallback — this socket is an accelerator, never a
/// dependency: if the handshake fails (proxy without WebSocket support, auth),
/// the app behaves exactly as before.
actor ImmichEventSocket {
    private let wsURL: URL
    private let apiKey: String
    private let sessionToken: String?
    private let onAssetsChanged: @Sendable () -> Void
    /// Verbindung steht (erstmals oder wieder). Eigener Rückruf statt
    /// `onAssetsChanged`: Das Nachholen ist kein Server-Ereignis und darf deshalb
    /// entfallen, wenn gerade erst synchronisiert wurde — ein echtes Ereignis nie.
    private let onConnected: @Sendable () -> Void
    private let onAlbumsChanged: @Sendable () -> Void

    private let session: URLSession
    private var loopTask: Task<Void, Never>?
    private var currentTask: URLSessionWebSocketTask?
    private var isOnline = true
    private var running = false

    /// Debounce window — bulk actions in web (multi-delete etc.) emit event bursts.
    private let debounceInterval: Duration = .milliseconds(750)
    private var pendingCategories: Set<ImmichEventClassifier.Category> = []
    private var debounceTask: Task<Void, Never>?

    private var backoff = ReconnectBackoff()

    /// Zeitpunkt, an dem der laufende Versuch den Namespace erreicht hat.
    /// `nil`, solange kein Namespace zustande kam.
    private var connectedAt: Date?

    init?(
        baseURL: URL,
        apiKey: String,
        sessionToken: String?,
        onAssetsChanged: @escaping @Sendable () -> Void,
        onAlbumsChanged: @escaping @Sendable () -> Void,
        onConnected: @escaping @Sendable () -> Void
    ) {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            AppLogger.syncStream.warning("Event socket disabled: cannot parse server URL")
            return nil
        }
        components.scheme = (components.scheme == "http") ? "ws" : "wss"
        components.path = components.path.hasSuffix("/")
            ? components.path + "api/socket.io/"
            : components.path + "/api/socket.io/"
        components.query = "EIO=4&transport=websocket"
        guard let url = components.url else {
            AppLogger.syncStream.warning("Event socket disabled: cannot build websocket URL")
            return nil
        }
        self.wsURL = url
        self.apiKey = apiKey
        self.sessionToken = sessionToken
        self.onAssetsChanged = onAssetsChanged
        self.onAlbumsChanged = onAlbumsChanged
        self.onConnected = onConnected

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession.mitSichererWeiterleitung(config)
    }

    // MARK: - Lifecycle

    func start() {
        guard !running else { return }
        running = true
        loopTask = Task { await runLoop() }
    }

    func stop() {
        running = false
        loopTask?.cancel()
        loopTask = nil
        currentTask?.cancel(with: .goingAway, reason: nil)
        currentTask = nil
        debounceTask?.cancel()
        debounceTask = nil
    }

    /// Connectivity hint from ConnectionManager — pauses reconnect churn while
    /// offline and reconnects promptly once back online.
    func setOnline(_ online: Bool) {
        guard online != isOnline else { return }
        isOnline = online
        if !online {
            currentTask?.cancel(with: .goingAway, reason: nil)
            currentTask = nil
        } else {
            backoff.reset()
        }
    }

    /// Force an immediate reconnect (e.g. after wake from sleep, when the TCP
    /// link is silently dead). The receive loop errors out and reconnects fast.
    func reconnectNow() {
        backoff.reset()
        currentTask?.cancel(with: .goingAway, reason: nil)
        currentTask = nil
    }

    // MARK: - Connection Loop

    private func runLoop() async {
        while running, !Task.isCancelled {
            guard isOnline else {
                try? await Task.sleep(for: .seconds(3))
                continue
            }
            connectedAt = nil
            var fehler: String?
            do {
                try await connectAndReceive()
            } catch {
                fehler = error.localizedDescription
            }

            // Der Rückzieher hängt an der **Dauer** der Verbindung, nicht daran, dass
            // sie zustande kam. Vorher setzte jeder erreichte Namespace ihn zurück —
            // ein Gegenüber, das annimmt und sofort schließt (ein Proxy ohne
            // Websocket-Durchreichung etwa), ergab damit einen Ein-Sekunden-Takt gegen
            // den Server, endlos und jedes Mal mit vollem Handshake samt Zugangsdaten.
            let dauer = connectedAt.map { Date().timeIntervalSince($0) }
            backoff.noteAttemptEnded(connectedFor: dauer)

            guard running else { break }
            let delay = backoff.nextDelay()
            if let fehler, running, isOnline {
                AppLogger.syncStream.info("Event socket disconnected: \(fehler) — retrying in \(delay)s")
            }
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    /// Connect, complete the socket.io handshake, then receive until the
    /// connection dies. Returns on clean close, throws on error.
    private func connectAndReceive() async throws {
        var request = URLRequest(url: wsURL)
        // Immich authenticates the websocket handshake like any API request:
        // x-api-key, bearer session token, or the access-token cookie (what the
        // mobile app uses). Send all available credentials for compatibility.
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        if let sessionToken {
            request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
            request.setValue("immich_access_token=\(sessionToken)", forHTTPHeaderField: "Cookie")
        }

        let task = session.webSocketTask(with: request)
        currentTask = task
        task.resume()
        defer {
            task.cancel(with: .goingAway, reason: nil)
            if currentTask === task { currentTask = nil }
        }

        // Watchdog: if the server goes silent past ping interval + timeout the
        // link is dead (e.g. after Mac sleep) — bail out and reconnect.
        var receiveTimeout: Double = 45

        while running, !Task.isCancelled {
            let message = try await receive(task: task, timeout: receiveTimeout)
            guard case .string(let text) = message else { continue }

            switch SocketIOFrame.parse(text) {
            case .open(let pingIntervalMs, let pingTimeoutMs):
                receiveTimeout = Double(pingIntervalMs + pingTimeoutMs) / 1000 + 5
                try await task.send(.string("40"))
            case .ping:
                try await task.send(.string("3"))
            case .namespaceConnected:
                connectedAt = Date()
                AppLogger.syncStream.info("Event socket connected — realtime updates active")
                // Catch-up: events during the disconnect window are lost; one
                // sync round brings us back to server state via checkpoints.
                // Der Asset-Teil geht an `onConnected`, damit der Koordinator ihn
                // beim ersten Verbinden direkt nach dem Start-Sync weglassen kann.
                onConnected()
                schedule(.albums)
            case .namespaceError(let detail):
                AppLogger.syncStream.warning("Event socket namespace error: \(detail)")
                throw SocketError.namespaceError(detail)
            case .event(let name):
                if let category = ImmichEventClassifier.classify(name) {
                    schedule(category)
                }
            case .close:
                return
            case .other:
                break
            }
        }
    }

    private enum SocketError: Error {
        case namespaceError(String)
        case receiveTimeout
    }

    /// Receive one message, failing if the server stays silent past `timeout`.
    private func receive(
        task: URLSessionWebSocketTask,
        timeout: Double
    ) async throws -> URLSessionWebSocketTask.Message {
        try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message?.self) { group in
            group.addTask { try await task.receive() }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return nil
            }
            guard let message = try await group.next() ?? nil else {
                group.cancelAll()
                task.cancel(with: .abnormalClosure, reason: nil)
                throw SocketError.receiveTimeout
            }
            group.cancelAll()
            return message
        }
    }

    // MARK: - Debounced Dispatch

    private func schedule(_ category: ImmichEventClassifier.Category) {
        pendingCategories.insert(category)
        guard debounceTask == nil else { return }
        debounceTask = Task { [debounceInterval] in
            try? await Task.sleep(for: debounceInterval)
            self.flushPending()
        }
    }

    private func flushPending() {
        debounceTask = nil
        let categories = pendingCategories
        pendingCategories.removeAll()
        guard !Task.isCancelled else { return }
        if categories.contains(.assets) { onAssetsChanged() }
        if categories.contains(.albums) { onAlbumsChanged() }
    }
}
