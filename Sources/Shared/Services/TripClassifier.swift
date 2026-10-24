import Foundation

/// Klassifiziert Alben und Zeiträume als Urlaube/Reisen („Trips"),
/// basierend auf dem bewährten Heuristik-Modell von immich-retrace.
///
/// Reine, abhängigkeitsfreie Logik (ohne UI, SwiftData oder Netzwerk).
public enum TripClassifier {

    public static let maxTripDays: Double = 45
    public static let minTripPhotos: Int = 10
    public static let tripPointsThreshold: Int = 2
    public static let awayDistanceKm: Double = 100

    // MARK: - Verdict

    public struct TripVerdict: Sendable, Equatable {
        public let isTrip: Bool
        public let points: Int
        public let away: AwayScore?
        public let libraryShare: Double?
        public let matchedPlace: String?
        public let isBareName: Bool

        public struct AwayScore: Sendable, Equatable {
            public let farDays: Int
            public let totalGpsDays: Int
            public var ratio: Double {
                totalGpsDays > 0 ? Double(farDays) / Double(totalGpsDays) : 0
            }

            public init(farDays: Int, totalGpsDays: Int) {
                self.farDays = farDays
                self.totalGpsDays = totalGpsDays
            }
        }

        public init(
            isTrip: Bool,
            points: Int,
            away: AwayScore?,
            libraryShare: Double?,
            matchedPlace: String?,
            isBareName: Bool
        ) {
            self.isTrip = isTrip
            self.points = points
            self.away = away
            self.libraryShare = libraryShare
            self.matchedPlace = matchedPlace
            self.isBareName = isBareName
        }
    }

    // MARK: - Kandidaten-Check

    /// Prüft, ob ein Album oder Zeitraum überhaupt als Reisekandidat in Frage kommt.
    public static func isCandidate(startDate: Date?, endDate: Date?, photoCount: Int, albumName: String? = nil) -> Bool {
        if let albumName, albumName.hasPrefix("✦ ") || albumName.hasPrefix("✦") {
            return false
        }
        guard let startDate, let endDate, photoCount >= minTripPhotos else { return false }
        let durationDays = endDate.timeIntervalSince(startDate) / 86_400
        guard durationDays >= 0, durationDays <= maxTripDays else { return false }
        return true
    }

    // MARK: - Klassifikation

    /// Bewertet einen Kandidaten anhand von Entfernung zum Heimatort, Mediatheksanteil und Ortsnamen.
    ///
    /// - Parameters:
    ///   - albumName: Name des Albums (falls vorhanden).
    ///   - albumPhotoCount: Anzahl Fotos im Album/Kandidaten.
    ///   - totalLibraryPhotosInSpan: Anzahl aller Fotos in der Mediathek in demselben Zeitraum.
    ///   - photosInSpan: GPS-Koordinaten, Daten und GeoNames-Ortsangaben der Fotos im Zeitraum.
    ///   - home: Koordinaten des Heimatorts (manuell konfiguriert oder auto-erkannt).
    public static func judge(
        albumName: String,
        albumPhotoCount: Int,
        totalLibraryPhotosInSpan: Int,
        photosInSpan: [(lat: Double?, lon: Double?, date: Date, city: String?, country: String?)],
        home: (lat: Double, lon: Double)?
    ) -> TripVerdict {
        if albumName.hasPrefix("✦ ") || albumName.hasPrefix("✦") {
            return TripVerdict(
                isTrip: false,
                points: -99,
                away: nil,
                libraryShare: nil,
                matchedPlace: nil,
                isBareName: true
            )
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current

        // 1. Away-Faktor: Tage mit GPS, die >= awayDistanceKm von Home entfernt sind
        var daysWithGps = Set<Int>() // day index
        var daysFarAway = Set<Int>()
        var knownPlaces = Set<String>()

        for photo in photosInSpan {
            if let c = photo.city, !c.isEmpty { knownPlaces.insert(c) }
            if let co = photo.country, !co.isEmpty { knownPlaces.insert(co) }

            guard let lat = photo.lat, let lon = photo.lon, let home else { continue }
            let dayIndex = calendar.ordinality(of: .day, in: .era, for: photo.date) ?? 0
            daysWithGps.insert(dayIndex)

            let dist = HighlightScorer.haversineKm(lat1: home.lat, lon1: home.lon, lat2: lat, lon2: lon)
            if dist >= awayDistanceKm {
                daysFarAway.insert(dayIndex)
            }
        }

        var points = 0
        var awayScore: TripVerdict.AwayScore? = nil

        if !daysWithGps.isEmpty, home != nil {
            let away = TripVerdict.AwayScore(farDays: daysFarAway.count, totalGpsDays: daysWithGps.count)
            awayScore = away
            let f = away.ratio
            if f >= 0.75 {
                points += 2
            } else if f >= 0.40 {
                points += 1
            } else {
                points -= 3 // Überwiegend zuhause -> Punktabzug!
            }
        }

        // 2. Mediatheksanteil (Share)
        var share: Double? = nil
        if totalLibraryPhotosInSpan > 0 {
            let s = min(1.0, Double(albumPhotoCount) / Double(totalLibraryPhotosInSpan))
            share = s
            if s >= 0.60 {
                points += 1
            } else if s < 0.10 {
                points -= 1
            }
        }

        // 3. Name Match
        let matchedPlace = findMatchingPlace(name: albumName, places: knownPlaces)
        let isBare = (matchedPlace == nil) && isBareWord(albumName)

        if matchedPlace != nil {
            points += 1
        } else if isBare {
            points -= 1
        }

        let isTrip = points >= tripPointsThreshold
        return TripVerdict(
            isTrip: isTrip,
            points: points,
            away: awayScore,
            libraryShare: share,
            matchedPlace: matchedPlace,
            isBareName: isBare
        )
    }

    // MARK: - Hilfsfunktionen

    /// Prüft, ob ein Wort des Albumnamens mit einem der besuchten Orte übereinstimmt.
    public static func findMatchingPlace(name: String, places: Set<String>) -> String? {
        let nameWords = words(name)
        guard !nameWords.isEmpty else { return nil }

        for place in places {
            let placeWords = words(place)
            for pw in placeWords {
                for nw in nameWords {
                    if isSameWordOrPrefix(nw, pw) {
                        return place
                    }
                }
            }
        }
        return nil
    }

    /// Zerlegt Text in normalisierte Wörter (mindestens 3 Buchstaben).
    public static func words(_ text: String) -> [String] {
        let cleaned = text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
        let parts = cleaned.components(separatedBy: CharacterSet.letters.inverted)
        return parts.filter { $0.count >= 3 }
    }

    /// Prüft, ob zwei Wörter identisch sind oder ab 4 Buchstaben ein Präfix des anderen sind.
    public static func isSameWordOrPrefix(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        if min(a.count, b.count) >= 4 && (a.hasPrefix(b) || b.hasPrefix(a)) {
            return true
        }
        return false
    }

    /// Ein einzelnes Wort ohne Zahlen oder Sonderzeichen (z. B. "Anna", "Fotos").
    public static func isBareWord(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return !trimmed.contains(" ") && trimmed.allSatisfy { $0.isLetter }
    }
}
