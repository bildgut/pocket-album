import Foundation

/// A recognized person/face cluster from Immich.
struct Person: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let birthDate: String?
    let thumbnailPath: String?
    let isHidden: Bool?
    let isFavorite: Bool?

    /// Number of assets containing this person
    let assetCount: Int?

    var displayName: String {
        name.isEmpty ? "Unbenannt" : name
    }
}

/// Response wrapper for people list
struct PeopleResponse: Decodable {
    let total: Int
    let people: [Person]
    let hidden: Int?
    let hasNextPage: Bool?
}

/// Antwort der Bulk-Endpunkte: pro ID ein eigenes Ergebnis.
///
/// Ein Merge kann **teilweise** gelingen — ein reiner Statuscode-Check würde einen
/// halb durchgelaufenen Merge als vollen Erfolg melden.
struct BulkIdResponse: Decodable {
    let id: String
    let success: Bool
    let error: String?
}

/// Drei Zustände für das Geburtsdatum.
///
/// Mit einem schlichten `Date?` ließe sich „Feld weglassen" nicht von „auf null setzen"
/// unterscheiden — der Fehler, nach dem sich ein einmal gesetztes Geburtsdatum nie
/// wieder löschen lässt.
enum PersonBirthDateUpdate: Equatable {
    case unchanged
    case clear
    case set(Date)

    /// `en_US_POSIX` fixiert das Format gegen fremde Gebietsschemata.
    ///
    /// Die Zeitzone ist bewusst die **lokale**, nicht UTC: `birthDate` ist ein reines
    /// Kalenderdatum ohne Uhrzeit, und die Datumsauswahl liefert lokale Mitternacht.
    /// In UTC formatiert würde daraus östlich von Greenwich der Vortag — ein am 5. Juni
    /// gewählter Geburtstag käme als 4. Juni auf dem Server an.
    private static var formatter: DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    /// Wert für den JSON-Body, oder `nil` wenn das Feld ganz entfallen soll.
    var jsonValue: Any? {
        switch self {
        case .unchanged:    return nil
        case .clear:        return NSNull()
        case .set(let date): return Self.formatter.string(from: date)
        }
    }

    static func parse(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        return formatter.date(from: String(raw.prefix(10)))
    }
}
