import Foundation

/// Was mit einer bestätigten Etappe geschehen soll.
///
/// Zwei Fälle, weil ein Vorschlag zwei sehr verschiedene Dinge bedeuten kann: Ein
/// neues Album ist ein neuer Behälter; ein Album zu ergänzen greift in bestehenden
/// Bestand ein. Beide laufen bewusst durch dieselbe Bestätigung und dasselbe
/// Rückgängig — was sich unterscheidet, ist allein, was rückgängig *heißt*.
enum TripSegmentAction: Hashable, Sendable {
    case createNew
    /// Nur die fehlenden Fotos in ein vorhandenes Album legen.
    case extendExisting(albumId: String)

    var albumId: String? {
        if case .extendExisting(let id) = self { return id }
        return nil
    }
}

/// Wie stark sich eine vorgeschlagene Etappe mit einem vorhandenen Album deckt.
///
/// Zwei Verhältnisse, und beide werden gebraucht:
///
/// - `coverageOfSegment` — wie viel des Vorschlags schon in dem Album steckt.
/// - `coverageOfAlbum` — wie viel des Albums der Vorschlag ausmacht.
///
/// Einzeln sagt keines von beiden genug. Eine Etappe kann **vollständig** in
/// „Japan 2017" enthalten sein (100 %) und trotzdem nur 4 % davon ausmachen — das
/// ist eine Etappe des Reisealbums, keine Dublette. Erst wenn beide Richtungen hoch
/// sind, beschreiben Vorschlag und Album dieselbe Sache.
struct TripAlbumOverlap: Identifiable, Equatable, Sendable {
    let album: Album
    /// Wie viele Fotos der Etappe in diesem Album liegen.
    let shared: Int
    /// Wie viele Fotos die Etappe insgesamt hat.
    let segmentCount: Int

    var id: String { album.id }

    var coverageOfSegment: Double {
        segmentCount > 0 ? Double(shared) / Double(segmentCount) : 0
    }

    var coverageOfAlbum: Double {
        album.assetCount > 0 ? Double(shared) / Double(album.assetCount) : 0
    }

    /// Fotos der Etappe, die in diesem Album noch fehlen.
    var missingCount: Int { segmentCount - shared }

    /// Die ganze Etappe liegt in diesem Album — es gibt nichts hinzuzufügen.
    ///
    /// Getrennt von `isNearDuplicate`: Das fragt, ob Vorschlag und Album *dieselbe
    /// Sache* sind, und verlangt dafür beide Richtungen. Hier zählt nur eine — eine
    /// Etappe kann vollständig in einem Reisealbum stecken, ohne dessen Dublette zu
    /// sein, und auch dann ist an ihr nichts mehr zu tun.
    var coversWholeSegment: Bool { segmentCount > 0 && shared >= segmentCount }

    var isNearDuplicate: Bool {
        coverageOfSegment >= TripAlbumOverlap.nearDuplicateThreshold
            && coverageOfAlbum >= TripAlbumOverlap.nearDuplicateThreshold
    }

    /// Ab wann Vorschlag und Album als dieselbe Sache gelten.
    ///
    /// 0,8 in **beide** Richtungen. Kein exakter Wert, sondern eine Setzung — sie
    /// entscheidet nur über die Voreinstellung, nicht über das Ergebnis: Wer ein
    /// zweites Album will, bekommt es weiterhin mit einem Klick.
    static let nearDuplicateThreshold = 0.8

    // MARK: - Berechnung

    /// - Parameter membership: `assetId → Album-IDs`, wie
    ///   `AlbumMembershipStore.albumIds(forAssets:)` es liefert. Assets ohne Album
    ///   **fehlen** dort, sie stehen nicht mit leerer Menge drin.
    /// - Returns: absteigend nach gemeinsamen Fotos; bei Gleichstand nach Name,
    ///   damit die Reihenfolge zwischen zwei Läufen nicht wechselt.
    static func compute(segmentAssetIds: [String],
                        membership: [String: Set<String>],
                        albums: [Album]) -> [TripAlbumOverlap] {
        guard !segmentAssetIds.isEmpty, !albums.isEmpty else { return [] }

        var counts: [String: Int] = [:]
        for assetId in segmentAssetIds {
            guard let albumIds = membership[assetId] else { continue }
            for albumId in albumIds { counts[albumId, default: 0] += 1 }
        }
        guard !counts.isEmpty else { return [] }

        let byId = Dictionary(albums.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        return counts.compactMap { albumId, shared -> TripAlbumOverlap? in
            // Ein Album, das der Index kennt und die Albumliste nicht, ist gerade
            // gelöscht worden. Es zu zeigen wäre schlimmer als es wegzulassen.
            guard let album = byId[albumId] else { return nil }
            return TripAlbumOverlap(album: album, shared: shared,
                                    segmentCount: segmentAssetIds.count)
        }
        .sorted {
            $0.shared == $1.shared
                ? $0.album.albumName.localizedCompare($1.album.albumName) == .orderedAscending
                : $0.shared > $1.shared
        }
    }
}
