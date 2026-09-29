import os

/// Centralized loggers for structured logging via Console.app.
///
/// Usage: `AppLogger.sync.info("Delta sync found \(count) changes")`
/// In Console.app, filter by Subsystem "com.ralksta.immichmac".
enum AppLogger {
    private static let subsystem = "com.ralksta.immichmac"

    /// Connection lifecycle (connect, disconnect, reconnect, network monitor)
    static let connection = Logger(subsystem: subsystem, category: "connection")

    /// Sync engine (initial sync, delta sync, reconciliation)
    static let sync = Logger(subsystem: subsystem, category: "sync")

    /// Sync stream (checkpoint HTTP sync) and realtime event socket
    static let syncStream = Logger(subsystem: subsystem, category: "syncStream")

    /// API client (requests, responses, errors)
    static let api = Logger(subsystem: subsystem, category: "api")

    /// Upload manager (queue, progress, completion)
    static let upload = Logger(subsystem: subsystem, category: "upload")

    /// Offline action queue (enqueue, replay, retry)
    static let offline = Logger(subsystem: subsystem, category: "offline")

    /// Library view model (cache loading, media types)
    static let library = Logger(subsystem: subsystem, category: "library")

    /// UI / Views (navigation, selection, grid)
    static let ui = Logger(subsystem: subsystem, category: "ui")

    /// General app lifecycle
    static let app = Logger(subsystem: subsystem, category: "app")

    /// Local file cache (download, eviction, disk usage)
    static let cache = Logger(subsystem: subsystem, category: "cache")

    // MARK: - Performance Signposts (Instruments → Points of Interest)

    /// Grid performance: cache recomputation, layout, snapshot apply
    static let gridPerf = OSLog(subsystem: subsystem, category: "gridPerf")

    /// Data loading: SwiftData fetch, API calls
    static let dataPerf = OSLog(subsystem: subsystem, category: "dataPerf")

    /// Image pipeline: thumbnail load, prefetch
    static let imagePerf = OSLog(subsystem: subsystem, category: "imagePerf")

    /// Rahmen der Instruments-Messläufe (`PerfMesslauf`, `scripts/perf/messlauf.sh`)
    static let perfLauf = OSLog(subsystem: subsystem, category: "perfLauf")
}

