import Foundation

/// A time-based memory from Immich ("On This Day" style).
///
/// `GET /api/memories` **ohne** Parameter liefert alle Erinnerungen, auch längst
/// abgelaufene und künftige (`showAt`/`hideAt`) — für „heute" gehört `for=YYYY-MM-DD`
/// dazu, siehe `ImmichAPIClient.getMemories(for:isSaved:calendar:)`.
struct Memory: Codable, Identifiable {
    let id: String
    let type: String?
    let data: MemoryData?
    let assets: [Asset]?
    let createdAt: String?
    /// Gemerkt — der Server löscht gemerkte Erinnerungen nie (ab v3.2.0 sichtbar).
    let isSaved: Bool?
    /// Der Tag, an den erinnert wird.
    let memoryAt: String?
    let showAt: String?
    let hideAt: String?
}

struct MemoryData: Codable {
    let year: Int?
}

/// Eine Erinnerungskarte der Oberfläche.
///
/// Heutige Erinnerungen kommen je Jahr einzeln vom Server (oft mehrere mit demselben
/// `year`) und werden zu **einer** Karte je Jahr gebündelt („Vor 1 Jahr", „Vor 5
/// Jahren"). Gemerkte stehen dagegen je Erinnerung für sich: Sie stammen von
/// verschiedenen Tagen, und mit dem Jahr als Kennung fielen zwei gemerkte aus
/// demselben Jahr zu einer Karte zusammen.
struct GroupedMemory: Identifiable, Equatable {
    enum Kind: Equatable {
        case today
        case saved
    }

    let id: String
    let kind: Kind
    let year: Int
    /// Tag der Erinnerung — nur bei gemerkten eindeutig.
    let memoryAt: Date?
    /// Die Original-IDs der Memories hinter dieser Karte.
    var memoryIds: [String]
    /// Alle Assets, nach Datum absteigend.
    var assets: [Asset]
    /// Alle Erinnerungen dieser Karte sind gemerkt.
    var isSaved: Bool

    /// Heutige Erinnerungen, eine Karte je Jahr, jüngstes Jahr zuerst.
    static func today(from raw: [Memory]) -> [GroupedMemory] {
        var byYear: [Int: [Memory]] = [:]
        for memory in raw {
            guard let year = memory.data?.year, let assets = memory.assets, !assets.isEmpty else { continue }
            byYear[year, default: []].append(memory)
        }
        return byYear
            .map { year, memories in
                GroupedMemory(
                    id: "jahr-\(year)",
                    kind: .today,
                    year: year,
                    memoryAt: nil,
                    memoryIds: memories.map(\.id),
                    assets: sortedByDate(memories.flatMap { $0.assets ?? [] }),
                    isSaved: memories.allSatisfy { $0.isSaved == true }
                )
            }
            .sorted { $0.year > $1.year }
    }

    /// Gemerkte Erinnerungen, eine Karte je Erinnerung, jüngster Tag zuerst.
    static func saved(from raw: [Memory]) -> [GroupedMemory] {
        raw.compactMap { memory -> GroupedMemory? in
            guard let assets = memory.assets, !assets.isEmpty else { return nil }
            let day = memory.memoryAt.flatMap(Asset.createdDate(from:))
            let year = memory.data?.year ?? day.map { utcCalendar.component(.year, from: $0) }
            guard let year else { return nil }
            return GroupedMemory(
                id: "gemerkt-\(memory.id)",
                kind: .saved,
                year: year,
                memoryAt: day,
                memoryIds: [memory.id],
                assets: sortedByDate(assets),
                isSaved: true
            )
        }
        .sorted { ($0.memoryAt ?? .distantPast) > ($1.memoryAt ?? .distantPast) }
    }

    /// „Dieses Jahr", „Vor 1 Jahr", „Vor 5 Jahren".
    func relativeTitle(currentYear: Int = Calendar.current.component(.year, from: Date())) -> String {
        let difference = max(0, currentYear - year)
        switch difference {
        case 0: return "Dieses Jahr"
        case 1: return "Vor 1 Jahr"
        default: return "Vor \(difference) Jahren"
        }
    }

    /// Das Jahr — bei gemerkten Erinnerungen der ganze Tag.
    ///
    /// In UTC formatiert: `memoryAt` ist Mitternacht UTC des Tages; in einer Zone
    /// westlich von Greenwich stünde sonst der Vortag da.
    var dateLabel: String {
        guard kind == .saved, let memoryAt else { return String(year) }
        return Self.dayFormatter.string(from: memoryAt)
    }

    private static func sortedByDate(_ assets: [Asset]) -> [Asset] {
        assets.sorted { ($0.createdDate ?? .distantPast) > ($1.createdDate ?? .distantPast) }
    }

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.calendar = utcCalendar
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "d. MMMM yyyy"
        return formatter
    }()
}

/// A map marker representing an asset's GPS location.
struct MapMarker: Codable, Identifiable {
    let id: String
    let lat: Double
    let lon: Double
    let city: String?
    let state: String?
    let country: String?
}

/// A grouped place (city) derived from MapMarkers for the Places overview.
struct PlaceItem: Identifiable {
    let id: String          // city name used as stable id
    let city: String
    let country: String?
    let assetCount: Int
    let previewAssetId: String  // Used for thumbnail
}
