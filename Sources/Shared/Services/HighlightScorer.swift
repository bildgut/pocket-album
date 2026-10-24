import Foundation

// MARK: - HighlightScorer
//
// Pure, side-effect-free scoring engine for "Höhepunkte" (Highlights).
// All methods are static — no instance state.
//
// Scoring table (additive):
//   +10  isFavorite
//   + 5  person(s) recognised (from Asset.people — populated in detail/search contexts)
//   + 3  has GPS coordinates
//   + 2  has EXIF camera model (real camera, not a screenshot)
//   + 0…+10  distance from home (logarithmic — see distanceScore)
//   - 5  ScreenshotDetector.isScreenshot — Namensmuster in sechs Sprachen, das
//        iOS-Muster IMG_0001.png *und* die Heuristik „PNG ohne Kamerafelder".
//        Die Zeile nannte früher nur zwei Dateinamen; der Detektor ist seither
//        gewachsen, und die Heuristik trifft auch ein echtes Foto, das als PNG
//        vorliegt. Für eine Gewichtung ist das vertretbar (siehe Begründung an
//        `ScreenshotDetector.isScreenshot(_:)`), steht hier aber jetzt richtig.
//   - 3  effective width < 600 px (thumbnail remnant, burst waste, meme)

enum HighlightScorer {

    // MARK: - Public Types

    struct ScoredAsset: Identifiable, Sendable {
        let asset: Asset
        let score: Double
        var id: String { asset.id }
    }

    // MARK: - Top Highlights (entry point)

    /// Returns up to `totalLimit` highlights from `assets`, spreading no more than
    /// `perMonthLimit` picks per calendar month to avoid one holiday dominating.
    ///
    /// - Parameters:
    ///   - homeLat/homeLon: optional home coordinates for distance boost.
    ///     Pass `nil` to skip the distance signal.
    static func topHighlights(
        from assets: [Asset],
        homeLat: Double?,
        homeLon: Double?,
        perMonthLimit: Int = 3,
        totalLimit: Int = 30
    ) -> [ScoredAsset] {
        guard !assets.isEmpty else { return [] }

        // Score eligible assets, grouped by month
        var byMonth: [String: [ScoredAsset]] = [:]
        for asset in assets {
            guard !asset.isTrashed, !asset.isArchived else { continue }
            let s = score(asset: asset, homeLat: homeLat, homeLon: homeLon)
            // Require at least one positive signal before including
            guard s > 0 else { continue }
            byMonth[asset.monthKey, default: []].append(ScoredAsset(asset: asset, score: s))
        }

        // Take top N per month (temporal spreading), then global top `totalLimit`.
        //
        // Bei Punktgleichstand entscheidet die Asset-ID, nicht die Reihenfolge der
        // Eingabe: `byMonth.values` läuft über ein Dictionary, und dessen Reihenfolge
        // ist unbestimmt. Ohne den zweiten Vergleich zeigte „Höhepunkte" bei
        // unveränderter Bibliothek nach jedem Start eine andere Auswahl — sowohl
        // `prefix(perMonthLimit)` als auch `prefix(totalLimit)` schneiden ja mitten
        // in die Gleichstände hinein, und Gleichstände sind hier der Normalfall:
        // Die Punkte sind eine Summe weniger fester Beträge.
        //
        // Dieselbe Vorsorge trifft `GeoMatcher.scan` („bei gleichem Zeitstempel wäre
        // die Reihenfolge sonst von der Eingabe abhängig, und damit auch das
        // Ergebnis") und `DuplicateMatcher.scan`.
        return byMonth.values
            .flatMap { group in group.sorted(by: highlightOrder).prefix(perMonthLimit) }
            .sorted(by: highlightOrder)
            .prefix(totalLimit)
            .map { $0 }
    }

    /// Beste zuerst; die ID macht die Reihenfolge bei Gleichstand eindeutig.
    private static func highlightOrder(_ a: ScoredAsset, _ b: ScoredAsset) -> Bool {
        a.score == b.score ? a.id < b.id : a.score > b.score
    }

    // MARK: - Score a single Asset

    static func score(asset: Asset, homeLat: Double?, homeLon: Double?) -> Double {
        var s: Double = 0

        // ── Positive signals ─────────────────────────────────────────────────
        if asset.isFavorite { s += 10 }

        if let people = asset.people, !people.isEmpty { s += 5 }

        let exif    = asset.exifInfo
        let hasGPS  = exif?.latitude != nil && exif?.longitude != nil
        if hasGPS                  { s += 3 }
        if exif?.model != nil      { s += 2 }   // real camera model present

        // Distance boost from home
        if let lat = exif?.latitude,
           let lon = exif?.longitude,
           let hLat = homeLat,
           let hLon = homeLon {
            s += distanceScore(lat: lat, lon: lon, homeLat: hLat, homeLon: hLon)
        }

        // ── Negative signals ─────────────────────────────────────────────────
        if ScreenshotDetector.isScreenshot(asset) { s -= 5 }

        if let w = asset.effectiveWidth, w < 600 { s -= 3 }

        return s
    }

    // MARK: - Distance Score (logarithmic 0…10)

    /// Boost based on distance from home.
    ///
    /// Curve: `min(10, log2(km / 30 + 1) × 1.35)`
    ///
    /// |  Distance  | Score |
    /// |------------|-------|
    /// |  < 5 km    |  0.0  |  (at home, no boost)
    /// |   30 km    |  1.4  |  (day trip)
    /// |  100 km    |  2.9  |
    /// |  200 km    |  4.0  |  (domestic)
    /// |  500 km    |  5.6  |
    /// | 1000 km    |  6.9  |  (Europe)
    /// | 5000 km    | 10.0  |  (another continent; the cap bites at ≈5060 km)
    ///
    /// Die Werte oben sind gerechnet, nicht gewünscht — wer den Faktor ändert,
    /// rechnet sie bitte neu. Der Faktor stand ursprünglich auf 2.5, womit die
    /// Kurve bereits bei 450 km an die Obergrenze stieß: Paris, New York und
    /// Tokio bekamen dieselben 10 Punkte, und die Entfernung unterschied
    /// ausgerechnet dort nichts mehr, wo sie am meisten unterscheiden sollte.
    /// Mit 1.35 reicht die Spreizung bis zum Kontinentwechsel.
    static func distanceScore(
        lat: Double, lon: Double,
        homeLat: Double, homeLon: Double
    ) -> Double {
        let km = haversineKm(lat1: lat, lon1: lon, lat2: homeLat, lon2: homeLon)
        guard km > 5 else { return 0 }
        return min(10.0, log2(km / 30.0 + 1.0) * 1.35)
    }

    // MARK: - Configured & Effective Home Location

    public static let overrideLatKey = "highlight.home.overrideLat"
    public static let overrideLonKey = "highlight.home.overrideLon"

    /// Liefert die manuell in den Einstellungen gesetzte Heimatadresse, falls vorhanden.
    static func configuredHomeLocation(defaults: UserDefaults = AppEnvironment.defaults) -> (lat: Double, lon: Double)? {
        guard defaults.object(forKey: overrideLatKey) != nil,
              defaults.object(forKey: overrideLonKey) != nil else {
            return nil
        }
        let lat = defaults.double(forKey: overrideLatKey)
        let lon = defaults.double(forKey: overrideLonKey)
        guard !lat.isNaN, !lon.isNaN, lat != 0 || lon != 0 else { return nil }
        return (lat: lat, lon: lon)
    }

    /// Ermittelt den maßgeblichen Heimatort:
    /// 1. Manuell gesetzte Adresse aus den Einstellungen (höchste Priorität).
    /// 2. Zeitbasierte Auto-Erkennung (Monats-Cluster über 0,25°-Zellen).
    /// 3. Fallback auf rein koordinatenbasierte Häufigkeit.
    static func effectiveHome(
        from timedCoordinates: [(lat: Double, lon: Double, date: Date?)],
        defaults: UserDefaults = AppEnvironment.defaults
    ) -> (lat: Double, lon: Double)? {
        if let manual = configuredHomeLocation(defaults: defaults) {
            return manual
        }
        return autoDetectHome(fromTimedCoordinates: timedCoordinates)
    }

    // MARK: - Auto-detect Home Location

    /// Finds the home location based on distinct calendar months in 0.25° grid cells
    /// across a rolling 3-year window (adapted from immich-retrace).
    ///
    /// Requires at least `minDistinctMonths` (default 3) distinct months so that a single long vacation
    /// (even with thousands of photos) never outweighs the true home.
    static func autoDetectHome(
        fromTimedCoordinates items: [(lat: Double, lon: Double, date: Date?)],
        cellSize: Double = 0.25,
        minDistinctMonths: Int = 3
    ) -> (lat: Double, lon: Double)? {
        let withDates = items.compactMap { item -> (lat: Double, lon: Double, date: Date)? in
            guard let date = item.date else { return nil }
            return (item.lat, item.lon, date)
        }
        guard !withDates.isEmpty else {
            return autoDetectHome(from: items.map { ($0.lat, $0.lon) })
        }

        struct Cell: Hashable { let latIdx: Int; let lonIdx: Int }
        final class CellAccumulator {
            var sumLat: Double = 0
            var sumLon: Double = 0
            var count: Int = 0
            var months = Set<Int>() // year * 12 + month
        }

        var cells: [Cell: CellAccumulator] = [:]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current

        for (lat, lon, date) in withDates {
            let cell = Cell(
                latIdx: Int((lat / cellSize).rounded()),
                lonIdx: Int((lon / cellSize).rounded())
            )
            let acc: CellAccumulator
            if let existing = cells[cell] {
                acc = existing
            } else {
                acc = CellAccumulator()
                cells[cell] = acc
            }
            acc.sumLat += lat
            acc.sumLon += lon
            acc.count += 1

            let comps = calendar.dateComponents([.year, .month], from: date)
            if let y = comps.year, let m = comps.month {
                acc.months.insert(y * 12 + m)
            }
        }

        // Distinct months per cell and per year
        struct CellYearSummary {
            let acc: CellAccumulator
            let monthsByYear: [Int: Int] // year -> count of distinct months
        }

        var allYears = Set<Int>()
        var summaries: [CellYearSummary] = []
        for acc in cells.values {
            var byYear: [Int: Int] = [:]
            for ym in acc.months {
                let y = ym / 12
                byYear[y, default: 0] += 1
                allYears.insert(y)
            }
            summaries.append(CellYearSummary(acc: acc, monthsByYear: byYear))
        }

        var bestScore = 0
        var bestAcc: CellAccumulator?

        // Check each year with a rolling window [y-1 ... y+1]
        for year in allYears {
            for summary in summaries {
                let score = (summary.monthsByYear[year - 1] ?? 0)
                          + (summary.monthsByYear[year] ?? 0)
                          + (summary.monthsByYear[year + 1] ?? 0)
                if score > bestScore {
                    bestScore = score
                    bestAcc = summary.acc
                }
            }
        }

        if let bestAcc, bestScore >= minDistinctMonths, bestAcc.count > 0 {
            return (lat: bestAcc.sumLat / Double(bestAcc.count),
                    lon: bestAcc.sumLon / Double(bestAcc.count))
        }

        // Fallback: If not enough months to meet the threshold, use raw photo counts
        return autoDetectHome(from: items.map { ($0.lat, $0.lon) })
    }

    /// Finds the most common 0.5° lat/lon grid cell in `coordinates`.
    /// Returns the centre of that cell as `(lat, lon)`, or `nil` if no data.
    ///
    /// 0.5° ≈ 55 km — precise enough to distinguish city-level home from travels.
    static func autoDetectHome(
        from coordinates: [(lat: Double, lon: Double)]
    ) -> (lat: Double, lon: Double)? {
        guard !coordinates.isEmpty else { return nil }

        // Map every coordinate to a grid cell index
        struct Cell: Hashable { let latIdx: Int; let lonIdx: Int }
        var counts: [Cell: Int] = [:]
        for (lat, lon) in coordinates {
            let cell = Cell(
                latIdx: Int((lat / 0.5).rounded()),
                lonIdx: Int((lon / 0.5).rounded())
            )
            counts[cell, default: 0] += 1
        }

        // Bei Gleichstand die kleinere Zelle — `max` über ein Dictionary greift sonst
        // eine beliebige heraus, und deren Reihenfolge ist unbestimmt. Der Heimatort
        // fließt über `distanceScore` in **jede** Bewertung ein: Ein Wechsel zwischen
        // zwei gleich häufigen Zellen verschöbe die ganze Auswahl.
        guard let best = counts.max(by: {
            $0.value == $1.value
                ? ($0.key.latIdx, $0.key.lonIdx) > ($1.key.latIdx, $1.key.lonIdx)
                : $0.value < $1.value
        }) else { return nil }
        // Return the centre of the winning cell
        return (lat: Double(best.key.latIdx) * 0.5,
                lon: Double(best.key.lonIdx) * 0.5)
    }

    /// Convenience overload accepting `[Asset]` directly, using timed coordinates when available.
    static func autoDetectHome(from assets: [Asset]) -> (lat: Double, lon: Double)? {
        let timed = assets.compactMap { a -> (lat: Double, lon: Double, date: Date?)? in
            guard let lat = a.exifInfo?.latitude,
                  let lon = a.exifInfo?.longitude else { return nil }
            return (lat: lat, lon: lon, date: a.createdDate)
        }
        return autoDetectHome(fromTimedCoordinates: timed)
    }

    // MARK: - Haversine

    /// Great-circle distance between two points in kilometres.
    static func haversineKm(
        lat1: Double, lon1: Double,
        lat2: Double, lon2: Double
    ) -> Double {
        let R    = 6_371.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a    = sin(dLat / 2) * sin(dLat / 2)
                 + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180)
                 * sin(dLon / 2) * sin(dLon / 2)
        return R * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    // MARK: - Formatting helpers (UI use)

    /// Human-readable coordinate string, e.g. "52.50°N, 13.50°E"
    static func formatCoordinate(lat: Double, lon: Double) -> String {
        let latDir = lat >= 0 ? "N" : "S"
        let lonDir = lon >= 0 ? "E" : "W"
        return String(format: "%.2f°%@, %.2f°%@", abs(lat), latDir, abs(lon), lonDir)
    }
}
