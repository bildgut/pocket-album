import Foundation
import SwiftData
// SyncTransport is defined in SyncEngine.swift and is Codable

@Model
final class SyncState {
    var lastSyncTimestamp: Date?
    var totalAssetCount: Int
    var lastSyncDuration: TimeInterval
    var isInitialSyncComplete: Bool
    /// JSON-serialized map: sync type -> last acknowledged checkpoint
    var lastStreamAckByType: String
    var lastSuccessfulStreamAt: Date?
    var syncTransport: SyncTransport
    var serverSupportsStream: Bool
    var streamAuthAvailable: Bool
    var lastTrashReconcileAt: Date?
    /// Tracks the last time the deletion-reconciliation ran in the polling sync path.
    /// Used to throttle the check to at most once every 5 minutes during background polls.
    var lastDeletionReconcileAt: Date?
    /// Marks the one-time EXIF migration/backfill as completed so it does not
    /// run again on every app launch.
    var exifBackfillCompletedAt: Date?

    init() {
        self.lastSyncTimestamp = nil
        self.totalAssetCount = 0
        self.lastSyncDuration = 0
        self.isInitialSyncComplete = false
        self.lastStreamAckByType = "{}"
        self.lastSuccessfulStreamAt = nil
        self.syncTransport = .none
        self.serverSupportsStream = true
        self.streamAuthAvailable = false
        self.lastTrashReconcileAt = nil
        self.lastDeletionReconcileAt = nil
        self.exifBackfillCompletedAt = nil
    }
}

@Model
final class ApplePhotosSyncState {
    var lastSuccessfulSyncAt: Date?
    var lastAttemptAt: Date?
    var lastError: String?
    var lastRunWindowAssetCount: Int
    var lastRunScannedCount: Int
    var lastRunSkippedByMappingCount: Int
    var lastRunAlreadyPresentCount: Int
    var lastRunEnqueuedCount: Int
    var lastRunRetriedCount: Int = 0
    var lastRunFailedCount: Int
    var pendingFailureCount: Int = 0
    var isRunning: Bool

    init() {
        self.lastSuccessfulSyncAt = nil
        self.lastAttemptAt = nil
        self.lastError = nil
        self.lastRunWindowAssetCount = 0
        self.lastRunScannedCount = 0
        self.lastRunSkippedByMappingCount = 0
        self.lastRunAlreadyPresentCount = 0
        self.lastRunEnqueuedCount = 0
        self.lastRunRetriedCount = 0
        self.lastRunFailedCount = 0
        self.pendingFailureCount = 0
        self.isRunning = false
    }
}

@Model
final class ApplePhotosSyncFailure {
    @Attribute(.unique) var localIdentifier: String
    var originalFilename: String
    var creationDate: Date?
    var modificationDate: Date?
    var lastError: String
    var attemptCount: Int
    var lastAttemptAt: Date?
    var nextRetryAt: Date?

    init(
        localIdentifier: String,
        originalFilename: String,
        creationDate: Date?,
        modificationDate: Date?,
        lastError: String,
        attemptCount: Int = 0,
        lastAttemptAt: Date? = nil,
        nextRetryAt: Date? = nil
    ) {
        self.localIdentifier = localIdentifier
        self.originalFilename = originalFilename
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.lastError = lastError
        self.attemptCount = attemptCount
        self.lastAttemptAt = lastAttemptAt
        self.nextRetryAt = nextRetryAt
    }
}

/// Warum ein Asset nicht mehr vorgeschlagen wird.
enum ApplePhotosIgnoreReason: String, Sendable, CaseIterable {
    /// Beim Sichern abgewählt — implizit ignoriert.
    case deselected
    /// Explizit über "Nie sichern" markiert.
    case explicit
}

/// Apple-Photos-Assets, die dauerhaft nicht mehr zum Sichern vorgeschlagen werden.
/// Ohne diese Liste taucht jedes bewusst abgewählte Foto bei jedem Scan erneut auf:
/// Die Auswahl im Vorschau-Dialog ist reiner View-State, und weder Mapping noch
/// Failure-Eintrag entstehen für etwas, das nie hochgeladen wurde.
@Model
final class ApplePhotosIgnoredAsset {
    @Attribute(.unique) var localIdentifier: String
    var originalFilename: String
    var creationDate: Date?
    var ignoredAt: Date
    /// Rohwert von `ApplePhotosIgnoreReason` — SwiftData speichert keine Enums direkt.
    var reasonRaw: String

    var reason: ApplePhotosIgnoreReason {
        ApplePhotosIgnoreReason(rawValue: reasonRaw) ?? .deselected
    }

    init(
        localIdentifier: String,
        originalFilename: String,
        creationDate: Date?,
        ignoredAt: Date = Date(),
        reason: ApplePhotosIgnoreReason = .deselected
    ) {
        self.localIdentifier = localIdentifier
        self.originalFilename = originalFilename
        self.creationDate = creationDate
        self.ignoredAt = ignoredAt
        self.reasonRaw = reason.rawValue
    }
}

@Model
final class ApplePhotosAssetMapping {
    @Attribute(.unique) var localIdentifier: String
    var immichAssetId: String
    var lastKnownModificationDate: Date?
    var uploadedAt: Date
    /// Dateigröße der zuletzt hochgeladenen Ressource. Unterscheidet echte Edits
    /// (Größe ändert sich) von reinen Metadaten-Bumps des modificationDate
    /// (Favorit, Album, Bildanalyse), die keinen Re-Upload rechtfertigen.
    var lastUploadedFileSize: Int64?

    init(
        localIdentifier: String,
        immichAssetId: String,
        lastKnownModificationDate: Date?,
        uploadedAt: Date = Date(),
        lastUploadedFileSize: Int64? = nil
    ) {
        self.localIdentifier = localIdentifier
        self.immichAssetId = immichAssetId
        self.lastKnownModificationDate = lastKnownModificationDate
        self.uploadedAt = uploadedAt
        self.lastUploadedFileSize = lastUploadedFileSize
    }
}
