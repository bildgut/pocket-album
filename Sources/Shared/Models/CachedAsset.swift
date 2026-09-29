import Foundation
import SwiftData

@Model
final class CachedAsset {
    #Index<CachedAsset>([\.assetId], [\.type], [\.isTrashed], [\.isFavorite], [\.isArchived])

    @Attribute(.unique) var assetId: String
    var type: String           // "IMAGE", "VIDEO", "AUDIO", "OTHER"
    var originalFileName: String
    var originalPath: String?
    var fileCreatedAt: String
    var fileModifiedAt: String
    var isFavorite: Bool
    var isArchived: Bool
    var isTrashed: Bool
    var isHidden: Bool
    var duration: String?
    var thumbhash: String?

    // EXIF subset — flattened for query performance
    var width: Int?
    var height: Int?
    var city: String?
    var country: String?
    var latitude: Double?
    var longitude: Double?
    var cameraMake: String?
    var cameraModel: String?
    var focalLength: Double?
    var fNumber: Double?
    var iso: Double?
    var exposureTime: String?
    var lensModel: String?
    var fileSizeInByte: Int?
    var state: String?

    // MARK: - Stack
    var stackId: String?
    /// Total number of assets in the stack (nil = not stacked / unknown)
    var stackCount: Int?
    var livePhotoVideoId: String?

    // MARK: - Local File Cache
    /// Relative path within OriginalCache/ directory (nil = not locally cached)
    var localFilePath: String?

    init(from asset: Asset) {
        self.assetId = asset.id
        self.type = asset.type.rawValue
        self.originalFileName = asset.originalFileName
        self.originalPath = asset.originalPath
        self.fileCreatedAt = asset.fileCreatedAt
        self.fileModifiedAt = asset.fileModifiedAt
        self.isFavorite = asset.isFavorite
        self.isArchived = asset.isArchived
        self.isTrashed = asset.isTrashed
        self.isHidden = false
        self.duration = asset.duration
        self.thumbhash = asset.thumbhash
        self.stackId = asset.stackId
        self.stackCount = asset.stackCount
        self.livePhotoVideoId = asset.livePhotoVideoId

        // Store dimensions from top-level API fields (more reliable than exifInfo)
        self.width = asset.effectiveWidth
        self.height = asset.effectiveHeight

        if let exif = asset.exifInfo {
            // Fill in width/height from EXIF if top-level was nil
            if self.width == nil { self.width = exif.exifImageWidth }
            if self.height == nil { self.height = exif.exifImageHeight }
            self.city = exif.city
            self.country = exif.country
            self.latitude = exif.latitude
            self.longitude = exif.longitude
            self.cameraMake = exif.make
            self.cameraModel = exif.model
            self.focalLength = exif.focalLength
            self.fNumber = exif.fNumber
            self.iso = exif.iso
            self.exposureTime = exif.exposureTime
            self.lensModel = exif.lensModel
            self.fileSizeInByte = exif.fileSizeInByte
            self.state = exif.state
        }
    }

    /// Create from Sync Stream asset (SyncAssetV1)
    init(fromSync asset: SyncAsset) {
        self.assetId = asset.id
        self.type = asset.type    // Already "IMAGE" / "VIDEO"
        self.originalFileName = asset.originalFileName
        // `localDateTime` ist die **Ortszeit der Aufnahme**, kein UTC-Zeitstempel —
        // als Rückfall für `fileCreatedAt` eingesetzt, verschiebt es den Wert um
        // den Zonenversatz (bis 14 h). Das ist Absicht und bleibt so:
        //
        // Erstens greift der Rückfall in der Praxis nicht. Beide Felder befüllt
        // Immich in derselben Metadaten-Extraktion; fehlt `fileCreatedAt`, fehlt
        // `localDateTime` fast immer mit, und heraus kommt ohnehin `""`. Gemessen
        // an dieser Mediathek (06.09.2026): 165.240 Assets in Grid-Index und
        // SwiftData-Store, **null** davon mit leerem `fileCreatedAt`.
        //
        // Zweitens wäre die naheliegende „Korrektur" — den Rückfall streichen —
        // eine Verschlechterung. Der einzige Fall, in dem sie etwas ändert, ist
        // `fileCreatedAt == nil`, `localDateTime != nil`; dort stünde dann `""`
        // statt eines um den Zonenversatz verschobenen Zeitstempels. `""` ergibt
        // in `Asset.monthKey` keinen brauchbaren Schlüssel: Das Foto verschwände
        // aus jeder Datumsgruppe, statt bloß im falschen Nachbartag zu landen.
        //
        // Wer hier je genauer werden will, braucht keinen anderen Rückfall,
        // sondern ein eigenes Feld — siehe den Hinweis zu `localDateTime` unten.
        self.fileCreatedAt = asset.fileCreatedAt ?? asset.localDateTime ?? ""
        self.fileModifiedAt = asset.fileModifiedAt ?? ""
        self.isFavorite = asset.isFavorite
        self.isArchived = asset.visibility == "archive"
        self.isTrashed = asset.deletedAt != nil
        self.isHidden = asset.visibility == "hidden"
        self.duration = asset.duration
        self.thumbhash = asset.thumbhash
        // Sync stream carries stackId but not stackCount
        self.stackId = asset.stackId
        self.stackCount = nil
        self.livePhotoVideoId = asset.livePhotoVideoId
    }

    /// Update from Sync Stream asset
    func update(fromSync asset: SyncAsset) -> Bool {
        var changed = false
        if self.type != asset.type { self.type = asset.type; changed = true }
        if self.originalFileName != asset.originalFileName { self.originalFileName = asset.originalFileName; changed = true }
        // Gleiche Kette wie in `init(fromSync:)`, gleiche Begründung dort.
        let newCreatedAt = asset.fileCreatedAt ?? asset.localDateTime ?? ""
        if self.fileCreatedAt != newCreatedAt { self.fileCreatedAt = newCreatedAt; changed = true }
        let newModifiedAt = asset.fileModifiedAt ?? ""
        if self.fileModifiedAt != newModifiedAt { self.fileModifiedAt = newModifiedAt; changed = true }
        if self.isFavorite != asset.isFavorite { self.isFavorite = asset.isFavorite; changed = true }
        let newArchived = asset.visibility == "archive"
        if self.isArchived != newArchived { self.isArchived = newArchived; changed = true }
        let newTrashed = asset.deletedAt != nil
        if self.isTrashed != newTrashed { self.isTrashed = newTrashed; changed = true }
        let newHidden = asset.visibility == "hidden"
        if self.isHidden != newHidden { self.isHidden = newHidden; changed = true }
        if self.duration != asset.duration { self.duration = asset.duration; changed = true }
        if self.thumbhash != asset.thumbhash { self.thumbhash = asset.thumbhash; changed = true }
        if self.livePhotoVideoId != asset.livePhotoVideoId { self.livePhotoVideoId = asset.livePhotoVideoId; changed = true }
        // `init(fromSync:)` liest `stackId`, dieses Update tat es nicht: Ein Asset, das
        // der Index schon kennt, behielt seine alte Stapelzugehörigkeit für immer.
        // Stapeln und Auflösen im Web kamen über den Stream also nie an — und der
        // Grid-Index führt `stackId` gar nicht, hier ist der einzige Ort.
        if self.stackId != asset.stackId {
            self.stackId = asset.stackId
            // Die Anzahl beschrieb den *alten* Stapel. Der Stream liefert keine neue
            // (siehe `init(fromSync:)`), und ein aufgelöstes Foto mit „3" wäre falscher
            // als gar keine Angabe. Der Polling-Pfad füllt sie beim nächsten Lauf.
            self.stackCount = nil
            changed = true
        }
        return changed
    }

    /// EXIF aus dem Sync-Stream (`AssetExifV1`) übernehmen.
    ///
    /// **Maße:** Der Stream liefert die rohen Sensormaße — am 06.09.2026 über 154.966
    /// Stream-Zeilen ausgezählt: bei `orientation = 6` kamen 33.357-mal quere Maße und
    /// kein einziges hohes, obwohl das genau die hochkant fotografierten Bilder sind.
    /// ``ExifOrientation`` macht daraus die Anzeigegröße.
    ///
    /// Überschrieben wird nur, wo die Orientierung tatsächlich tauscht. Sonst gilt
    /// weiter „nur auffüllen": Ein Top-Level-Wert aus der API hat der rohen EXIF-Zeile
    /// nichts nachzustehen, und ein erster Anlauf, der jede EXIF-Zeile gewinnen liess,
    /// hat im Grid-Index die Zahl der Hochformate von 71.647 auf 37.653 gedrückt.
    ///
    /// Dieselbe Regel wie in `GridIndexStore.updateExifFromSync`, und das muss so sein:
    /// `upsertFromCache` schreibt diese Werte in den Index zurück: Stünde die Korrektur
    /// nur dort, machte der nächste Ladevorgang aus dem Cache sie wieder zunichte.
    ///
    /// Alle übrigen Felder überschreiben, auch mit nil: Eine GPS-Löschung auf dem
    /// Server muss lokal ankommen.
    func update(fromSyncExif exif: SyncAssetExif) -> Bool {
        var changed = false
        if let w = exif.exifImageWidth, let h = exif.exifImageHeight {
            let masse = ExifOrientation.displaySize(width: w, height: h,
                                                    orientation: exif.orientation)
            if ExifOrientation.swapsSides(exif.orientation) {
                if self.width != masse.width { self.width = masse.width; changed = true }
                if self.height != masse.height { self.height = masse.height; changed = true }
            } else {
                if self.width == nil { self.width = masse.width; changed = true }
                if self.height == nil { self.height = masse.height; changed = true }
            }
        }
        if self.city != exif.city { self.city = exif.city; changed = true }
        if self.state != exif.state { self.state = exif.state; changed = true }
        if self.country != exif.country { self.country = exif.country; changed = true }
        if self.latitude != exif.latitude { self.latitude = exif.latitude; changed = true }
        if self.longitude != exif.longitude { self.longitude = exif.longitude; changed = true }
        if self.cameraMake != exif.make { self.cameraMake = exif.make; changed = true }
        if self.cameraModel != exif.model { self.cameraModel = exif.model; changed = true }
        if self.lensModel != exif.lensModel { self.lensModel = exif.lensModel; changed = true }
        if self.fNumber != exif.fNumber { self.fNumber = exif.fNumber; changed = true }
        if self.focalLength != exif.focalLength { self.focalLength = exif.focalLength; changed = true }
        if self.iso != exif.iso { self.iso = exif.iso; changed = true }
        if self.exposureTime != exif.exposureTime { self.exposureTime = exif.exposureTime; changed = true }
        if self.fileSizeInByte != exif.fileSizeInByte { self.fileSizeInByte = exif.fileSizeInByte; changed = true }
        return changed
    }

    /// Update from a newer version of the API asset
    func update(from asset: Asset) -> Bool {
        var changed = false
        if self.type != asset.type.rawValue { self.type = asset.type.rawValue; changed = true }
        if self.originalFileName != asset.originalFileName { self.originalFileName = asset.originalFileName; changed = true }
        if self.originalPath != asset.originalPath { self.originalPath = asset.originalPath; changed = true }
        if self.fileCreatedAt != asset.fileCreatedAt { self.fileCreatedAt = asset.fileCreatedAt; changed = true }
        if self.fileModifiedAt != asset.fileModifiedAt { self.fileModifiedAt = asset.fileModifiedAt; changed = true }
        if self.isFavorite != asset.isFavorite { self.isFavorite = asset.isFavorite; changed = true }
        if self.isArchived != asset.isArchived { self.isArchived = asset.isArchived; changed = true }
        if self.isTrashed != asset.isTrashed { self.isTrashed = asset.isTrashed; changed = true }
        // `isHidden` bleibt unangetastet. Der API-`Asset` kennt das Feld nicht — er
        // sagt über „versteckt" also **nichts**, und ein hartes `false` machte aus
        // diesem Schweigen ein Dementi. Wer ein Foto im Web versteckt, bekam es über
        // den Stream korrekt als versteckt eingetragen; der nächste Lauf über einen
        // `Asset` (Polling-Delta, EXIF-Nachzug) setzte es wieder zurück.
        //
        // `GridIndexStore.upsert` entscheidet dasselbe und begründet es dort ebenso:
        // „Kennt `isHidden` nicht (bindet hart 0) → im UPDATE ausgelassen." Die beiden
        // Speicher liefen genau hier auseinander. Zurück auf sichtbar kommt ein Asset
        // ohnehin über den Stream, der `visibility` führt.
        if self.duration != asset.duration { self.duration = asset.duration; changed = true }
        if self.thumbhash != asset.thumbhash { self.thumbhash = asset.thumbhash; changed = true }
        if self.stackId != asset.stackId { self.stackId = asset.stackId; changed = true }
        if self.stackCount != asset.stackCount { self.stackCount = asset.stackCount; changed = true }
        if self.livePhotoVideoId != asset.livePhotoVideoId { self.livePhotoVideoId = asset.livePhotoVideoId; changed = true }

        // Store dimensions from top-level API fields (more reliable than exifInfo)
        if self.width != asset.effectiveWidth { self.width = asset.effectiveWidth; changed = true }
        if self.height != asset.effectiveHeight { self.height = asset.effectiveHeight; changed = true }

        if let exif = asset.exifInfo {
            // Fill in width/height from EXIF if top-level was nil
            if self.width == nil, let exifW = exif.exifImageWidth { self.width = exifW; changed = true }
            if self.height == nil, let exifH = exif.exifImageHeight { self.height = exifH; changed = true }
            if self.city != exif.city { self.city = exif.city; changed = true }
            if self.country != exif.country { self.country = exif.country; changed = true }
            if self.latitude != exif.latitude { self.latitude = exif.latitude; changed = true }
            if self.longitude != exif.longitude { self.longitude = exif.longitude; changed = true }
            if self.cameraMake != exif.make { self.cameraMake = exif.make; changed = true }
            if self.cameraModel != exif.model { self.cameraModel = exif.model; changed = true }
            if self.focalLength != exif.focalLength { self.focalLength = exif.focalLength; changed = true }
            if self.fNumber != exif.fNumber { self.fNumber = exif.fNumber; changed = true }
            if self.iso != exif.iso { self.iso = exif.iso; changed = true }
            if self.exposureTime != exif.exposureTime { self.exposureTime = exif.exposureTime; changed = true }
            if self.lensModel != exif.lensModel { self.lensModel = exif.lensModel; changed = true }
            if self.fileSizeInByte != exif.fileSizeInByte { self.fileSizeInByte = exif.fileSizeInByte; changed = true }
            if self.state != exif.state { self.state = exif.state; changed = true }
        }
        return changed
    }

    /// Convert back to API Asset for view compatibility
    ///
    /// **Kein `localDateTime`:** `CachedAsset` führt das Feld nicht, das
    /// zurückgegebene `Asset` hat es also immer `nil`. Heute ist das folgenlos —
    /// der einzige Pfad, der nach Ortszeit gruppiert, ist der Fotos-Reiter des
    /// iOS-Clients, und der lädt ausschließlich über `searchAssets` und fasst
    /// `CachedAsset` nie an (`PhotoFeedGrouping` fällt sonst auf das UTC-Präfix
    /// von `fileCreatedAt` zurück).
    ///
    /// Fällig wird es erst mit dem ersten cache-gestützten Pfad, der
    /// Tagesabschnitte bildet. Dann braucht es ein gespeichertes Feld hier, und
    /// das heißt SwiftData-Schemaänderung — der teure Teil: In diesem Projekt
    /// fangen Unit-Tests Migrationsplan-Crashes nicht, es braucht eine
    /// Store-Kopie und einen echten App-Start. Deshalb bewusst nicht auf Vorrat.
    func toAsset() -> Asset {
        let exif = ExifInfo(
            make: cameraMake,
            model: cameraModel,
            exifImageWidth: width,
            exifImageHeight: height,
            fileSizeInByte: fileSizeInByte,
            city: city,
            state: state,
            country: country,
            latitude: latitude,
            longitude: longitude,
            focalLength: focalLength,
            fNumber: fNumber,
            iso: iso,
            exposureTime: exposureTime,
            lensModel: lensModel
        )

        return Asset(
            id: assetId,
            type: AssetType(rawValue: type) ?? .other,
            originalFileName: originalFileName,
            originalPath: originalPath,
            fileCreatedAt: fileCreatedAt,
            fileModifiedAt: fileModifiedAt,
            isFavorite: isFavorite,
            isArchived: isArchived,
            duration: duration,
            thumbhash: thumbhash,
            isTrashed: isTrashed,
            exifInfo: exif,
            people: nil,
            width: width,
            height: height,
            stackId: stackId,
            stackCount: stackCount,
            livePhotoVideoId: livePhotoVideoId
        )
    }

    // MARK: - Computed helpers (mirror Asset struct)

    /// True if the original file is cached locally on disk
    var isLocallyAvailable: Bool { localFilePath != nil }

    var isVideo: Bool { type == "VIDEO" }

    /// Bewusst über `Asset.createdDate` statt über einen eigenen Formatter: Beide
    /// werten denselben Serverwert aus, und ein zweiter Formatter konnte vom ersten
    /// abweichen — genau das war der Fall, als hier nur die Schreibweise **mit**
    /// Millisekunden angenommen wurde.
    var createdDate: Date? {
        Asset.createdDate(from: fileCreatedAt)
    }

    var monthKey: String { String(fileCreatedAt.prefix(7)) }
    var yearKey: String { String(fileCreatedAt.prefix(4)) }
}
