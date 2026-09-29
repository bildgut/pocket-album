import Foundation

// MARK: - Asset Model

enum AssetType: String, Codable, Sendable {
    case image = "IMAGE"
    case video = "VIDEO"
    case audio = "AUDIO"
    case other = "OTHER"
}

/// Sichtbarkeit eines Assets, wie Immich sie führt (`AssetResponseDto.visibility`,
/// Enum `AssetVisibility`). Der Sync-Stream führt dasselbe Feld als rohe
/// Zeichenfolge (`SyncStreamClient.SyncAsset.visibility`).
///
/// ## ``hidden`` ist der Bewegtbild-Anteil eines Live Photos
///
/// Immich legt das eine-Sekunde-Video eines Live/Motion Photos als eigenes
/// Asset vom Typ `VIDEO` an, verweist vom Standbild darauf
/// (``Asset/livePhotoVideoId``) und setzt seine Sichtbarkeit auf `hidden`.
/// Genau das ist die Kennzeichnung, an der man es erkennt — es gibt kein
/// „istBewegtbildanteil"-Feld und keine Laufzeitgrenze, an der man raten müßte.
///
/// Der Mac-Client kommt gar nicht erst in die Verlegenheit: Sein Bestand kommt
/// aus dem Sync-Stream, und der liefert diese Assets nicht (nachgemessen im
/// Rasterindex dieses Servers: 6 223 Standbilder verweisen auf einen
/// Bewegtbild-Anteil, 6 208 davon haben dort überhaupt keine Zeile). Wo er sie
/// doch bekäme, hält `GridIndexStore` sie über `isHidden` aus jeder Abfrage
/// heraus. Der iOS-Reiter „Fotos" lädt dagegen über `POST /api/search/metadata`,
/// und dieser Endpunkt liefert sie ohne ausdrücklichen Filter mit — deshalb muß
/// dort ``PhotoFeedGrouping`` sie wegfiltern.
enum AssetVisibility: String, Codable, Sendable {
    case timeline
    case archive
    case hidden
    case locked
}

struct Asset: Identifiable, Hashable, Sendable, Codable {
    let id: String
    let type: AssetType
    let originalFileName: String
    let originalPath: String?
    /// Top-level orientation reported by Immich (EXIF orientation 1–8).
    /// Used for non-destruktive Rotation über die updateAsset-API.
    let orientation: Int?
    let fileCreatedAt: String
    let fileModifiedAt: String
    /// Ortszeit der Aufnahme, wie Immich sie aus den EXIF-Daten ableitet
    /// (`AssetResponseDto.localDateTime`) — derselbe Zeitpunkt wie `fileCreatedAt`,
    /// aber in der Zone, in der fotografiert wurde. Immich schreibt trotzdem ein
    /// `Z` ans Ende; das ist Schreibweise, keine Zonenangabe.
    ///
    /// **Bewusst roh als `String`, nicht als `Date`.** Ein `Date` ist ein Zeitpunkt
    /// ohne Ort; den Text zu parsen hieße, ihn gegen irgendeine Zone aufzulösen und
    /// genau die Ortsinformation wegzuwerfen, für die das Feld da ist. Wer nach dem
    /// Aufnahmetag gruppieren will, nimmt `String(localDateTime.prefix(10))` — kein
    /// `Calendar`, keine Zone, keine Sommerzeitgrenze.
    ///
    /// `nil` bei älteren Servern, die das Feld nicht liefern, und auf allen Wegen,
    /// die nicht direkt aus der API-Antwort kommen (`CachedAsset` speichert es nicht).
    let localDateTime: String?
    /// Server-side upload timestamp
    let createdAt: String?
    let isFavorite: Bool
    let isArchived: Bool
    let duration: String?
    let thumbhash: String?
    let isTrashed: Bool
    /// Represents if the asset is in the locked folder (API returns `isOffline = true`)
    let isOffline: Bool
    /// Ob serverseitig eine Bearbeitung (Drehung, Beschnitt, Belichtung) hinterlegt ist.
    ///
    /// Entscheidet, ob die Bild-URLs `edited=true` tragen müssen — siehe
    /// ``EditedAssetsStore``. Der Sync-Stream führt das Feld nicht, die REST-Antwort
    /// schon; deshalb markiert erst das Öffnen eines Fotos eine anderswo (Web-UI)
    /// vorgenommene Bearbeitung.
    let isEdited: Bool

    let exifInfo: ExifInfo?
    let people: [Person]?
    let tags: [TagInfo]?

    // Top-level dimensions from Immich API (more reliable than exifInfo)
    private let _width: Int?
    private let _height: Int?

    // MARK: - Stack Info
    /// The stack this asset belongs to, if any.
    let stackId: String?
    /// Total number of assets in the stack (nil when unknown, e.g. from sync stream).
    let stackCount: Int?
    /// Asset ID of the paired Live Photo video when this asset is the primary photo.
    let livePhotoVideoId: String?

    /// Sichtbarkeit laut Server. `nil`, wo sie nicht durchgereicht wird — also
    /// bei `CachedAsset.toAsset()` (das SwiftData-Modell führt statt dessen die
    /// abgeleiteten Flaggen `isArchived`/`isHidden`), bei allen von Hand
    /// gebauten `Asset`-Werten und bei Servern, die das Feld nicht kennen.
    ///
    /// Aus der REST-Antwort kommt sie dagegen immer: `visibility` steht in
    /// Immichs `AssetResponseDto` unter `required`. Ein `nil` von dort wäre also
    /// ein unbekannter neuer Wert (siehe Decoder) — und der darf nicht als
    /// „versteckt" gelten, sonst verschwänden bei einem Serverwechsel wortlos
    /// Fotos aus dem Raster.
    let visibility: AssetVisibility?

    /// Der Bewegtbild-Anteil eines Live/Motion Photos — das eine-Sekunde-Video,
    /// das zu einem Standbild gehört und für sich genommen nichts zeigt.
    ///
    /// Siehe ``AssetVisibility/hidden`` für die Begründung, warum das die
    /// Kennzeichnung ist und keine Laufzeitschwelle.
    var istVersteckterBewegtbildAnteil: Bool { visibility == .hidden }

    // MARK: - Integrity
    /// SHA-1 hex string returned by the Immich server for this asset.
    /// Used for post-upload checksum validation.
    let checksum: String?

    // MARK: - Memberwise init (used by CachedAsset.toAsset() and tests)

    init(
        id: String,
        type: AssetType,
        originalFileName: String,
        originalPath: String? = nil,
        orientation: Int? = nil,
        fileCreatedAt: String,
        fileModifiedAt: String,
        localDateTime: String? = nil,
        createdAt: String? = nil,
        isFavorite: Bool,
        isArchived: Bool = false,
        duration: String? = nil,
        thumbhash: String? = nil,
        isTrashed: Bool = false,
        isOffline: Bool = false,
        isEdited: Bool = false,
        exifInfo: ExifInfo? = nil,
        people: [Person]? = nil,
        tags: [TagInfo]? = nil,
        width: Int? = nil,
        height: Int? = nil,
        stackId: String? = nil,
        stackCount: Int? = nil,
        livePhotoVideoId: String? = nil,
        visibility: AssetVisibility? = nil,
        checksum: String? = nil
    ) {
        self.id = id
        self.type = type
        self.originalFileName = originalFileName
        self.originalPath = originalPath
        self.orientation = orientation
        self.fileCreatedAt = fileCreatedAt
        self.fileModifiedAt = fileModifiedAt
        self.localDateTime = localDateTime
        self.createdAt = createdAt
        self.isFavorite = isFavorite
        self.isArchived = isArchived
        self.duration = duration
        self.thumbhash = thumbhash
        self.isTrashed = isTrashed
        self.isOffline = isOffline
        self.isEdited = isEdited
        self.exifInfo = exifInfo
        self.people = people
        self.tags = tags
        self._width = width
        self._height = height
        self.stackId = stackId
        self.stackCount = stackCount
        self.livePhotoVideoId = livePhotoVideoId
        self.visibility = visibility
        self.checksum = checksum
    }

    // MARK: - Dauer aus Millisekunden

    /// Millisekunden → `"HH:MM:SS.mmm"` — die eine Form, die alle Formatierer
    /// dieser App erwarten. `nil`, wenn daraus keine Dauer werden kann.
    ///
    /// Der Server schickt `duration` in drei Formen: als fertige Zeichenfolge
    /// (AssetV1) sowie als Millisekunden-`Double` oder -`Int` (AssetV2).
    /// Die beiden Zahlenformen laufen hier zusammen — auch die aus
    /// `SyncStreamClient`, die dieselbe Rechnung vorher wortgleich noch einmal
    /// hatte.
    ///
    /// **Warum die Prüfung nötig ist:** `Int(totalSeconds)` bricht mit SIGTRAP
    /// ab, sobald der Wert nicht endlich ist oder jenseits von `Int` liegt.
    /// NaN und Infinity lehnt JSON selbst ab, `1e30` ist dagegen gültiges
    /// JSON — und riss die App beim Decodieren der Serverantwort mit.
    /// Negative Werte ergaben `"00:00:-5.000"`, eine Form, die anschließend
    /// kein Formatierer dieser App versteht; auch dafür ist `nil` die
    /// ehrlichere Antwort als eine Zeichenfolge, die nur so aussieht.
    ///
    /// Bewusst **ohne** inhaltliche Obergrenze wie die 86 400 s in
    /// `AssetInfoFormat.duration`: Dieser Wert wandert in den Cache, nicht auf
    /// den Bildschirm. Was davon anzeigbar ist, entscheidet die Anzeige.
    static func durationString(fromMilliseconds milliseconds: Double) -> String? {
        let totalSeconds = milliseconds / 1000.0
        guard totalSeconds.isFinite, totalSeconds >= 0, totalSeconds < Double(Int.max)
        else { return nil }
        let hours = Int(totalSeconds) / 3600
        let minutes = (Int(totalSeconds) % 3600) / 60
        let seconds = totalSeconds.truncatingRemainder(dividingBy: 60)
        return String(format: "%02d:%02d:%06.3f", hours, minutes, seconds)
    }

    // MARK: - Codable (isTrashed defaults to false when absent)

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = try c.decode(AssetType.self, forKey: .type)
        originalFileName = try c.decode(String.self, forKey: .originalFileName)
        originalPath = try c.decodeIfPresent(String.self, forKey: .originalPath)
        orientation = try c.decodeIfPresent(Int.self, forKey: .orientation)
        fileCreatedAt = try c.decode(String.self, forKey: .fileCreatedAt)
        fileModifiedAt = try c.decode(String.self, forKey: .fileModifiedAt)
        localDateTime = try c.decodeIfPresent(String.self, forKey: .localDateTime)
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        isFavorite = try c.decode(Bool.self, forKey: .isFavorite)
        isArchived = try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        if let strVal = try? c.decodeIfPresent(String.self, forKey: .duration) {
            duration = strVal
        } else if let doubleVal = try? c.decodeIfPresent(Double.self, forKey: .duration) {
            duration = Asset.durationString(fromMilliseconds: doubleVal)
        } else if let intVal = try? c.decodeIfPresent(Int.self, forKey: .duration) {
            duration = Asset.durationString(fromMilliseconds: Double(intVal))
        } else {
            duration = nil
        }
        thumbhash = try c.decodeIfPresent(String.self, forKey: .thumbhash)
        isTrashed = try c.decodeIfPresent(Bool.self, forKey: .isTrashed) ?? false
        isOffline = try c.decodeIfPresent(Bool.self, forKey: .isOffline) ?? false
        isEdited = try c.decodeIfPresent(Bool.self, forKey: .isEdited) ?? false

        exifInfo = try c.decodeIfPresent(ExifInfo.self, forKey: .exifInfo)
        people = try c.decodeIfPresent([Person].self, forKey: .people)
        tags = try c.decodeIfPresent([TagInfo].self, forKey: .tags)
        _width = try c.decodeIfPresent(Int.self, forKey: ._width)
        _height = try c.decodeIfPresent(Int.self, forKey: ._height)
        // Stack fields — nested under "stack" in the Immich API response
        if let stack = try c.decodeIfPresent(AssetStack.self, forKey: .stack) {
            stackId = stack.id
            stackCount = stack.assetCount
        } else {
            stackId = nil
            stackCount = nil
        }
        livePhotoVideoId = try c.decodeIfPresent(String.self, forKey: .livePhotoVideoId)
        // `try?` statt `try`: Ein Wert, den dieses Enum nicht kennt (ein
        // späterer Server könnte einen fünften einführen), darf nicht das ganze
        // Asset unlesbar machen — dann fiele eine ganze Seite des Rasters aus.
        // Er landet als `nil`, also als „nicht versteckt", und das Asset bleibt
        // sichtbar. Lieber ein Bewegtbild-Anteil zuviel im Raster als ein Foto
        // zu wenig.
        visibility = (try? c.decodeIfPresent(AssetVisibility.self, forKey: .visibility)) ?? nil
        checksum = try c.decodeIfPresent(String.self, forKey: .checksum)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(type, forKey: .type)
        try c.encode(originalFileName, forKey: .originalFileName)
        try c.encodeIfPresent(originalPath, forKey: .originalPath)
        try c.encodeIfPresent(orientation, forKey: .orientation)
        try c.encode(fileCreatedAt, forKey: .fileCreatedAt)
        try c.encode(fileModifiedAt, forKey: .fileModifiedAt)
        // Mitgeschrieben, weil dieser Encoder allein für die Rundreise existiert
        // (siehe `stack` unten) und ein `Asset` nirgends an den Server geht.
        try c.encodeIfPresent(localDateTime, forKey: .localDateTime)
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
        try c.encode(isFavorite, forKey: .isFavorite)
        try c.encode(isArchived, forKey: .isArchived)
        try c.encodeIfPresent(duration, forKey: .duration)
        try c.encodeIfPresent(thumbhash, forKey: .thumbhash)
        try c.encode(isTrashed, forKey: .isTrashed)
        try c.encode(isOffline, forKey: .isOffline)
        try c.encode(isEdited, forKey: .isEdited)
        try c.encodeIfPresent(exifInfo, forKey: .exifInfo)
        try c.encodeIfPresent(people, forKey: .people)
        try c.encodeIfPresent(tags, forKey: .tags)
        try c.encodeIfPresent(_width, forKey: ._width)
        try c.encodeIfPresent(_height, forKey: ._height)
        // Re-serialise stack as a minimal nested object so round-trips work
        if let stackId {
            try c.encode(EncodableStack(id: stackId, assetCount: stackCount ?? 1), forKey: .stack)
        }
        try c.encodeIfPresent(livePhotoVideoId, forKey: .livePhotoVideoId)
        try c.encodeIfPresent(visibility, forKey: .visibility)
        // Aus demselben Grund mitgeschrieben wie `localDateTime` oben. `checksum`
        // stand in `CodingKeys` und wurde gelesen, aber nicht geschrieben — eine
        // Rundreise verlor die SHA-1 stillschweigend. Daran hängen die
        // Upload-Prüfung (`UploadManager.fetchServerChecksum`) und der exakte
        // Duplikat-Modus.
        try c.encodeIfPresent(checksum, forKey: .checksum)
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, originalFileName, originalPath, fileCreatedAt, fileModifiedAt, orientation, createdAt
        case localDateTime
        case isFavorite, isArchived, duration, thumbhash, isTrashed, isOffline, isEdited, exifInfo, people, tags
        case checksum
        case stack
        case livePhotoVideoId
        case visibility
        case _width = "width"
        case _height = "height"
    }

    /// Effective width: top-level from Immich API, falling back to EXIF
    var effectiveWidth: Int? { _width ?? exifInfo?.exifImageWidth }
    /// Effective height: top-level from Immich API, falling back to EXIF
    var effectiveHeight: Int? { _height ?? exifInfo?.exifImageHeight }

    // MARK: - Cached Formatters (avoid per-call allocation in hot paths)

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let detailDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.dateFormat = "d. MMMM yyyy 'um' HH:mm:ss"
        return f
    }()

    // MARK: - Computed Properties

    var isVideo: Bool { type == .video }

    /// Convenience: `isOffline` means it's in the locked folder
    var isLocked: Bool { isOffline }

    /// True when this asset is part of a stack.
    ///
    /// Maßgeblich ist `stackId`, **nicht** `stackCount`: Der Sync-Stream liefert die
    /// Kennung des Stapels, die Mitgliederzahl aber nicht — `CachedAsset.init(fromSync:)`
    /// hält das ausdrücklich fest und setzt `stackCount` auf `nil`.
    ///
    /// Hing die Antwort allein an der Anzahl, galt ein frisch über den Stream
    /// eingetroffenes Foto als nicht gestapelt: keine Stapel-Optik im Raster, und —
    /// schwerwiegender — unsichtbar für die Smart-Album-Regel „ist gestapelt". Bei
    /// einem gespiegelten Smart Album hätte dieser rein lokale Ausfall den Server
    /// erreicht und das Foto aus dem Album entfernt.
    ///
    /// Ein Stapel hat in Immich immer mindestens zwei Mitglieder; eine gesetzte
    /// Kennung genügt daher als Nachweis. Die Anzahl bleibt als zweite Quelle
    /// stehen, falls je ein Pfad nur sie liefert.
    var isStacked: Bool { stackId != nil || (stackCount ?? 0) > 1 }

    /// Zweiter Parser ohne Sekundenbruchteile.
    ///
    /// `ISO8601DateFormatter` mit `.withFractionalSeconds` weist einen Zeitstempel
    /// **ohne** Millisekunden ab — `2026-01-01T10:00:00Z` ergibt `nil`. Vier andere
    /// Stellen im Code fangen genau das mit einem Rückfall ab
    /// (`AlbumSyncManager.parseISODate`, `UploadManager:1512`,
    /// `AlbumsSidebarSection:489`); hier fehlte er.
    private static let isoFormatterWithoutFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Aufnahmezeitpunkt aus einem ISO-8601-String des Servers.
    ///
    /// Nimmt beide Schreibweisen an, mit und ohne Millisekunden. Zuvor nur mit —
    /// und ein `nil` bleibt hier nicht folgenlos: An `createdDate` hängen 27
    /// Stellen, darunter die Sortierung der Sammlungen
    /// (`($0.createdDate ?? .distantPast)` sortiert ans Ende), der Datumsfilter
    /// der Suche (`guard let date … else { return false }` blendet aus) und
    /// `FavoritesSyncManager.findOnServer`, wo ein Fehlschlag das Foto als „nicht
    /// auf dem Server" einstuft und **erneut hochlädt**.
    static func createdDate(from string: String) -> Date? {
        isoFormatter.date(from: string) ?? isoFormatterWithoutFractional.date(from: string)
    }

    /// ISO-8601-String im Server-Format (UTC, mit Millisekunden) — lexikografisch
    /// vergleichbar mit `fileCreatedAt`.
    static func isoString(from date: Date) -> String {
        isoFormatter.string(from: date)
    }

    var createdDate: Date? {
        Asset.createdDate(from: fileCreatedAt)
    }

    var uploadedDate: Date? {
        guard let createdAt else { return nil }
        return Asset.createdDate(from: createdAt)
    }

    /// "2024-01" style key for month grouping
    var monthKey: String {
        String(fileCreatedAt.prefix(7))
    }

    /// "2024" style key for year grouping
    var yearKey: String {
        String(fileCreatedAt.prefix(4))
    }

    /// German detail date, e.g. "31. Januar 2026 um 16:16:27"
    var detailDateString: String {
        Self.detailDateString(fromISO: fileCreatedAt)
    }

    /// Dasselbe aus dem rohen `fileCreatedAt` — für Stellen, die nur den String
    /// halten und erst bei Bedarf formatieren (VoiceOver-Beschriftung im Raster).
    static func detailDateString(fromISO iso: String) -> String {
        guard let date = createdDate(from: iso) else { return "" }
        return detailDateFormatter.string(from: date)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: Asset, rhs: Asset) -> Bool {
        lhs.id == rhs.id
    }
}

/// Lightweight struct that matches the "stack" sub-object in the Immich asset response:
/// { "id": "…", "assetCount": 3 }
private struct AssetStack: Decodable {
    let id: String
    let assetCount: Int
}

private struct EncodableStack: Encodable {
    let id: String
    let assetCount: Int
}

struct ExifInfo: Codable, Sendable {
    let make: String?
    let model: String?
    let exifImageWidth: Int?
    let exifImageHeight: Int?
    let fileSizeInByte: Int?
    let city: String?
    let state: String?
    let country: String?
    let latitude: Double?
    let longitude: Double?
    let focalLength: Double?
    let fNumber: Double?
    let iso: Double?
    let exposureTime: String?
    let lensModel: String?

    // MARK: - Nutzerdaten
    //
    // Immich führt diese drei unter `exifInfo`, obwohl sie nicht aus der Datei
    // stammen, sondern vom Nutzer gesetzt werden. Genau deshalb sind sie — anders
    // als Hersteller, Modell oder ISO — über `PUT /api/assets/{id}` schreibbar und
    // lassen sich vor dem Löschen eines Duplikats auf das Exemplar retten, das bleibt.

    let description: String?
    /// 0…5 Sterne.
    let rating: Int?
    /// Aufnahmezeit aus der Datei, ISO-8601. Fehlt sie, führt Immich nur den
    /// Importzeitpunkt — der Unterschied entscheidet, ob eine Übernahme sinnvoll ist.
    let dateTimeOriginal: String?

    /// Ausgeschrieben statt implizit, damit die drei Nutzerfelder Vorgaben haben
    /// können und die bestehenden Aufrufstellen unverändert bleiben.
    init(
        make: String?,
        model: String?,
        exifImageWidth: Int?,
        exifImageHeight: Int?,
        fileSizeInByte: Int?,
        city: String?,
        state: String?,
        country: String?,
        latitude: Double?,
        longitude: Double?,
        focalLength: Double?,
        fNumber: Double?,
        iso: Double?,
        exposureTime: String?,
        lensModel: String?,
        description: String? = nil,
        rating: Int? = nil,
        dateTimeOriginal: String? = nil
    ) {
        self.make = make
        self.model = model
        self.exifImageWidth = exifImageWidth
        self.exifImageHeight = exifImageHeight
        self.fileSizeInByte = fileSizeInByte
        self.city = city
        self.state = state
        self.country = country
        self.latitude = latitude
        self.longitude = longitude
        self.focalLength = focalLength
        self.fNumber = fNumber
        self.iso = iso
        self.exposureTime = exposureTime
        self.lensModel = lensModel
        self.description = description
        self.rating = rating
        self.dateTimeOriginal = dateTimeOriginal
    }
}

// MARK: - API Request/Response Models

struct SearchRequest: Encodable {
    let page: Int
    let size: Int
    let order: String
}

struct AssetSearchResponse: Decodable {
    let assets: AssetPage
}

struct AssetPage: Decodable {
    let items: [Asset]?
    let total: Int?
    let count: Int?
    /// Nur die alte flache Suchform blättert darüber; in der strukturierten Form
    /// (``AssetSearchQuery``) ist es stets `null`.
    let nextPage: String?
    /// Seit Server v3.2.0: Fortsetzung der strukturierten Suche. `nil` heißt Ende.
    let nextCursor: String?
}

/// Nur ID und Eigentümer eines Treffers — für Mengenfragen an die Suche.
struct AssetRef: Decodable, Equatable, Sendable {
    let id: String
    let ownerId: String
}

struct AssetRefSearchResponse: Decodable {
    struct Page: Decodable {
        let items: [AssetRef]
        let nextCursor: String?
    }
    let assets: Page
}

struct ServerAbout: Decodable {
    let version: String?
}

struct ServerVersion: Decodable {
    let major: Int
    let minor: Int
    let patch: Int
}

struct ServerPing: Decodable {
    let res: String
}

enum ThumbnailSize: String {
    case thumbnail
    case preview
}

// MARK: - Asset Group for timeline display

struct AssetGroup: Identifiable {
    let id: String       // adaptive section id from TimelineGrouping ("2026-07-20", "2026-06", "2023")
    let title: String    // "Heute", "Letzte Woche", "Juni", "2023"
    let assets: [Asset]
}

struct AssetStatistics: Decodable {
    let images: Int
    let videos: Int
    let total: Int
}
