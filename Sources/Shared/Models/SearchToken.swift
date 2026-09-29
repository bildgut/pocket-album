import Foundation

/// Welches EXIF-Feld ein Kamera-Chip filtert. Hersteller und Modell sind auf dem Server
/// getrennte Felder (`make`, `model`), und nicht jedes Modell trägt den Hersteller im
/// Namen („X-T3" ist Fujifilm, „DSC-RX100" Sony).
enum CameraField: String, Codable {
    case make
    case model
}

// MARK: - SearchToken

/// A structured filter token that can be combined with free-text CLIP search.
/// Tokens appear as removable pills in the search bar.
enum SearchToken: Equatable, Identifiable, Codable {

    case type(AssetType)                          // type:photo / type:video
    case person(id: String, name: String)         // person:Clara
    case year(Int)                                // year:2024
    case date(Date)                               // specific day: 16.10.2019
    case city(String)                             // place:Berlin
    case country(String)                          // country:Deutschland
    case favorite                                 // is:favorite
    case tag(id: String, value: String)           // tag:reise
    case album(id: String, name: String)          // album:Urlaub

    /// Umkreis um eine geokodierte Adresse — der einzige Weg zu einer Straßensuche.
    ///
    /// Immich reverse-geokodiert nur bis zur Stadt (`ExifInfo` kennt `city`, `state`,
    /// `country` und sonst nichts), eine Straße steht in keinem Feld. Die Koordinaten
    /// stehen aber pro Foto im Grid-Index, also wird einmal die *Eingabe* vorwärts
    /// geokodiert und danach lokal nach Entfernung gefiltert.
    ///
    /// Rein lokal: Der Server kennt keinen Radiusfilter (siehe `ServerFilters`).
    case nearby(lat: Double, lon: Double, radius: Double, label: String)

    /// Zeitraum aus der Satzerkennung („letzten Sommer", „seit 2020"). Eine Seite darf
    /// offen sein: „seit 2020" hat **kein** Ende „heute" — ein daraus gesichertes Smart
    /// Album nähme sonst ab morgen keine neuen Fotos mehr auf.
    ///
    /// `from` ist der Beginn des ersten Tages, `to` das Ende des letzten (inklusive,
    /// wie `SmartAlbumEvaluator.dayRange`). Die Beschriftung kommt vom Erzeuger, weil
    /// „Sommer 2026" sich aus zwei Daten nicht zurückgewinnen lässt.
    case dateRange(from: Date?, to: Date?, label: String)

    /// Kamera aus der Satzerkennung. Die Werte stehen beim Zerlegen fest (Katalogwerte),
    /// denn der Server vergleicht `make`/`model` nur exakt.
    case camera(field: CameraField, values: [String], label: String)

    /// Text, der im Bild steht („Reisepass" auf dem Foto eines Passes) — die
    /// Texterkennung des Servers (`filter.ocr`), wie „OCR" in Immich Web. Der Server
    /// vergleicht per Trigramm-Ähnlichkeit, Tippfehler verzeiht er also teilweise.
    case imageText(String)

    // MARK: Identifiable

    var id: String {
        switch self {
        case .type(let t):              return "type:\(t.rawValue)"
        case .person(let id, _):        return "person:\(id)"
        case .year(let y):              return "year:\(y)"
        case .date(let d):              return "date:\(d.timeIntervalSince1970)"
        case .city(let c):              return "city:\(c)"
        case .country(let c):           return "country:\(c)"
        case .favorite:                 return "is:favorite"
        case .tag(let id, _):           return "tag:\(id)"
        case .album(let id, _):         return "album:\(id)"
        // Ohne den Radius: Wer ihn im Chipmenü verstellt, verändert denselben Chip,
        // statt einen zweiten daneben zu stellen.
        case .nearby(let lat, let lon, _, _):
            return String(format: "nearby:%.5f,%.5f", lat, lon)
        case .dateRange(let from, let to, _):
            let von = from.map { String($0.timeIntervalSince1970) } ?? "offen"
            let bis = to.map { String($0.timeIntervalSince1970) } ?? "offen"
            return "dateRange:\(von)-\(bis)"
        case .camera(let field, _, let label):
            return "camera:\(field.rawValue):\(label.lowercased())"
        case .imageText(let text):
            return "text:\(text.lowercased())"
        }
    }

    // MARK: Display

    var label: String {
        switch self {
        case .type(let t):              return t == .image ? "Fotos" : "Videos"
        case .person(_, let name):      return name
        case .year(let y):              return "\(y)"
        case .date(let d):              return Self.dayFormatter.string(from: d)
        case .city(let c):              return c
        case .country(let c):           return c
        case .favorite:                 return "Favoriten"
        case .tag(_, let value):        return value
        case .album(_, let name):       return name
        case .nearby(_, _, let radius, let label):
            return "\(label) · \(Self.radiusLabel(radius))"
        case .dateRange(_, _, let label): return label
        case .camera(_, _, let label):    return label
        case .imageText(let text):        return "„\(text)“"
        }
    }

    /// Kurzform für den Chip: „250 m" bzw. „1 km".
    static func radiusLabel(_ meters: Double) -> String {
        if meters >= 1000 {
            let km = meters / 1000
            return km == km.rounded() ? "\(Int(km)) km" : String(format: "%.1f km", km)
        }
        return "\(Int(meters)) m"
    }

    /// Auswahl im Radiusmenü des Umkreis-Chips.
    static let radiusOptions: [Double] = [100, 250, 1000, 5000]

    /// Auf `en_US_POSIX` festgelegt, damit das Muster `dd.MM.yyyy` überall dasselbe
    /// bedeutet: Ohne gepinntes Locale übernimmt `DateFormatter` den Kalender des
    /// Nutzers, und unter einem nicht-gregorianischen Kalender (etwa `th_TH`,
    /// buddhistisch) stünde im Chip 2562 statt 2019.
    ///
    /// Statisch, weil `label` aus der Suchleiste bei jedem Neuzeichnen läuft und
    /// `DateFormatter()` teuer zu bauen ist.
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "dd.MM.yyyy"
        return f
    }()

    var iconName: String {
        switch self {
        case .type(let t):    return t == .image ? "photo" : "video.fill"
        case .person:         return "person.fill"
        case .year:           return "calendar"
        case .date:           return "calendar.badge.clock"
        case .city, .country: return "location.fill"
        case .favorite:       return "heart.fill"
        case .tag:            return "tag.fill"
        case .album:          return "rectangle.stack.fill"
        case .nearby:         return "mappin.and.ellipse"
        case .dateRange:      return "calendar"
        case .camera:         return "camera.fill"
        case .imageText:      return "text.viewfinder"
        }
    }

    // MARK: Zeitraum

    /// Der Zeitraum, den dieses Token abdeckt — `nil` für alles ohne Datumsbezug. Eine
    /// Seite ist `nil`, wenn sie offen ist (nur bei `.dateRange`).
    ///
    /// **Die** eine Stelle, an der aus Jahr oder Datum eine Spanne wird. Vorher gab es
    /// drei: eine inzwischen entfernte Token-Abbildung, die alte CLIP-Suche und
    /// `SaveSearchAsSmartAlbumSheet`, und
    /// alle drei rechneten anders. Zwei davon rechneten in UTC und schnitten damit den
    /// Jahres- bzw. Tagesrand ab: Ein Foto vom 1. Januar 00:30 Berliner Zeit liegt in
    /// UTC noch im Vorjahr und fiel aus `year:2024` heraus.
    ///
    /// Deshalb hier über dieselben lokalen Helfer wie die Smart-Album-Regeln
    /// (`SearchDateRangeTests` sichert genau diese Gleichheit ab).
    var dateRange: (from: Date?, to: Date?)? {
        switch self {
        case .year(let y):
            return SmartAlbumEvaluator.yearRange(for: y).map { ($0.from, $0.to) }
        case .date(let d):
            let tag = SmartAlbumEvaluator.dayRange(for: d)
            return (tag.from, tag.to)
        case .dateRange(let from, let to, _):
            return (from, to)
        default:
            return nil
        }
    }

    /// Millisekundengenau mit `Z`-Suffix — das Format, das Immich für `takenAfter`
    /// und `takenBefore` erwartet.
    static let isoUTC: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()
}

// MARK: - SavedSearch

struct SavedSearch: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var query: String
    var tokens: [SearchToken]
    var date: Date = Date()
    var isPinned: Bool = false

    var displayTitle: String {
        var parts: [String] = tokens.map(\.label)
        if !query.isEmpty { parts.append(query) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Codable conformance for SearchToken

extension SearchToken {
    private enum CodingKeys: String, CodingKey {
        case kind, typeValue, personId, personName, year, date, city, country, tagId, tagValue
        case albumId, albumName
        case lat, lon, radius, placeLabel
        case rangeFrom, rangeTo, rangeLabel
        case cameraField, cameraValues, cameraLabel
        case imageText
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .type(let t):
            try c.encode("type", forKey: .kind)
            try c.encode(t.rawValue, forKey: .typeValue)
        case .person(let id, let name):
            try c.encode("person", forKey: .kind)
            try c.encode(id, forKey: .personId)
            try c.encode(name, forKey: .personName)
        case .year(let y):
            try c.encode("year", forKey: .kind)
            try c.encode(y, forKey: .year)
        case .date(let d):
            try c.encode("date", forKey: .kind)
            try c.encode(d.timeIntervalSince1970, forKey: .date)
        case .city(let v):
            try c.encode("city", forKey: .kind)
            try c.encode(v, forKey: .city)
        case .country(let v):
            try c.encode("country", forKey: .kind)
            try c.encode(v, forKey: .country)
        case .favorite:
            try c.encode("favorite", forKey: .kind)
        case .tag(let id, let value):
            try c.encode("tag", forKey: .kind)
            try c.encode(id, forKey: .tagId)
            try c.encode(value, forKey: .tagValue)
        case .album(let id, let name):
            try c.encode("album", forKey: .kind)
            try c.encode(id, forKey: .albumId)
            try c.encode(name, forKey: .albumName)
        case .nearby(let lat, let lon, let radius, let label):
            try c.encode("nearby", forKey: .kind)
            try c.encode(lat, forKey: .lat)
            try c.encode(lon, forKey: .lon)
            try c.encode(radius, forKey: .radius)
            try c.encode(label, forKey: .placeLabel)
        case .dateRange(let from, let to, let label):
            try c.encode("dateRange", forKey: .kind)
            try c.encodeIfPresent(from?.timeIntervalSince1970, forKey: .rangeFrom)
            try c.encodeIfPresent(to?.timeIntervalSince1970, forKey: .rangeTo)
            try c.encode(label, forKey: .rangeLabel)
        case .camera(let field, let values, let label):
            try c.encode("camera", forKey: .kind)
            try c.encode(field.rawValue, forKey: .cameraField)
            try c.encode(values, forKey: .cameraValues)
            try c.encode(label, forKey: .cameraLabel)
        case .imageText(let text):
            try c.encode("imageText", forKey: .kind)
            try c.encode(text, forKey: .imageText)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "type":
            let raw = try c.decode(String.self, forKey: .typeValue)
            self = .type(AssetType(rawValue: raw) ?? .image)
        case "person":
            self = .person(
                id:   try c.decode(String.self, forKey: .personId),
                name: try c.decode(String.self, forKey: .personName)
            )
        case "year":
            self = .year(try c.decode(Int.self, forKey: .year))
        case "date":
            let ts = try c.decode(Double.self, forKey: .date)
            self = .date(Date(timeIntervalSince1970: ts))
        case "city":
            self = .city(try c.decode(String.self, forKey: .city))
        case "country":
            self = .country(try c.decode(String.self, forKey: .country))
        case "favorite":
            self = .favorite
        case "tag":
            self = .tag(
                id:    try c.decode(String.self, forKey: .tagId),
                value: try c.decode(String.self, forKey: .tagValue)
            )
        case "album":
            self = .album(
                id:   try c.decode(String.self, forKey: .albumId),
                name: try c.decode(String.self, forKey: .albumName)
            )
        case "nearby":
            self = .nearby(
                lat:    try c.decode(Double.self, forKey: .lat),
                lon:    try c.decode(Double.self, forKey: .lon),
                radius: try c.decode(Double.self, forKey: .radius),
                label:  try c.decode(String.self, forKey: .placeLabel)
            )
        case "dateRange":
            self = .dateRange(
                from:  try c.decodeIfPresent(Double.self, forKey: .rangeFrom).map(Date.init(timeIntervalSince1970:)),
                to:    try c.decodeIfPresent(Double.self, forKey: .rangeTo).map(Date.init(timeIntervalSince1970:)),
                label: try c.decode(String.self, forKey: .rangeLabel)
            )
        case "camera":
            let raw = try c.decode(String.self, forKey: .cameraField)
            self = .camera(
                field:  CameraField(rawValue: raw) ?? .model,
                values: try c.decode([String].self, forKey: .cameraValues),
                label:  try c.decode(String.self, forKey: .cameraLabel)
            )
        case "imageText":
            self = .imageText(try c.decode(String.self, forKey: .imageText))
        default:
            self = .favorite // Fallback — should never happen
        }
    }
}
