import Foundation
import SwiftData
import Observation

/// Observed store for persisted sync/upload log entries.
/// Keeps the last `maxEntries` rows; prunes older ones automatically.
/// Access from `@MainActor` only — matches the `@Observable` requirement.
@Observable
@MainActor
final class SyncLogStore {
    static let shared = SyncLogStore()

    // MARK: - Config

    static let maxEntries = 100

    // MARK: - Published State

    /// Last `maxEntries` runs, most recent first.
    private(set) var entries: [SyncLogEntry] = []

    /// Warnings that the user has manually dismissed (in-memory only).
    private var acknowledgedIDs: Set<PersistentIdentifier> = []

    /// Accumulated checksum mismatches over all stored entries.
    var totalChecksumMismatches: Int {
        entries.reduce(0) { $0 + $1.checksumMismatchCount }
    }

    /// The most recent entry that carries a warning and has not been acknowledged.
    var latestWarningEntry: SyncLogEntry? {
        entries.first(where: { $0.hasWarning && !acknowledgedIDs.contains($0.persistentModelID) })
    }

    /// Dismiss the warning banner for `entry` until the next new warning arrives.
    func acknowledgeWarning(_ entry: SyncLogEntry) {
        acknowledgedIDs.insert(entry.persistentModelID)
    }

    /// Most recent sync entry (kind == .sync).
    var lastSyncEntry: SyncLogEntry? {
        entries.first(where: { $0.kindEnum == .sync })
    }

    /// Most recent upload entry (kind == .upload) that has failures or mismatches.
    var lastUploadWarning: SyncLogEntry? {
        entries.first(where: { $0.kindEnum == .upload && $0.hasWarning })
    }

    // MARK: - Internal

    private var modelContext: ModelContext?

    private init() {}

    /// Call once from the owning view with the SwiftData context.
    func configure(modelContext: ModelContext) {
        self.modelContext = modelContext
        reload()
    }

    // MARK: - Public API

    func append(_ entry: SyncLogEntry) {
        guard let ctx = modelContext else { return }
        ctx.insert(entry)
        entries.insert(entry, at: 0)
        try? ctx.save()
        pruneIfNeeded()
    }

    func reload() {
        guard let ctx = modelContext else { return }
        var descriptor = FetchDescriptor<SyncLogEntry>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = Self.maxEntries
        entries = (try? ctx.fetch(descriptor)) ?? []
    }

    func clear() {
        guard let ctx = modelContext else { return }
        try? ctx.delete(model: SyncLogEntry.self)
        try? ctx.save()
        entries.removeAll()
    }

    // MARK: - Private

    private func pruneIfNeeded() {
        guard let ctx = modelContext, entries.count > Self.maxEntries else { return }
        // Fetch oldest entries beyond the cap
        var descriptor = FetchDescriptor<SyncLogEntry>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchOffset = Self.maxEntries
        let toDelete = (try? ctx.fetch(descriptor)) ?? []
        for entry in toDelete {
            ctx.delete(entry)
        }
        try? ctx.save()
        entries = Array(entries.prefix(Self.maxEntries))
    }
}
