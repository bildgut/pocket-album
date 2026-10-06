import Foundation

/// Filters that can be applied to the asset grid
struct AssetFilter: Equatable {
    var preset: FilterPreset = .all
    var cameraModel: String?
    var city: String?
    var country: String?
    /// Nur Fotos zeigen, die in keinem Album stehen.
    ///
    /// Bewusst ein eigenes Feld statt eines weiteren ``FilterPreset``: Die Presets
    /// schließen einander aus, „ohne Album" ist zu ihnen aber quer — „Videos ohne
    /// Album" ist eine sinnvolle Frage, „Videos oder ohne Album" keine.
    ///
    /// Braucht den lokalen Album-Index; wer den Filter setzt, muss `apply` das
    /// Mitgliedschafts-Set mitgeben (siehe `PhotoGridViewModel`).
    var onlyWithoutAlbum: Bool = false

    var isActive: Bool {
        preset != .all || cameraModel != nil || city != nil || country != nil || onlyWithoutAlbum
    }

    /// - Parameter assetIdsInAnyAlbum: Asset-IDs, die in mindestens einem Album stehen
    ///   (aus ``AlbumMembershipStore/assetIdsInAnyAlbum(excludingAlbumIds:)``). Nur für
    ///   `onlyWithoutAlbum` nötig. Der Aufrufer stellt sicher, dass der Index alle Alben
    ///   abdeckt, bevor er den Filter setzt — ein Teilbestand ließe hier Fotos
    ///   auftauchen, die sehr wohl in einem Album stehen.
    func apply(to assets: [Asset], assetIdsInAnyAlbum: Set<String> = []) -> [Asset] {
        // Single-pass: combine all predicates to avoid intermediate array copies
        guard isActive else { return assets }

        return assets.filter { asset in
            // Preset filter
            switch preset {
            case .all: break
            case .favorites: if !asset.isFavorite { return false }
            case .photos: if asset.type != .image { return false }
            case .videos: if asset.type != .video { return false }
            case .screenshots: if !isScreenshot(asset) { return false }
            case .withLocation: if asset.exifInfo?.latitude == nil { return false }
            }
            // Metadata filters
            if let cameraModel, asset.exifInfo?.model != cameraModel { return false }
            if let city, asset.exifInfo?.city != city { return false }
            if let country, asset.exifInfo?.country != country { return false }
            if onlyWithoutAlbum, assetIdsInAnyAlbum.contains(asset.id) { return false }
            return true
        }
    }

    private func isScreenshot(_ asset: Asset) -> Bool {
        ScreenshotDetector.isScreenshot(asset)
    }

    static let empty = AssetFilter()
}

// MARK: - Facetten (Kamera- und Länderliste im Filtermenü)

/// Reihenfolge der Auswahlwerte im Filtermenü.
///
/// Das Menü zeigte jeden gefundenen Wert alphabetisch — bei einer gewachsenen
/// Bibliothek sind das über ein Dutzend Kameras, darunter jede je einmal benutzte.
/// Die Liste war damit länger als der Bildschirm und die zwei tatsächlich benutzten
/// Kameras lagen irgendwo mittendrin.
enum FilterFacets {

    /// Wie viele Werte direkt im Menü stehen; der Rest wandert ins Untermenü.
    static let inlineLimit = 3

    /// Nach Häufigkeit absteigend, bei Gleichstand alphabetisch (damit die
    /// Reihenfolge bei gleich häufigen Werten nicht zwischen zwei Läufen springt).
    static func ranked(_ counts: [String: Int]) -> [String] {
        counts.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
        }.map(\.key)
    }

    /// Teilt die gerankte Liste in „steht direkt im Menü" und „steht im Untermenü".
    ///
    /// `selected` bleibt immer im vorderen Teil: Wer eine seltene Kamera ausgewählt
    /// hat, soll sie im Menü sehen (mit Haken) statt sie im Untermenü suchen zu müssen.
    /// Das Untermenü ist alphabetisch — dort wird gesucht, nicht gerankt.
    static func split(_ ranked: [String], selected: String?) -> (inline: [String], more: [String]) {
        var inline = Array(ranked.prefix(inlineLimit))
        if let selected, ranked.contains(selected), !inline.contains(selected) {
            inline.append(selected)
        }
        let inlineSet = Set(inline)
        let more = ranked.filter { !inlineSet.contains($0) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return (inline, more)
    }
}

enum FilterPreset: String, CaseIterable, Identifiable {
    case all = "Alle Objekte"
    case favorites = "Favoriten"
    case photos = "Fotos"
    case videos = "Videos"
    case screenshots = "Bildschirmfotos"
    case withLocation = "Mit Standort"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .all: return "checkmark.circle"
        case .favorites: return "star.fill"
        case .photos: return "photo"
        case .videos: return "video.fill"
        case .screenshots: return "camera.viewfinder"
        case .withLocation: return "location.fill"
        }
    }
}

// MARK: - Media Types (Apple Photos "Medienarten" sidebar section)

enum MediaType: String, CaseIterable, Identifiable, Hashable {
    case videos = "Videos"
    case selfies = "Selfies"
    case portraits = "Porträt"
    case panoramas = "Panoramen"
    case screenshots = "Bildschirmfotos"
    case rawFiles = "RAW"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .videos: return "video"
        case .selfies: return "person.crop.square"
        case .portraits: return "f.cursive"
        case .panoramas: return "pano"
        case .screenshots: return "camera.viewfinder"
        case .rawFiles: return "r.square"
        }
    }

    /// Determine if an asset matches this media type using EXIF and filename heuristics.
    func matches(_ asset: Asset) -> Bool {
        switch self {
        case .videos:
            return asset.type == .video

        case .selfies, .portraits:
            // Dieselben Stichworte beantwortet der Server über
            // ``MediaTypeServerQuery`` — hier die lokale Fassung derselben Regel.
            let name = asset.originalFileName.lowercased()
            if fileNameKeywords.contains(where: { name.contains($0) }) { return true }
            // Das Objektiv entscheidet; nur ohne Objektivangabe das Kameramodell.
            guard let model = asset.exifInfo?.lensModel?.lowercased()
                    ?? asset.exifInfo?.model?.lowercased() else { return false }
            return lensKeywords.contains(where: { model.contains($0) })

        case .panoramas:
            return Self.isPanorama(
                fileName: asset.originalFileName,
                path: asset.originalPath,
                width: asset.effectiveWidth,
                height: asset.effectiveHeight
            )

        case .screenshots:
            return ScreenshotDetector.isScreenshot(asset)

        case .rawFiles:
            return Self.isRawFile(fileName: asset.originalFileName, path: asset.originalPath)
        }
    }

    /// Ob Dateiname oder Originalpfad auf ein RAW-Format zeigen.
    ///
    /// Die Endungen kommen aus ``MIMEType/rawExtensions`` — der Stelle, die dafür
    /// angelegt wurde. Hier stand eine eigene Liste, und in
    /// `MediaTypeService.rawAssetsFromSwiftData` noch eine dritte; beide zählten zehn
    /// Endungen, die Quelle elf. Es fehlte ausgerechnet `raw` — dieselbe Lücke, die im
    /// Kommentar von `MIMEType.rawExtensions` schon einmal für die Smart-Album-Regel
    /// beschrieben ist.
    ///
    /// Der Pfad zählt mit: Immich behält beim Import den ursprünglichen Dateinamen
    /// nicht immer. Die SwiftData-Fassung sah nur den Dateinamen — dieselbe Auswahl
    /// lieferte damit je nach Weg ein anderes Ergebnis.
    static func isRawFile(fileName: String, path: String?) -> Bool {
        let fileExt = (fileName as NSString).pathExtension.lowercased()
        let pathExt = (path as NSString?)?.pathExtension.lowercased() ?? ""
        return MIMEType.rawExtensions.contains(fileExt)
            || MIMEType.rawExtensions.contains(pathExt)
    }

    /// Ob Name, Pfad oder Seitenverhältnis auf ein Panorama zeigen.
    ///
    /// Dieselbe Entscheidung stand in `SmartAlbumEvaluator` noch einmal, dort ohne den
    /// Blick auf den Pfad — die Medienart „Panoramen" und die Smart-Album-Regel
    /// „ist Panorama" antworteten für dasselbe Foto verschieden.
    ///
    /// **Nicht** dieselbe Rechnung wie `GridIndexStore.loadPanoramas`: Die SQL-Fassung
    /// nimmt `>= 2.0` statt `> 2.0`, lässt `lensModel IS NOT NULL` als Ersatz für die
    /// Breite gelten, kennt die Namensabkürzung „pano" nicht und schließt
    /// Bildschirmfoto-Namen aus. Das ist bewusst anders getunt und hier absichtlich
    /// nicht angeglichen — welche der beiden gelten soll, ist eine Entscheidung über
    /// die Anzeige, keine Korrektur.
    static func isPanorama(fileName: String, path: String?, width: Int?, height: Int?) -> Bool {
        // Name oder Pfad (iPhone „IMG_PANO_xxxx.jpg", Ordner „Panoramas/")
        if fileName.lowercased().contains("pano") { return true }
        if let path = path?.lowercased(), path.contains("pano") { return true }
        // Seitenverhältnis: nur *liegende* Panoramen mit hoher Auflösung
        // (Bildschirmfotos enden bei ~2800 px Breite, echte Panoramen ab 4000).
        guard let w = width, let h = height, h > 0, w > h, w >= 4000 else { return false }
        return Double(w) / Double(h) > 2.0
    }

    /// Whether this media type needs a server-side search (because EXIF data may not be cached locally)
    var requiresServerSearch: Bool {
        switch self {
        case .selfies, .portraits, .rawFiles: return true
        default: return false
        }
    }

    /// Stichworte im Objektiv (bzw. ohne Objektiv im Kameramodell), klein geschrieben.
    /// Frontkameras nennen „front", ältere „FaceTime", die Tiefenkamera „TrueDepth";
    /// Porträtmodus-Objektive nennen „portrait".
    var lensKeywords: [String] {
        switch self {
        case .selfies: return ["front", "facetime", "truedepth"]
        case .portraits: return ["portrait", "truedepth"]
        default: return []
        }
    }

    /// Stichworte im Dateinamen, klein geschrieben.
    var fileNameKeywords: [String] {
        switch self {
        case .portraits: return ["portrait", "porträt"]
        default: return []
        }
    }

    /// CLIP-Suche, deren beste Treffer zusätzlich zählen — nur bei Porträts, und nur
    /// die ``clipLimit`` relevantesten: CLIP kennt keine Trefferschwelle. Die alte
    /// Fassung holte 20 Seiten à 500, also 10 000 „porträtähnliche" Fotos, und zeigte
    /// sie alle (am 11.09.2026 gut 8 800 ohne Porträtobjektiv). Bei Selfies übernahm
    /// sie ohnehin nur Treffer, die die Objektivregel erfüllen — dort fügt CLIP nichts
    /// hinzu.
    var clipQuery: String? {
        switch self {
        case .portraits: return "portrait mode photo"
        default: return nil
        }
    }

    /// Wie viele CLIP-Treffer höchstens dazukommen — derselbe Deckel wie die
    /// Freitextsuche (``SearchQueryPlanner/clipCap``).
    static let clipLimit = SearchQueryPlanner.clipCap
}
