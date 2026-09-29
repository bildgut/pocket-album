import Foundation

extension Notification.Name {
    static let dockDropFiles = Notification.Name("dockDropFiles")
    static let importFilesRequested = Notification.Name("importFilesRequested")
    static let syncNowRequested = Notification.Name("syncNowRequested")
    static let applePhotosSyncPromptRequested = Notification.Name("applePhotosSyncPromptRequested")
    static let applePhotosSyncNowRequested = Notification.Name("applePhotosSyncNowRequested")
    static let applePhotosFullSyncRequested = Notification.Name("applePhotosFullSyncRequested")
    static let applePhotosSyncProgressChanged = Notification.Name("applePhotosSyncProgressChanged")
    static let applePhotosDeletedAfterSync = Notification.Name("applePhotosDeletedAfterSync")
    static let assetsDidChange = Notification.Name("assetsDidChange")
    static let localAssetMutation = Notification.Name("localAssetMutation")
    static let syncAssetsChanged = Notification.Name("syncAssetsChanged")
    /// Die Bilder dieser Assets haben sich geändert, und ihre Cache-Einträge sind
    /// **bereits geräumt** — das Raster soll die Kacheln neu bauen, damit sie ihre
    /// Bild-URL neu berechnen (etwa `edited=true` nach einer Bearbeitung im Web).
    /// Gepostet nach dem Sync; das eigene Drehen geht weiter über `.assetsDidChange`.
    /// userInfo: ["ids": [String]]
    static let assetImagesDidChange = Notification.Name("assetImagesDidChange")
    /// `ConnectionManager.disconnect()` hat die Zugangsdaten zurückgezogen.
    /// Für app-weite Hintergrundläufe, die den Abbau des Ansichtsbaums
    /// überleben und sonst mit ungültigem Schlüssel weiterfragen würden
    /// (``InfoBildLauf``). Wird **synchron** auf dem Hauptthread zugestellt.
    static let connectionDidDisconnect = Notification.Name("connectionDidDisconnect")
    /// Neue Zugangsdaten gehören zu einem anderen Konto; die lokalen Daten des
    /// vorigen sind bereits geleert (`ConnectionManager.beiKontoWechsel`).
    static let kontoGewechselt = Notification.Name("kontoGewechselt")
    static let syncStaleWarning = Notification.Name("syncStaleWarning")
    static let offlineReplayCompleted = Notification.Name("offlineReplayCompleted")
    static let offlineRetryFailedRequested = Notification.Name("offlineRetryFailedRequested")
    static let offlineDiscardFailedRequested = Notification.Name("offlineDiscardFailedRequested")
    static let showCreateAlbumSheet = Notification.Name("showCreateAlbumSheet")
    static let showAddToAlbumSheet = Notification.Name("showAddToAlbumSheet")
    /// Kontextmenü → „Nach Kamera aufteilen …". userInfo: ["targetIds": [String]]
    static let kameraAufteilungRequested = Notification.Name("kameraAufteilungRequested")
    static let albumsDidChange = Notification.Name("albumsDidChange")
    /// Das Kontextmenü bittet um „Aus Album entfernen"; die Rückfrage stellt das
    /// Raster, damit Menü und Auswahlleiste denselben Dialog zeigen.
    /// userInfo: ["targetIds": [String], "albumId": String]
    static let removeFromAlbumRequested = Notification.Name("removeFromAlbumRequested")
    /// Opens the detail view for a specific album from anywhere in the app.
    /// userInfo: ["album": Album]
    static let openAlbumRequested = Notification.Name("openAlbumRequested")
    static let immichDeepLinkOpened = Notification.Name("immichDeepLinkOpened")
    static let openPersonDeepLink = Notification.Name("openPersonDeepLink")
    /// Posted by SammlungenView to open a specific memory year in MemoriesView.
    /// userInfo: ["year": Int]
    static let openMemoryDeepLink = Notification.Name("openMemoryDeepLink")
    /// Posted by SammlungenView to scroll the library to a specific date.
    /// userInfo: ["date": Date]
    static let scrollLibraryToDate = Notification.Name("scrollLibraryToDate")
    /// Trigger ExportSheet for specific asset IDs from anywhere in the app.
    /// userInfo: ["assetIds": [String]]
    static let showExportSheet = Notification.Name("showExportSheet")

    /// Fehlertext aus einer Kontextmenü-Aktion, den das Raster als Banner zeigt
    /// (`userInfo["message"]`). `ContextMenuActions` ist ein AppKit-Singleton ohne
    /// Zugriff auf das ViewModel — und ein `NSAlert` dort ist bewusst nicht gewollt.
    static let showErrorMessage = Notification.Name("showErrorMessage")
    /// Posted after tags are added or removed so the Sidebar reloads its tag list.
    static let tagsDidChange = Notification.Name("tagsDidChange")
    /// Kontextmenü „Preset anwenden": startet die Stapel-Entwicklung im Raster.
    /// userInfo: ["assetIds": [String], "presetName": String, "paramsJSON": String]
    static let applyDevelopPresetRequested = Notification.Name("applyDevelopPresetRequested")
    /// Kopierte Entwicklungseinstellungen auf eine RAW-Auswahl schreiben (nur
    /// persistieren — entwickelt wird beim nächsten Öffnen bzw. Batch-Lauf).
    static let pasteDevelopSettingsRequested = Notification.Name("pasteDevelopSettingsRequested")
    /// KI-Zuschnitt → „Im Editor verfeinern": öffnet den Beschnitt-Editor der
    /// Detailansicht vorbefüllt (userInfo: assetId, rect als NSValue, aspect-RawValue).
}
