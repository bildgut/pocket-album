import Foundation
import SwiftData

extension ModelContext {

    /// Legt die Zuordnung Apple-Foto → Immich-Asset an oder frischt sie auf.
    ///
    /// Zuvor stand diese Logik nur in `AlbumSyncManager`; `FavoritesSyncManager`
    /// fügte bedingungslos einen neuen Datensatz ein. Das ist **kein** Fehler:
    /// `@Attribute(.unique)` auf `localIdentifier` macht daraus ein Upsert, und
    /// `ApplePhotosMappingStoreTests` bestehen mit beiden Fassungen — geprüft, nicht
    /// vermutet. Eine Stelle statt zwei ist trotzdem richtig, weil es jetzt drei
    /// Aufrufer gibt.
    ///
    /// Der eigentliche Unterschied lag daneben, in einer **fehlenden Aufrufstelle**:
    /// Wurde ein Foto über Dateiname und Datum auf dem Server gefunden, merkte sich
    /// der Album-Pfad das Ergebnis (Tier 2), der Favoriten-Pfad nicht. Dieselbe
    /// Suche lief bei jedem Lauf erneut, für jedes Foto, und kam nie zur Ruhe.
    func upsertApplePhotosMapping(
        localIdentifier: String,
        immichAssetId: String,
        modificationDate: Date?
    ) {
        let id = localIdentifier
        let predicate = #Predicate<ApplePhotosAssetMapping> { $0.localIdentifier == id }
        if let existing = try? fetch(FetchDescriptor(predicate: predicate)).first {
            existing.immichAssetId = immichAssetId
            existing.lastKnownModificationDate = modificationDate
            existing.uploadedAt = Date()
        } else {
            insert(
                ApplePhotosAssetMapping(
                    localIdentifier: localIdentifier,
                    immichAssetId: immichAssetId,
                    lastKnownModificationDate: modificationDate
                )
            )
        }
        try? save()
    }
}
