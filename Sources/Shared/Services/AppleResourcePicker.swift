import Photos
import UniformTypeIdentifiers

/// Protokoll für Ressourcen-Eigenschaften, damit `AppleResourcePicker` auch ohne echte `PHAssetResource`
/// (die sich in Unit-Tests nicht instanziieren lässt) vollständig prüfbar bleibt.
public protocol AppleResourceDescribing: Sendable {
    var resourceType: PHAssetResourceType { get }
    var uniformTypeIdentifier: String { get }
    var originalFilename: String { get }
}

extension PHAssetResource: AppleResourceDescribing {
    public var resourceType: PHAssetResourceType { type }
}

extension AppleResourceDescribing {
    public var isRaw: Bool {
        if let utType = UTType(uniformTypeIdentifier), utType.conforms(to: .rawImage) {
            return true
        }
        let ext = (originalFilename as NSString).pathExtension.lowercased()
        let rawExts: Set<String> = [
            "dng", "raw", "cr2", "cr3", "nef", "nrw", "arw", "srf", "sr2",
            "orf", "rw2", "raf", "pef", "ptx", "srw", "x3f", "erf", "mef", "mos", "mrw"
        ]
        return rawExts.contains(ext)
    }
}

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
/// Arbeitet auf den Typen bzw. `AppleResourceDescribing` statt zwingend auf `PHAssetResource`,
/// weil sich Letztere im Test nicht bauen lässt. Die Auswahlregel ist damit prüfbar,
/// die Verdrahtung bleibt dünn.
enum AppleResourcePicker {

    /// Index der zu bevorzugenden Ressource nur nach Typen, oder `nil`, wenn keine taugt.
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

    /// Bevorzugte Ressource unter Berücksichtigung von Typ, Format und RAW-Eigenschaft.
    /// Bei RAW+HEIC/JPEG-Kombinationen (wie von Not Boring Camera oder Apple ProRAW)
    /// wird immer das gerenderte/stilisierte Bild (HEIC/JPEG) als Hauptbild/Cover gewählt.
    static func preferred<T: AppleResourceDescribing>(_ resources: [T], mediaType: PHAssetMediaType) -> T? {
        if mediaType == .video {
            if let i = preferredIndex(types: resources.map(\.resourceType), mediaType: .video) {
                return resources[i]
            }
            return nil
        }

        // Bei Fotos:
        // 1. Wenn eine bearbeitete Fassung in voller Größe vorliegt (.fullSizePhoto), diese bevorzugen.
        if let fullSize = resources.first(where: { $0.resourceType == .fullSizePhoto }) {
            return fullSize
        }

        // 2. Kandidaten aus .photo und .alternatePhoto:
        let photoCandidates = resources.filter { $0.resourceType == .photo || $0.resourceType == .alternatePhoto }

        // Wenn sowohl RAW als auch gerendertes Bild (HEIC/JPEG) vorliegen: Bevorzuge das gerenderte Bild!
        if let nonRaw = photoCandidates.first(where: { !$0.isRaw }) {
            return nonRaw
        }

        // 3. Wenn nur RAW vorliegt, nimm den ersten Kandidaten (.alternatePhoto vor .photo, oder umgekehrt).
        if let firstCandidate = photoCandidates.first {
            return firstCandidate
        }

        // Fallback über Typenliste
        if let i = preferredIndex(types: resources.map(\.resourceType), mediaType: mediaType) {
            return resources[i]
        }
        return resources.first
    }

    /// Findet die gepaarte RAW-Ressource, falls das Asset eine RAW+HEIC/JPEG-Kombination ist.
    static func pairedRaw<T: AppleResourceDescribing>(_ resources: [T]) -> T? {
        guard let primary = preferred(resources, mediaType: .image), !primary.isRaw else {
            return nil
        }
        return resources.first(where: {
            ($0.resourceType == .photo || $0.resourceType == .alternatePhoto) && $0.isRaw
        })
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

    /// Bequemlichkeit für die Aufrufer mit echten Ressourcen.
    static func pairedVideo<T: AppleResourceDescribing>(_ resources: [T]) -> T? {
        resources.first(where: { $0.resourceType == .pairedVideo })
            ?? resources.first(where: { $0.resourceType == .fullSizePairedVideo })
    }
}

