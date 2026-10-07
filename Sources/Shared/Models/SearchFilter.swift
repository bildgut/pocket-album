import Foundation

// MARK: - Strukturierte Suche (Immich v3.2.0)

/// Der `filter` der strukturierten Suche an `POST /api/search/metadata` (und
/// `/search/smart`, `/search/random`, `/search/statistics`), seit Server v3.2.0.
///
/// Alle gesetzten Felder sind UND-verknüpft; ``or`` hängt eine Ebene ODER-Zweige an,
/// in die die Felder der obersten Ebene jeweils mit hineinwirken. Ein Zweig darf
/// selbst kein ``or`` tragen und nicht leer sein — der Server prüft streng und
/// antwortet sonst mit 400, ebenso bei unbekannten Schlüsseln.
///
/// **Fallen, die die alte flache Form nicht hatte** (am Server nachgemessen):
/// - Ohne ``trashedAt`` ist der **Papierkorb dabei**; der alte Standard braucht
///   `trashedAt: .isNull`.
/// - Ohne ``visibility`` sind Archiv und `hidden` (Bewegtbild-Anteile von Live
///   Photos) dabei, nur `locked` nicht.
/// - Eine `visibility`-Bedingung, die `locked` treffen *könnte* (etwa
///   `.notEquals(.timeline)`), gibt ohne entsperrte Sitzung **401**. Positivlisten
///   (`.oneOf([.timeline, .archive])`) sind sicher.
/// - ``takenAt`` vergleicht `fileCreatedAt` in UTC, nicht die Ortszeit des Fotos.
/// - Die alten flachen Felder (`page`, `order`, `isFavorite` …) dürfen **nicht**
///   neben `filter` stehen — 400.
///
/// Felder für Blende, ISO, GPS-Umkreis und `stackId` gibt es nicht.
struct SearchFilter: Encodable, Equatable, Sendable {
    var type: SearchCondition<AssetType>?
    var visibility: SearchCondition<AssetVisibility>?

    var isFavorite: SearchCondition<Bool>?
    /// Standbild mit Bewegtbild-Anteil (`livePhotoVideoId` gesetzt).
    var isMotion: SearchCondition<Bool>?
    var hasAlbums: SearchCondition<Bool>?
    var hasPeople: SearchCondition<Bool>?
    var hasTags: SearchCondition<Bool>?

    var city: SearchCondition<String>?
    var state: SearchCondition<String>?
    var country: SearchCondition<String>?
    var make: SearchCondition<String>?
    var model: SearchCondition<String>?
    var lensModel: SearchCondition<String>?

    /// Muster (`like`, `startsWith` …) ignorieren Groß-/Kleinschreibung und Akzente.
    var description: SearchCondition<String>?
    var originalFileName: SearchCondition<String>?
    var ocr: SearchSimilarity?

    var rating: SearchCondition<Int>?
    var fileSizeInBytes: SearchCondition<Int>?
    var checksum: SearchCondition<String>?

    var takenAt: SearchCondition<String>?
    var createdAt: SearchCondition<String>?
    var updatedAt: SearchCondition<String>?
    var trashedAt: SearchCondition<String>?

    var personIds: SearchIds?
    var tagIds: SearchIds?
    /// Durchsucht die Alben unabhängig vom Eigentümer der Assets; fremde Alben-IDs
    /// beantwortet der Server mit „no album.read access".
    var albumIds: SearchIds?

    var or: [SearchFilter]?

    init() {}

    /// Was der iOS-Reiter „Fotos" zeigt: die Zeitleiste ohne Archiv, Papierkorb und
    /// Bewegtbild-Anteile — optional nur ein Typ.
    static func visibleLibrary(type: AssetType?) -> SearchFilter {
        var filter = SearchFilter()
        filter.visibility = .oneOf([.timeline])
        filter.trashedAt = .isNull
        if let type { filter.type = .equals(type) }
        return filter
    }

    /// Derselbe Filter über die eigene Bibliothek **und** die Fotos geteilter Alben.
    ///
    /// Ohne ``albumIds`` sucht der Server nur in Assets, die dem Konto gehören — ein
    /// Album, das jemand anderes teilt, bleibt für Suche, Zählung und Orte unsichtbar.
    /// Mit ``albumIds`` sucht er dagegen unabhängig vom Eigentümer. Beides zusammen
    /// geht nur als ``or``: ein Zweig für die eigene Bibliothek, einer für die Alben.
    /// Am Demo-Server am 07.10.2026 gemessen: Das Hauptkonto zählt damit unverändert
    /// 133 (seine Album-Fotos gehören ihm ohnehin, nichts doppelt), ein Konto mit nur
    /// einem geteilten Album 50 statt 0; Land- und Stadtfilter der obersten Ebene
    /// wirken in beide Zweige (Japan 38, Tokyo 2), die Bildsuche nimmt die Form auch.
    ///
    /// Ein Zweig darf nicht leer sein (400). Deshalb wandert ``trashedAt`` in beide
    /// Zweige — die einzige Bedingung, die ohnehin für beide gilt. Steht schon ein
    /// ``or`` im Filter, bleibt er unverändert: Zweige dürfen nicht verschachtelt werden.
    func mitGeteiltenAlben(_ albumIds: [String]) -> SearchFilter {
        guard !albumIds.isEmpty, or == nil else { return self }
        var filter = self
        let papierkorb = filter.trashedAt ?? .isNull
        filter.trashedAt = nil
        var eigene = SearchFilter()
        eigene.trashedAt = papierkorb
        var geteilte = SearchFilter()
        geteilte.trashedAt = papierkorb
        geteilte.albumIds = .anyOf(albumIds)
        filter.or = [eigene, geteilte]
        return filter
    }
}

/// Ein Wert, der auch ausdrücklich JSON-`null` sein darf (`{"eq": null}`).
enum SearchNullable<Value: Encodable & Equatable & Sendable>: Encodable, Equatable, Sendable {
    case null
    case value(Value)

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .value(let value): try container.encode(value)
        }
    }
}

/// Eine Bedingung auf ein Feld. Welche Operatoren ein Feld annimmt, bestimmt der
/// Server je Feld (`StringFilterNullable`, `DateFilter` …) — die Fabrikmethoden
/// unten decken die gebrauchten Fälle ab, gesetzte Felder werden sonst nicht geprüft.
struct SearchCondition<Value: Encodable & Equatable & Sendable>: Encodable, Equatable, Sendable {
    var eq: SearchNullable<Value>?
    var ne: SearchNullable<Value>?
    var `in`: [Value]?
    var notIn: [Value]?
    var lt: Value?
    var lte: Value?
    var gt: Value?
    var gte: Value?
    var like: String?
    var notLike: String?
    var startsWith: String?
    var endsWith: String?

    static func equals(_ value: Value) -> Self { var c = Self(); c.eq = .value(value); return c }
    static func notEquals(_ value: Value) -> Self { var c = Self(); c.ne = .value(value); return c }
    static func oneOf(_ values: [Value]) -> Self { var c = Self(); c.in = values; return c }
    static func noneOf(_ values: [Value]) -> Self { var c = Self(); c.notIn = values; return c }
    /// Nur für Felder, die der Server als nullable führt (`city`, `rating`, `trashedAt` …).
    static var isNull: Self { var c = Self(); c.eq = .null; return c }
    static var isNotNull: Self { var c = Self(); c.ne = .null; return c }

    private init() {}
}

extension SearchCondition where Value == String {
    /// Enthält `text` (`like`; `%` und `_` im Text wirken als Platzhalter).
    static func contains(_ text: String) -> Self { var c = Self(); c.like = text; return c }
    static func hasPrefix(_ text: String) -> Self { var c = Self(); c.startsWith = text; return c }
    static func hasSuffix(_ text: String) -> Self { var c = Self(); c.endsWith = text; return c }

    /// Halboffenes Zeitfenster `[from, to)`.
    static func between(_ from: Date, and to: Date) -> Self {
        var c = Self(); c.gte = iso(from); c.lt = iso(to); return c
    }
    /// Geschlossenes Zeitfenster `[from, to]`.
    static func between(_ from: Date, andIncluding to: Date) -> Self {
        var c = Self(); c.gte = iso(from); c.lte = iso(to); return c
    }
    static func onOrAfter(_ date: Date) -> Self { var c = Self(); c.gte = iso(date); return c }
    static func before(_ date: Date) -> Self { var c = Self(); c.lt = iso(date); return c }
    static func onOrBefore(_ date: Date) -> Self { var c = Self(); c.lte = iso(date); return c }

    /// Zeitraum einer `SmartAlbumRule.dateRange`, beide Grenzen inklusive.
    ///
    /// `distantPast` als Anfang bzw. `distantFuture` als Ende stehen für eine **offene**
    /// Seite („bis 2018", „seit 2020"): Die Regel bleibt für den lokalen Auswerter ein
    /// gewöhnlicher Vergleich, zum Server geht nur die gesetzte Seite. Sonst stünde dort
    /// das Jahr 4001. Beide Seiten offen → keine Bedingung.
    static func dateRange(from: Date, to: Date) -> Self? {
        switch (from == .distantPast, to == .distantFuture) {
        case (true, true):   return nil
        case (true, false):  return .onOrBefore(to)
        case (false, true):  return .onOrAfter(from)
        case (false, false): return .between(from, andIncluding: to)
        }
    }

    /// Das Format, das Immich selbst ausgibt: UTC mit Millisekunden.
    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

extension SearchCondition where Value: Comparable {
    static func atLeast(_ value: Value) -> Self { var c = Self(); c.gte = value; return c }
    static func atMost(_ value: Value) -> Self { var c = Self(); c.lte = value; return c }
}

/// Bedingung auf eine ID-Liste (`personIds`, `tagIds`, `albumIds`). `tagIds` schließt
/// Unter-Tags ein.
struct SearchIds: Encodable, Equatable, Sendable {
    var any: [String]?
    var all: [String]?
    var none: [String]?

    // Nicht `.none(_:)`: An einem `SearchIds?` griffe sonst `Optional.none`.
    static func anyOf(_ ids: [String]) -> Self { Self(any: ids) }
    static func allOf(_ ids: [String]) -> Self { Self(all: ids) }
    static func noneOf(_ ids: [String]) -> Self { Self(none: ids) }
}

/// Texterkennung im Bild (Trigramm-Ähnlichkeit).
struct SearchSimilarity: Encodable, Equatable, Sendable {
    var matches: String
    static func matches(_ text: String) -> Self { Self(matches: text) }
}

struct SearchOrder: Encodable, Equatable, Sendable {
    enum Field: String, Encodable, Sendable {
        case fileCreatedAt, localDateTime, fileSizeInBytes, rating
    }
    enum Direction: String, Encodable, Sendable {
        case asc, desc
    }
    var field: Field
    var direction: Direction
}

/// Anfragekörper der strukturierten Metadatensuche. Geblättert wird über
/// ``cursor`` (aus `AssetPage.nextCursor`), nicht über Seitennummern. Der Cursor ist
/// ein verpackter Offset: Wer ihn mit einem anderen Filter weiterverwendet, bekommt
/// keinen Fehler, sondern übersprungene oder doppelte Treffer.
struct AssetSearchQuery: Encodable, Equatable, Sendable {
    var filter: SearchFilter
    var orderBy: SearchOrder?
    var cursor: String?
    /// 1–1000, Server-Vorgabe 250.
    var size: Int?
    var withExif: Bool?
    var withPeople: Bool?
    var withStacked: Bool?

    init(
        filter: SearchFilter,
        orderBy: SearchOrder? = nil,
        cursor: String? = nil,
        size: Int? = nil,
        withExif: Bool? = nil,
        withPeople: Bool? = nil,
        withStacked: Bool? = nil
    ) {
        self.filter = filter
        self.orderBy = orderBy
        self.cursor = cursor
        self.size = size
        self.withExif = withExif
        self.withPeople = withPeople
        self.withStacked = withStacked
    }
}
