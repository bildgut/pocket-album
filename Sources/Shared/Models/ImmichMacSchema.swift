import SwiftData
import Foundation

// MARK: - Schema Versioning
//
// Jede Änderung an einem @Model (neue Felder, Typ-Änderungen) erfordert:
// 1. Eine neue enum im entsprechenden VersionedSchema (z.B. SchemaV2, SchemaV3, …)
// 2. Einen neuen MigrationStage in ImmichMacMigrationPlan
//
// SwiftData Lightweight Migration funktioniert automatisch wenn:
//  - Neue Felder einen Default-Wert haben (var foo: Int = 0)
//  - Felder optional werden (var foo: String?)
//
// Für komplexere Änderungen: .custom(willMigrate:didMigrate:) Stage verwenden.

// MARK: - Eingefrorene Model-Kopien für Staged Migration
//
// Bis einschließlich V3 hatte ApplePhotosAssetMapping kein lastUploadedFileSize.
// Die historischen Schema-Versionen MÜSSEN diese alte Form referenzieren:
// Würden sie die Live-Klasse teilen, hätten V3 und V4 identische Checksums
// ("Duplicate version checksums detected"-Crash beim Start) und der Checksum
// des On-Disk-Stores würde keiner bekannten Version mehr entsprechen.
// Der Klassenname bestimmt den Entity-Namen und muss dem Original entsprechen.
enum FrozenSchemaV3 {
    @Model
    final class ApplePhotosAssetMapping {
        @Attribute(.unique) var localIdentifier: String
        var immichAssetId: String
        var lastKnownModificationDate: Date?
        var uploadedAt: Date

        init(
            localIdentifier: String,
            immichAssetId: String,
            lastKnownModificationDate: Date?,
            uploadedAt: Date = Date()
        ) {
            self.localIdentifier = localIdentifier
            self.immichAssetId = immichAssetId
            self.lastKnownModificationDate = lastKnownModificationDate
            self.uploadedAt = uploadedAt
        }
    }
}

// MARK: - V1 (Baseline – bis 2026-06-11)

enum SchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)
    static var models: [any PersistentModel.Type] {
        [
            CachedAsset.self,
            CachedAlbum.self,
            SyncState.self,
            PendingAction.self,
            ApplePhotosSyncState.self,
            FrozenSchemaV3.ApplePhotosAssetMapping.self,
            CachedAssetEdit.self,
            SyncPairing.self,
            SmartAlbum.self,
            UploadQueueEntry.self,
            SyncLogEntry.self,
        ]
    }
}

// MARK: - V2 (2026-06-12 – SmartAlbumFolder + SmartAlbum.folderID/sortIndex)

enum SchemaV2: VersionedSchema {
    static var versionIdentifier = Schema.Version(2, 0, 0)
    static var models: [any PersistentModel.Type] {
        [
            CachedAsset.self,
            CachedAlbum.self,
            SyncState.self,
            PendingAction.self,
            ApplePhotosSyncState.self,
            FrozenSchemaV3.ApplePhotosAssetMapping.self,
            CachedAssetEdit.self,
            SyncPairing.self,
            SmartAlbum.self,
            SmartAlbumFolder.self,
            UploadQueueEntry.self,
            SyncLogEntry.self,
        ]
    }
}

// MARK: - V3 (2026-06-15 – Apple Photos retry queue)

enum SchemaV3: VersionedSchema {
    static var versionIdentifier = Schema.Version(3, 0, 0)
    static var models: [any PersistentModel.Type] {
        [
            CachedAsset.self,
            CachedAlbum.self,
            SyncState.self,
            PendingAction.self,
            ApplePhotosSyncState.self,
            FrozenSchemaV3.ApplePhotosAssetMapping.self,
            ApplePhotosSyncFailure.self,
            CachedAssetEdit.self,
            SyncPairing.self,
            SmartAlbum.self,
            SmartAlbumFolder.self,
            UploadQueueEntry.self,
            SyncLogEntry.self,
        ]
    }
}

// MARK: - V4 (2026-07-09 – ApplePhotosAssetMapping.lastUploadedFileSize)

enum SchemaV4: VersionedSchema {
    static var versionIdentifier = Schema.Version(4, 0, 0)
    static var models: [any PersistentModel.Type] {
        [
            CachedAsset.self,
            CachedAlbum.self,
            SyncState.self,
            PendingAction.self,
            ApplePhotosSyncState.self,
            ApplePhotosAssetMapping.self,
            ApplePhotosSyncFailure.self,
            CachedAssetEdit.self,
            SyncPairing.self,
            SmartAlbum.self,
            SmartAlbumFolder.self,
            UploadQueueEntry.self,
            SyncLogEntry.self,
        ]
    }
}

// MARK: - V5 (2026-07-25 – ApplePhotosIgnoredAsset)

enum SchemaV5: VersionedSchema {
    static var versionIdentifier = Schema.Version(5, 0, 0)
    static var models: [any PersistentModel.Type] {
        [
            CachedAsset.self,
            CachedAlbum.self,
            SyncState.self,
            PendingAction.self,
            ApplePhotosSyncState.self,
            ApplePhotosAssetMapping.self,
            ApplePhotosSyncFailure.self,
            ApplePhotosIgnoredAsset.self,
            CachedAssetEdit.self,
            SyncPairing.self,
            SmartAlbum.self,
            SmartAlbumFolder.self,
            UploadQueueEntry.self,
            SyncLogEntry.self,
        ]
    }
}

// MARK: - V6 (2026-07-27 – GeoIgnoredAsset)

enum SchemaV6: VersionedSchema {
    static var versionIdentifier = Schema.Version(6, 0, 0)
    static var models: [any PersistentModel.Type] {
        [
            CachedAsset.self,
            CachedAlbum.self,
            SyncState.self,
            PendingAction.self,
            ApplePhotosSyncState.self,
            ApplePhotosAssetMapping.self,
            ApplePhotosSyncFailure.self,
            ApplePhotosIgnoredAsset.self,
            CachedAssetEdit.self,
            SyncPairing.self,
            SmartAlbum.self,
            SmartAlbumFolder.self,
            UploadQueueEntry.self,
            SyncLogEntry.self,
            GeoIgnoredAsset.self,
        ]
    }
}

// MARK: - V7 (2026-07-27 – DupeIgnoredPair)

enum SchemaV7: VersionedSchema {
    static var versionIdentifier = Schema.Version(7, 0, 0)
    static var models: [any PersistentModel.Type] {
        [
            CachedAsset.self,
            CachedAlbum.self,
            SyncState.self,
            PendingAction.self,
            ApplePhotosSyncState.self,
            ApplePhotosAssetMapping.self,
            ApplePhotosSyncFailure.self,
            ApplePhotosIgnoredAsset.self,
            CachedAssetEdit.self,
            SyncPairing.self,
            SmartAlbum.self,
            SmartAlbumFolder.self,
            UploadQueueEntry.self,
            SyncLogEntry.self,
            GeoIgnoredAsset.self,
            DupeIgnoredPair.self,
        ]
    }
}

enum SchemaV8: VersionedSchema {
    static var versionIdentifier = Schema.Version(8, 0, 0)
    static var models: [any PersistentModel.Type] {
        [
            CachedAsset.self,
            CachedAlbum.self,
            SyncState.self,
            PendingAction.self,
            ApplePhotosSyncState.self,
            ApplePhotosAssetMapping.self,
            ApplePhotosSyncFailure.self,
            ApplePhotosIgnoredAsset.self,
            CachedAssetEdit.self,
            SyncPairing.self,
            SmartAlbum.self,
            SmartAlbumFolder.self,
            UploadQueueEntry.self,
            SyncLogEntry.self,
            GeoIgnoredAsset.self,
            DupeIgnoredPair.self,
            DateFixUndoEntry.self,
        ]
    }
}

// MARK: - V9 (2026-08-09 – OfflinePin)

enum SchemaV9: VersionedSchema {
    static var versionIdentifier = Schema.Version(9, 0, 0)
    static var models: [any PersistentModel.Type] {
        [
            CachedAsset.self,
            CachedAlbum.self,
            SyncState.self,
            PendingAction.self,
            ApplePhotosSyncState.self,
            ApplePhotosAssetMapping.self,
            ApplePhotosSyncFailure.self,
            ApplePhotosIgnoredAsset.self,
            CachedAssetEdit.self,
            SyncPairing.self,
            SmartAlbum.self,
            SmartAlbumFolder.self,
            UploadQueueEntry.self,
            SyncLogEntry.self,
            GeoIgnoredAsset.self,
            DupeIgnoredPair.self,
            DateFixUndoEntry.self,
            OfflinePin.self,
        ]
    }
}

// MARK: - V10 (2026-08-10 – TripIgnoredAsset)

enum SchemaV10: VersionedSchema {
    static var versionIdentifier = Schema.Version(10, 0, 0)
    static var models: [any PersistentModel.Type] {
        [
            CachedAsset.self,
            CachedAlbum.self,
            SyncState.self,
            PendingAction.self,
            ApplePhotosSyncState.self,
            ApplePhotosAssetMapping.self,
            ApplePhotosSyncFailure.self,
            ApplePhotosIgnoredAsset.self,
            CachedAssetEdit.self,
            SyncPairing.self,
            SmartAlbum.self,
            SmartAlbumFolder.self,
            UploadQueueEntry.self,
            SyncLogEntry.self,
            GeoIgnoredAsset.self,
            DupeIgnoredPair.self,
            DateFixUndoEntry.self,
            OfflinePin.self,
            TripIgnoredAsset.self,
        ]
    }
}

// MARK: - V11 (2026-08-11 – RawDevelopState + DevelopPreset)

enum SchemaV11: VersionedSchema {
    static var versionIdentifier = Schema.Version(11, 0, 0)
    static var models: [any PersistentModel.Type] {
        [
            CachedAsset.self,
            CachedAlbum.self,
            SyncState.self,
            PendingAction.self,
            ApplePhotosSyncState.self,
            ApplePhotosAssetMapping.self,
            ApplePhotosSyncFailure.self,
            ApplePhotosIgnoredAsset.self,
            CachedAssetEdit.self,
            SyncPairing.self,
            SmartAlbum.self,
            SmartAlbumFolder.self,
            UploadQueueEntry.self,
            SyncLogEntry.self,
            GeoIgnoredAsset.self,
            DupeIgnoredPair.self,
            DateFixUndoEntry.self,
            OfflinePin.self,
            TripIgnoredAsset.self,
            RawDevelopState.self,
            DevelopPreset.self,
        ]
    }
}

// MARK: - V12 (2026-08-14 – LandmarkFinding)

enum SchemaV12: VersionedSchema {
    static var versionIdentifier = Schema.Version(12, 0, 0)
    static var models: [any PersistentModel.Type] {
        [
            CachedAsset.self,
            CachedAlbum.self,
            SyncState.self,
            PendingAction.self,
            ApplePhotosSyncState.self,
            ApplePhotosAssetMapping.self,
            ApplePhotosSyncFailure.self,
            ApplePhotosIgnoredAsset.self,
            CachedAssetEdit.self,
            SyncPairing.self,
            SmartAlbum.self,
            SmartAlbumFolder.self,
            UploadQueueEntry.self,
            SyncLogEntry.self,
            GeoIgnoredAsset.self,
            DupeIgnoredPair.self,
            DateFixUndoEntry.self,
            OfflinePin.self,
            TripIgnoredAsset.self,
            RawDevelopState.self,
            DevelopPreset.self,
            LandmarkFinding.self,
        ]
    }
}

// MARK: - V13 (2026-08-16 – ApplePhotoDeletionFinding)

enum SchemaV13: VersionedSchema {
    static var versionIdentifier = Schema.Version(13, 0, 0)
    static var models: [any PersistentModel.Type] {
        SchemaV12.models + [ApplePhotoDeletionFinding.self]
    }
}

// MARK: - V14 (2026-09-24 – InfoBildBefund)

enum SchemaV14: VersionedSchema {
    static var versionIdentifier = Schema.Version(14, 0, 0)
    static var models: [any PersistentModel.Type] {
        SchemaV13.models + [InfoBildBefund.self]
    }
}

// MARK: - Migration Plan

enum ImmichMacMigrationPlan: SchemaMigrationPlan {
    static let currentSchema: any VersionedSchema.Type = SchemaV14.self

    static var schemas: [any VersionedSchema.Type] {
        [
            SchemaV1.self, SchemaV2.self, SchemaV3.self, SchemaV4.self,
            SchemaV5.self, SchemaV6.self, SchemaV7.self, SchemaV8.self,
            SchemaV9.self, SchemaV10.self, SchemaV11.self, SchemaV12.self,
            SchemaV13.self, SchemaV14.self,
        ]
    }

    static var stages: [MigrationStage] {
        [migrateV1toV2, migrateV2toV3, migrateV3toV4, migrateV4toV5,
         migrateV5toV6, migrateV6toV7, migrateV7toV8, migrateV8toV9,
         migrateV9toV10, migrateV10toV11, migrateV11toV12, migrateV12toV13,
         migrateV13toV14]
    }

    /// V1 → V2: SmartAlbumFolder hinzugefügt, SmartAlbum bekommt folderID (optional) und sortIndex (Int = 0).
    /// Beide neuen Felder haben Defaults → Lightweight Migration reicht aus.
    static let migrateV1toV2 = MigrationStage.lightweight(
        fromVersion: SchemaV1.self,
        toVersion: SchemaV2.self
    )

    /// V2 → V3: persistente Retry-Liste für fehlgeschlagene Apple-Photos-Assets.
    /// Neue State-Felder haben Defaults, das neue Model startet leer → Lightweight Migration reicht.
    static let migrateV2toV3 = MigrationStage.lightweight(
        fromVersion: SchemaV2.self,
        toVersion: SchemaV3.self
    )

    /// V3 → V4: ApplePhotosAssetMapping bekommt lastUploadedFileSize (optional) →
    /// Lightweight Migration reicht.
    static let migrateV3toV4 = MigrationStage.lightweight(
        fromVersion: SchemaV3.self,
        toVersion: SchemaV4.self
    )

    /// V4 → V5: ApplePhotosIgnoredAsset hinzugefügt. Nur eine neue, leer startende
    /// Entity — kein bestehendes Model ändert sich, daher braucht V4 keine
    /// eingefrorene Kopie und Lightweight Migration reicht.
    static let migrateV4toV5 = MigrationStage.lightweight(
        fromVersion: SchemaV4.self,
        toVersion: SchemaV5.self
    )

    /// V5 → V6: GeoIgnoredAsset hinzugefügt (Merkliste des GPS-Abgleichs). Wieder nur
    /// eine neue, leer startende Entity — kein bestehendes Model ändert sich, daher
    /// braucht V5 keine eingefrorene Kopie und Lightweight Migration reicht.
    static let migrateV5toV6 = MigrationStage.lightweight(
        fromVersion: SchemaV5.self,
        toVersion: SchemaV6.self
    )

    /// V6 → V7: DupeIgnoredPair hinzugefügt (Merkliste der Duplikatsuche). Erneut nur
    /// eine neue, leer startende Entity — kein bestehendes Model ändert sich, daher
    /// braucht V6 keine eingefrorene Kopie und Lightweight Migration reicht.
    static let migrateV6toV7 = MigrationStage.lightweight(
        fromVersion: SchemaV6.self,
        toVersion: SchemaV7.self
    )

    /// V7 → V8: DateFixUndoEntry hinzugefügt (Rücknahme der Datumskorrektur).
    /// Wieder nur eine neue, leer startende Entity — kein bestehendes Model ändert
    /// sich, daher braucht V7 keine eingefrorene Kopie und Lightweight Migration
    /// reicht.
    static let migrateV7toV8 = MigrationStage.lightweight(
        fromVersion: SchemaV7.self,
        toVersion: SchemaV8.self
    )

    /// V8 → V9: OfflinePin hinzugefügt (was offline vorgehalten wird — Alben und Smart
    /// Alben gemeinsam). Wieder nur eine neue, leer startende Entity; kein bestehendes
    /// Model ändert sich, daher braucht V8 keine eingefrorene Kopie und Lightweight
    /// Migration reicht. Die Übernahme der alten `CachedAlbum.isMarkedForOffline`-Flags
    /// passiert bewusst **nicht** hier, sondern beim ersten Start in
    /// `OfflinePinStore.migrateLegacyFlags` — sie braucht keine Schema-Stufe und wäre
    /// in einer Migration nur schwerer zu testen.
    static let migrateV8toV9 = MigrationStage.lightweight(
        fromVersion: SchemaV8.self,
        toVersion: SchemaV9.self
    )

    /// V9 → V10: TripIgnoredAsset hinzugefügt (Merkliste der Albumvorschläge).
    /// Wieder nur eine neue, leer startende Entity — kein bestehendes Model ändert
    /// sich, daher braucht V9 keine eingefrorene Kopie und Lightweight Migration
    /// reicht.
    static let migrateV9toV10 = MigrationStage.lightweight(
        fromVersion: SchemaV9.self,
        toVersion: SchemaV10.self
    )

    /// V10 → V11: RawDevelopState + DevelopPreset hinzugefügt (RAW-Develop-Modul).
    /// Wieder nur zwei neue, leer startende Entities; kein bestehendes Model ändert
    /// sich, daher braucht V10 keine eingefrorene Kopie und Lightweight Migration
    /// reicht.
    static let migrateV10toV11 = MigrationStage.lightweight(
        fromVersion: SchemaV10.self,
        toVersion: SchemaV11.self
    )

    /// V11 → V12: LandmarkFinding hinzugefügt (Wahrzeichen-Erkennung im
    /// GPS-Assistenten). Eine einzelne neue, leer startende Entity; kein
    /// bestehendes Model ändert sich, daher braucht V11 keine eingefrorene Kopie
    /// und Lightweight Migration reicht.
    static let migrateV11toV12 = MigrationStage.lightweight(
        fromVersion: SchemaV11.self,
        toVersion: SchemaV12.self
    )

    /// V12 → V13: ApplePhotoDeletionFinding hinzugefügt (Befundjournal der
    /// Apple-Photos-Löschprüfung). Eine einzelne neue, leer startende Entity; kein
    /// bestehendes Model ändert sich, daher reicht Lightweight Migration.
    static let migrateV12toV13 = MigrationStage.lightweight(
        fromVersion: SchemaV12.self,
        toVersion: SchemaV13.self
    )

    /// V13 → V14: InfoBildBefund hinzugefügt (Rubriken Dokumente/Screenshots).
    /// Nur eine neue, leer startende Entity — kein bestehendes Model ändert sich,
    /// daher reicht Lightweight Migration.
    static let migrateV13toV14 = MigrationStage.lightweight(
        fromVersion: SchemaV13.self,
        toVersion: SchemaV14.self
    )
}
