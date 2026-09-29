import Photos

/// Welche Ressource eines Apple-Fotos hochgeladen wird — **eine** Stelle für alle drei
/// Aufrufer (`UploadManager`, `AlbumSyncManager`, `FavoritesSyncManager`).
///
/// Zuvor gab es drei Fassungen. Zwei waren gleich, die dritte fiel bei einem Video, für
/// das weder `.fullSizeVideo` noch `.video` vorlag, **in den Foto-Zweig durch** und
/// konnte eine `.alternatePhoto` oder `.fullSizePhoto` liefern. Die beiden anderen
/// verbieten genau das, mit dem Kommentar „Für Videos NIE eine Photo-Resource
/// zurückgeben (z. B. .alternatePhoto bei bearbeiteten Videos)" — jemand ist da einmal
/// hineingelaufen.
///
/// Arbeitet auf den Typen statt auf `PHAssetResource`, weil sich Letztere im Test nicht
/// bauen lässt. Die Auswahlregel ist damit prüfbar, die Verdrahtung bleibt dünn.
enum AppleResourcePicker {

    /// Index der zu bevorzugenden Ressource, oder `nil`, wenn keine taugt.
    static func preferredIndex(types: [PHAssetResourceType], mediaType: PHAssetMediaType) -> Int? {
        func ersten(_ treffer: (PHAssetResourceType) -> Bool) -> Int? {
            types.firstIndex(where: treffer)
        }

        if mediaType == .video {
            // Bearbeitete Fassung vor Original.
            if let i = ersten({ $0 == .fullSizeVideo }) { return i }
            if let i = ersten({ $0 == .video })         { return i }
            // Notnagel: irgendetwas, das kein Standbild ist (Tonspur, gepaartes Video).
            // Bewusst **kein** Rückfall auf den Foto-Zweig: Sonst lüde ein Video als
            // JPEG hoch, und die Zuordnung führte es als erledigt.
            return ersten { $0 != .photo && $0 != .alternatePhoto && $0 != .fullSizePhoto }
        }

        // Foto: bearbeitete Fassung vor Original.
        if let i = ersten({ $0 == .alternatePhoto }) { return i }
        if let i = ersten({ $0 == .fullSizePhoto })  { return i }
        if let i = ersten({ $0 == .photo })          { return i }
        return types.isEmpty ? nil : 0
    }

    /// Bequemlichkeit für die Aufrufer, die echte Ressourcen in der Hand haben.
    static func preferred(_ resources: [PHAssetResource], mediaType: PHAssetMediaType) -> PHAssetResource? {
        preferredIndex(types: resources.map(\.type), mediaType: mediaType).map { resources[$0] }
    }

    /// Index des Video-Teils eines Live Photos, oder `nil`, wenn keiner vorliegt.
    ///
    /// Die Reihenfolge (`.pairedVideo` vor `.fullSizePairedVideo`) ist die des Uploads —
    /// und sie gilt hier für **beide** Seiten. Der Upload bestimmt, was auf dem Server
    /// liegt; wer beim Verifizieren die jeweils andere Fassung hasht, meldet bei jedem
    /// bearbeiteten Live Photo eine Prüfsummen-Abweichung, die es nicht gibt.
    static func pairedVideoIndex(types: [PHAssetResourceType]) -> Int? {
        types.firstIndex { $0 == .pairedVideo }
            ?? types.firstIndex { $0 == .fullSizePairedVideo }
    }

    /// Bequemlichkeit für die Aufrufer, die echte Ressourcen in der Hand haben.
    static func pairedVideo(_ resources: [PHAssetResource]) -> PHAssetResource? {
        pairedVideoIndex(types: resources.map(\.type)).map { resources[$0] }
    }
}
