import Foundation
import SwiftData

// MARK: - Log Kind

enum SyncLogKind: String, Codable, Sendable {
    case sync
    case upload
}

// MARK: - SwiftData Model

/// Persistent record of a single sync run or upload batch.
/// The store is capped to the last 100 entries (pruned by SyncLogStore).
@Model
final class SyncLogEntry {

    // MARK: Stored Properties

    var timestamp: Date
    /// Raw value of SyncLogKind
    var kind: String
    /// For sync entries: SyncTrigger.rawValue. For upload entries: session label.
    var trigger: String
    /// Raw value of SyncTransport (empty string for upload entries)
    var transport: String
    var changedCount: Int
    var uploadedCount: Int
    var duplicateCount: Int
    var failedCount: Int
    var checksumMismatchCount: Int
    var durationSeconds: Double
    var errorMessage: String?

    init(
        timestamp: Date = .now,
        kind: SyncLogKind,
        trigger: String,
        transport: SyncTransport = .none,
        changedCount: Int = 0,
        uploadedCount: Int = 0,
        duplicateCount: Int = 0,
        failedCount: Int = 0,
        checksumMismatchCount: Int = 0,
        durationSeconds: Double = 0,
        errorMessage: String? = nil
    ) {
        self.timestamp = timestamp
        self.kind = kind.rawValue
        self.trigger = trigger
        self.transport = transport.rawValue
        self.changedCount = changedCount
        self.uploadedCount = uploadedCount
        self.duplicateCount = duplicateCount
        self.failedCount = failedCount
        self.checksumMismatchCount = checksumMismatchCount
        self.durationSeconds = durationSeconds
        self.errorMessage = errorMessage
    }

    // MARK: Computed Helpers

    var kindEnum: SyncLogKind { SyncLogKind(rawValue: kind) ?? .sync }
    var transportEnum: SyncTransport { SyncTransport(rawValue: transport) ?? .none }

    /// True if this entry contains any error or integrity warning.
    var hasWarning: Bool {
        errorMessage != nil || failedCount > 0 || checksumMismatchCount > 0
    }

    var durationFormatted: String {
        durationSeconds < 1 ? "<1s" : "\(Int(durationSeconds.rounded()))s"
    }
}
