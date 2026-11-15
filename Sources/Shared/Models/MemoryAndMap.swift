import Foundation
import CoreGraphics

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

    @discardableResult
    mutating func applyFavorites(_ favoritesById: [String: Bool]) -> Bool {
        assets.applyFavorites(favoritesById)
    }

    static func == (lhs: GroupedMemory, rhs: GroupedMemory) -> Bool {
        guard lhs.id == rhs.id,
              lhs.kind == rhs.kind,
              lhs.year == rhs.year,
              lhs.memoryAt == rhs.memoryAt,
              lhs.memoryIds == rhs.memoryIds,
              lhs.isSaved == rhs.isSaved,
              lhs.assets.count == rhs.assets.count else {
            return false
        }
        return zip(lhs.assets, rhs.assets).allSatisfy { a, b in
            a.id == b.id
                && a.isFavorite == b.isFavorite
                && a.isArchived == b.isArchived
                && a.isTrashed == b.isTrashed
                && a.isEdited == b.isEdited
        }
    }

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

    // MARK: - Smart-Kuratierung & Kontext

    private var visibleAssets: [Asset] {
        let filtered = assets.filter { !$0.istVersteckterBewegtbildAnteil }
        return filtered.isEmpty ? assets : filtered
    }

    /// Geklemmtes Seitenverhältnis (Breite / Höhe) für Streifen-Layouts, inkl. EXIF-Orientierung.
    static func aspectRatio(of asset: Asset) -> CGFloat {
        let ratio = rawAspectRatio(of: asset)
        return min(1.85, max(0.65, ratio))
    }

    private static func rawAspectRatio(of asset: Asset) -> CGFloat {
        guard let rawW = asset.effectiveWidth, let rawH = asset.effectiveHeight,
              rawW > 0, rawH > 0 else {
            return 4.0 / 3.0
        }
        let swapsAxes = [5, 6, 7, 8].contains(asset.orientation ?? 1)
        let width = swapsAxes ? rawH : rawW
        let height = swapsAxes ? rawW : rawH
        return CGFloat(width) / CGFloat(height)
    }

    /// Wählt das stärkste Titelbild (Favoriten, Personen, GPS, Quer-/moderates Hochformat)
    /// statt blind das erste Asset zu nehmen.
    var coverAsset: Asset? {
        Self.bestCover(in: visibleAssets) ?? assets.first
    }

    private static func coverScore(of asset: Asset) -> Double {
        var score = HighlightScorer.score(asset: asset, homeLat: nil, homeLon: nil)
        if WebOriginDetector.isWebOrMessenger(asset, exifIsAuthoritative: true) != true {
            score += 1.5
        }
        let ratio = rawAspectRatio(of: asset)
        if (0.75...1.6).contains(ratio) {
            score += 1.0
        }
        return score
    }

    private static func bestCover(in candidates: [Asset]) -> Asset? {
        guard !candidates.isEmpty else { return nil }
        var best: Asset?
        var bestScore = -Double.infinity
        for asset in candidates {
            let score = coverScore(of: asset)
            if score > bestScore {
                bestScore = score
                best = asset
            }
        }
        return best
    }

    /// Erkennt Screenshots, Messenger-/Web-Downloads sowie Nicht-Favoriten-Bilder mit
    /// bekannten EXIF-Daten ohne Kamera, GPS und erkannte Personen.
    static func isClutterAsset(_ asset: Asset) -> Bool {
        guard !asset.isFavorite else { return false }
        if ScreenshotDetector.isScreenshot(asset)
            || WebOriginDetector.isWebOrMessenger(asset, exifIsAuthoritative: true) == true {
            return true
        }
        if asset.type == .image, let exif = asset.exifInfo {
            let makeEmpty = (exif.make ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            let modelEmpty = (exif.model ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            let noGPS = exif.latitude == nil && exif.longitude == nil
            let noPeople = (asset.people ?? []).isEmpty
            if makeEmpty && modelEmpty && noGPS && noPeople {
                return true
            }
        }
        return false
    }

    /// Filtert versteckte Live-Photo-Videos sowie optional Beifang (Screenshots,
    /// Messenger-/Web-Downloads, EXIF-lose Shop-/Webbilder) und bündelt dichte Burst-Serien.
    func curatedAssets(hideClutter: Bool = true, burstWindowSeconds: TimeInterval = 15) -> [Asset] {
        curatedAssets(hideClutter: hideClutter, burstWindowSeconds: burstWindowSeconds, fallbackToAllIfEmpty: true)
    }

    private func curatedAssets(
        hideClutter: Bool,
        burstWindowSeconds: TimeInterval,
        fallbackToAllIfEmpty: Bool
    ) -> [Asset] {
        let base = visibleAssets
        guard hideClutter, !base.isEmpty else { return base }

        let withoutClutter = base.filter { !Self.isClutterAsset($0) }
        let candidates: [Asset]
        if withoutClutter.isEmpty {
            guard fallbackToAllIfEmpty else { return [] }
            candidates = base
        } else {
            candidates = withoutClutter
        }

        // Burst-Bündelung aufeinanderfolgender Nicht-Video-Aufnahmen innerhalb von `burstWindowSeconds`.
        var groups: [[Asset]] = []
        for asset in candidates {
            if asset.type == .video {
                groups.append([asset])
                continue
            }
            if var lastGroup = groups.last,
               let prev = lastGroup.last,
               prev.type != .video,
               let prevDate = prev.createdDate,
               let currDate = asset.createdDate,
               abs(prevDate.timeIntervalSince(currDate)) <= burstWindowSeconds {
                lastGroup.append(asset)
                groups[groups.count - 1] = lastGroup
            } else {
                groups.append([asset])
            }
        }

        return groups.flatMap { group -> [Asset] in
            guard group.count > 1 else { return group }
            let favorites = group.filter(\.isFavorite)
            if !favorites.isEmpty { return favorites }
            var best = group[0]
            var bestScore = HighlightScorer.score(asset: best, homeLat: nil, homeLon: nil)
            for candidate in group.dropFirst() {
                let s = HighlightScorer.score(asset: candidate, homeLat: nil, homeLon: nil)
                if s > bestScore {
                    bestScore = s
                    best = candidate
                }
            }
            return [best]
        }
    }

    /// Kuratierte Assets mit den bis zu 5 stärksten Highlights (nach Bildqualität,
    /// Tie-Break zeitlich) vorn für Hero-/Bento-Mosaike, gefolgt vom restlichen Verlauf.
    func previewAssets(hideClutter: Bool = true) -> [Asset] {
        let curated = curatedAssets(hideClutter: hideClutter)
        guard curated.count > 1 else { return curated }

        let rankedTop = curated.enumerated()
            .sorted { lhs, rhs in
                let lScore = Self.coverScore(of: lhs.element)
                let rScore = Self.coverScore(of: rhs.element)
                if lScore != rScore { return lScore > rScore }
                return lhs.offset < rhs.offset
            }
            .prefix(5)
            .map(\.element)
        let topIds = Set(rankedTop.map(\.id))
        let rest = curated.filter { !topIds.contains($0.id) }
        return rankedTop + rest
    }

    /// Anzahl der Assets, die durch den Beifang- & Serienfilter in der Vorschau entfallen.
    var clutterCount: Int {
        max(0, visibleAssets.count - curatedAssets(hideClutter: true).count)
    }

    /// Kompakte Ortsangabe aus den EXIF-Daten („Lissabon & Porto", „Berlin, Deutschland").
    var locationSummary: String? {
        var cityCounts: [String: Int] = [:]
        var countryCounts: [String: Int] = [:]

        for asset in visibleAssets {
            if let city = asset.exifInfo?.city?.trimmingCharacters(in: .whitespacesAndNewlines),
               !city.isEmpty {
                cityCounts[city, default: 0] += 1
            }
            if let rawCountry = asset.exifInfo?.country?.trimmingCharacters(in: .whitespacesAndNewlines),
               !rawCountry.isEmpty {
                let localized = Laendernamen.anzeigename(fuer: rawCountry)
                countryCounts[localized, default: 0] += 1
            }
        }

        let sortedCities = cityCounts
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map(\.key)
        let sortedCountries = countryCounts
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map(\.key)

        switch sortedCities.count {
        case 1:
            if sortedCountries.count == 1 {
                return "\(sortedCities[0]), \(sortedCountries[0])"
            }
            return sortedCities[0]
        case 2:
            return "\(sortedCities[0]) & \(sortedCities[1])"
        case 3...:
            return "\(sortedCities[0]), \(sortedCities[1]) + \(sortedCities.count - 2)"
        default:
            guard !sortedCountries.isEmpty else { return nil }
            return sortedCountries.prefix(2).joined(separator: " & ")
        }
    }

    /// Erkannte, nicht ausgeblendete Personen dieser Erinnerung — benannte & häufige zuerst.
    var recognizedPeople: [Person] {
        var counts: [String: Int] = [:]
        var byId: [String: Person] = [:]

        for person in visibleAssets.flatMap({ $0.people ?? [] }) where person.isHidden != true {
            counts[person.id, default: 0] += 1
            if let existing = byId[person.id] {
                if existing.name.trimmingCharacters(in: .whitespaces).isEmpty
                    && !person.name.trimmingCharacters(in: .whitespaces).isEmpty {
                    byId[person.id] = person
                }
            } else {
                byId[person.id] = person
            }
        }

        return byId.values.sorted { lhs, rhs in
            let lhsNamed = !lhs.name.trimmingCharacters(in: .whitespaces).isEmpty
            let rhsNamed = !rhs.name.trimmingCharacters(in: .whitespaces).isEmpty
            if lhsNamed != rhsNamed { return lhsNamed }
            let lhsCount = counts[lhs.id] ?? 0
            let rhsCount = counts[rhs.id] ?? 0
            if lhsCount != rhsCount { return lhsCount > rhsCount }
            return lhs.id < rhs.id
        }
    }

    /// Statistik-Zeile für den Karten-Header („14 Fotos · 2 Videos · 3 ♥").
    var statsSummary: String {
        let items = visibleAssets
        let photoCount = items.count { $0.type == .image }
        let videoCount = items.count { $0.type == .video && !$0.istVersteckterBewegtbildAnteil }
        let favoriteCount = items.count { $0.isFavorite }

        var parts: [String] = []
        if photoCount > 0 {
            parts.append("\(photoCount) \(photoCount == 1 ? "Foto" : "Fotos")")
        }
        if videoCount > 0 {
            parts.append("\(videoCount) \(videoCount == 1 ? "Video" : "Videos")")
        }
        if favoriteCount > 0 {
            parts.append("\(favoriteCount) ♥")
        }
        return parts.isEmpty ? "\(assets.count) Elemente" : parts.joined(separator: " · ")
    }

    /// Gesamtbewertung der Karte für das Hero-Spotlight in der Magazin-Ansicht.
    /// Nutzt ausschließlich saubere (nicht auf Beifang zurückgefallene) Bilder,
    /// belohnt bekannte Orte (+6) und echte Kameraserien (≥ 3 Kamerafotos: +4).
    var highlightScore: Double {
        let clean = curatedAssets(hideClutter: true, burstWindowSeconds: 15, fallbackToAllIfEmpty: false)
        let topThree = clean
            .map { HighlightScorer.score(asset: $0, homeLat: nil, homeLon: nil) }
            .sorted(by: >)
            .prefix(3)
            .reduce(0, +)
        let locationBonus = locationSummary != nil ? 6.0 : 0.0
        let cameraCount = clean.count {
            !($0.exifInfo?.model ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        }
        let cameraBonus = cameraCount >= 3 ? 4.0 : 0.0
        let countBonus = Double(min(clean.count, 20)) * 0.2
        return topThree + locationBonus + cameraBonus + countBonus
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
