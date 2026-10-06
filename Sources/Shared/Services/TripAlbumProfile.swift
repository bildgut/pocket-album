import Foundation

/// Was der Scan über ein vorhandenes Album weiß: wann es spielt und wo.
///
/// Gebildet aus den Zeilen, die der Etappen-Scan ohnehin geladen hat, plus der
/// Mitgliedschaft aus `AlbumMembershipStore`. Bewusst **nicht** aus
/// `Album.startDate`/`endDate`: Die Felder sind auf manchen Servern leer, und wo
/// sie gesetzt sind, stammen sie aus derselben Quelle wie unsere Zeilen — dann
/// aber ohne die Sichtbarkeitsfilter, die hier gelten.
struct TripAlbumProfile: Sendable, Equatable {
    let albumId: String
    let start: Date
    let end: Date
    /// Häufigste Landesangabe der bekannten Fotos.
    let country: String?
    /// Wie viele Fotos des Albums der Scan überhaupt kennt.
    ///
    /// Nicht `Album.assetCount`: Der zählt auch, was im Papierkorb liegt, archiviert
    /// ist oder nie nach EXIF gefragt wurde. Ein Profil aus drei bekannten von 800
    /// Fotos wäre kein Profil, sondern eine Vermutung — deshalb die Untergrenze.
    let knownCount: Int

    var spanDays: Double { end.timeIntervalSince(start) / 86_400 }

    // MARK: - Bilden

    /// So viele Fotos eines Albums muss der Scan kennen, damit sein Zeitraum zählt.
    static let minimumKnownAssets = 5

    /// - Parameter membership: `albumId → Asset-IDs`, wie
    ///   `AlbumMembershipStore.assetIds(inAlbum:)` sie je Album liefert.
    /// - Parameter rows: die Zeilen des Etappen-Scans.
    ///
    ///   Beim Aufteilen eines Albums enthalten sie nur dessen eigene Fotos. Fremde
    ///   Alben kommen dann über `minimumKnownAssets` gar nicht erst zustande — die
    ///   Erkennung schaltet sich dort also von selbst ab, statt auf drei zufällig
    ///   bekannten Fotos ein Urteil zu bauen.
    static func build(membership: [String: [String]],
                      rows: [TripScanRow]) -> [String: TripAlbumProfile] {
        guard !membership.isEmpty, !rows.isEmpty else { return [:] }

        let byId = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var profiles: [String: TripAlbumProfile] = [:]

        for (albumId, assetIds) in membership {
            var start: Date?
            var end: Date?
            var countries: [String] = []
            var known = 0

            for assetId in assetIds {
                guard let row = byId[assetId] else { continue }
                known += 1
                if start == nil || row.timestamp < start! { start = row.timestamp }
                if end == nil || row.timestamp > end! { end = row.timestamp }
                if let country = row.country { countries.append(country) }
            }

            guard known >= minimumKnownAssets, let start, let end else { continue }
            profiles[albumId] = TripAlbumProfile(
                albumId: albumId,
                start: start,
                end: end,
                country: TripSegmenter.mostCommon(countries),
                knownCount: known
            )
        }

        return profiles
    }
}

/// Ein vorhandenes Album, das den Zeitraum einer Etappe abdeckt, ohne ein einziges
/// Foto mit ihr zu teilen.
///
/// Der Fall, den die Fotoüberschneidung nicht sehen kann: Ein Reisealbum „Iran 2006"
/// mit achtzig handverlesenen Bildern liegt neben einem Vorschlag mit zweihundert
/// anderen Aufnahmen derselben Tage. Beide beschreiben dieselbe Reise, teilen aber
/// nichts — die Deckung ist null.
struct TripAlbumTimeMatch: Identifiable, Equatable, Sendable {
    let album: Album
    let profile: TripAlbumProfile

    var id: String { album.id }

    // MARK: - Erkennen

    /// Wie weit der Zeitraum eines Albums über die Etappe hinausreichen darf, ohne
    /// dass es ein Sammelalbum ist.
    ///
    /// Vier Monate: Eine Reise dauert Tage bis Wochen, ein Jahresalbum ein Jahr.
    /// Die Grenze dazwischen ist gesetzt, nicht gemessen — sie soll „Iran 2006"
    /// erfassen und „Beste Bilder 2006" nicht. Ein halbjähriger Auslandsaufenthalt
    /// fiele hier durch; das ist der bewusst in Kauf genommene Fehler.
    static let maximumAlbumSpanDays = 120.0

    /// Wie viel Spielraum der Albumzeitraum an den Rändern bekommt.
    ///
    /// Nötig, weil der Zeitraum aus den *bekannten* Fotos stammt: Liegt das erste
    /// Foto eines Reisealbums im Papierkorb, beginnt sein Zeitraum einen halben Tag
    /// zu spät, und eine Etappe am Anreisetag fiele knapp heraus.
    static let toleranceDays = 1.0

    /// - Parameter sharedAlbumIds: Alben, die schon Fotos mit der Etappe teilen. Die
    ///   stehen bereits in der Überschneidungsliste; sie hier zu wiederholen hieße,
    ///   dasselbe Album zweimal zu melden.
    /// - Parameter excludedAlbumIds: etwa das Album, das gerade aufgeteilt wird. Dass
    ///   eine Etappe in den Zeitraum ihres eigenen Quellalbums fällt, ist keine
    ///   Erkenntnis.
    static func matches(for segment: TripSegment,
                        albums: [Album],
                        profiles: [String: TripAlbumProfile],
                        sharedAlbumIds: Set<String>,
                        excludedAlbumIds: Set<String> = []) -> [TripAlbumTimeMatch] {
        guard let country = segment.country else { return [] }

        let tolerance = toleranceDays * 86_400
        return albums.compactMap { album -> TripAlbumTimeMatch? in
            guard !sharedAlbumIds.contains(album.id),
                  !excludedAlbumIds.contains(album.id),
                  let profile = profiles[album.id],
                  profile.country == country,
                  profile.spanDays <= maximumAlbumSpanDays,
                  segment.start >= profile.start.addingTimeInterval(-tolerance),
                  segment.end <= profile.end.addingTimeInterval(tolerance)
            else { return nil }
            return TripAlbumTimeMatch(album: album, profile: profile)
        }
        // Das engste Album zuerst: Es beschreibt die Reise am genauesten. Bei
        // Gleichstand der Name, damit die Reihenfolge zwischen zwei Läufen steht.
        .sorted {
            $0.profile.spanDays == $1.profile.spanDays
                ? $0.album.albumName.localizedCompare($1.album.albumName) == .orderedAscending
                : $0.profile.spanDays < $1.profile.spanDays
        }
    }
}
