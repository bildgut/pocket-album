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
    /// Die aktive Server-Route hat zwischen Lokal (Primär-URL) und Remote (Externe URL)
    /// gewechselt (`ImmichAPIClient.baseURL` wurde aktualisiert).
    static let serverRouteDidChange = Notification.Name("serverRouteDidChange")
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
    /// Foto-Raster / Auswahlleiste → „Ort zuweisen…". userInfo: ["targetIds": [String]]
    static let assignLocationRequested = Notification.Name("assignLocationRequested")
    static let albumsDidChange = Notification.Name("albumsDidChange")
    /// Das Kontextmenü bittet um „Aus Album entfernen"; die Rückfrage stellt das
    /// Raster, damit Menü und Auswahlleiste denselben Dialog zeigen.
    /// userInfo: ["targetIds": [String], "albumId": String]
    static let removeFromAlbumRequested = Notification.Name("removeFromAlbumRequested")
    /// Opens the detail view for a specific album from anywhere in the app.
    /// userInfo: ["album": Album]
    static let openAlbumRequested = Notification.Name("openAlbumRequested")
    /// Opens the tag view for a specific tag from anywhere in the app (e.g. Info Panel).
    /// userInfo: ["tag": TagInfo]
    static let openTagRequested = Notification.Name("openTagRequested")
    /// Opens the place detail view for a city from anywhere in the app (e.g. Info Panel).
    /// userInfo: ["city": String, "country": String?]
    static let openPlaceRequested = Notification.Name("openPlaceRequested")
    static let openPlaceDeepLink = Notification.Name("openPlaceDeepLink")
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
    /// Fordert das Öffnen des RAW-Entwicklers an (z. B. aus dem Stapel-Popover).
    static let openRawDevelopRequested = Notification.Name("openRawDevelopRequested")
    /// Startet die interaktive Reisetour im Vollbild über der gesamten App.
    /// userInfo: ["albumName": String, "assets": [Asset]]
    static let startTripPlaybackRequested = Notification.Name("startTripPlaybackRequested")

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
    /// Ein Stapel-Vertreter hat sich geändert (Titelbildwechsel oder Löschen einer
    /// einzelnen Stapel-Fassung): Ansichten wie `AlbumDetailView` ersetzen alte IDs
    /// direkt an Ort und Stelle durch das neue `Asset`.
    /// userInfo: ["replacements": [String: Asset]]
    static let stackRepresentativeReplaced = Notification.Name("stackRepresentativeReplaced")
    /// KI-Zuschnitt → „Im Editor verfeinern": öffnet den Beschnitt-Editor der
    /// Detailansicht vorbefüllt (userInfo: assetId, rect als NSValue, aspect-RawValue).
}
