import Foundation
import Observation

/// Zustand des Blatts „Offline speichern“: Anzahl, Schätzung, freier Platz, Sperre.
@Observable @MainActor
final class PhoneOfflineBlattModell {
    enum Laden: Equatable { case laedt, fertig, fehlgeschlagen }

    /// Titel des Blatts (Album-, Personenname, „Favoriten“).
    let titel: String
    let freierPlatz: Int64?
    /// Was ohne Zählung bekannt ist (Album: `assetCount`) — für den Fehlerfall.
    let bekannteAnzahl: Int?
    /// Holt die Assets zum Zählen — beim Album die Albumliste, bei Favoriten und
    /// Personen die Suche der Quelle.
    private let zaehle: @MainActor (ImmichAPIClient) async throws -> [Asset]
    private let kennung: String
    var wahl: OfflineWahl
    private(set) var laden: Laden = .laedt
    private(set) var eintraege: [OfflineSchaetzung.Eintrag] = []

    init(titel: String, kennung: String, bekannteAnzahl: Int? = nil, wahl: OfflineWahl, freierPlatz: Int64?,
         zaehle: @escaping @MainActor (ImmichAPIClient) async throws -> [Asset]) {
        self.titel = titel
        self.kennung = kennung
        self.bekannteAnzahl = bekannteAnzahl
        self.wahl = wahl
        self.freierPlatz = freierPlatz
        self.zaehle = zaehle
    }

    convenience init(album: Album, wahl: OfflineWahl, freierPlatz: Int64?) {
        let albumId = album.id
        self.init(titel: album.albumName, kennung: "album:\(albumId)", bekannteAnzahl: album.assetCount, wahl: wahl, freierPlatz: freierPlatz) {
            try await $0.getAlbumAssets(albumId: albumId)
        }
    }

    /// Für Favoriten und Personen: alle Treffer der Suche der Quelle.
    convenience init(quelle kind: OfflinePinKind, targetId: String, titel: String, wahl: OfflineWahl, freierPlatz: Int64?) {
        let filter = OfflineQuellenFilter.filter(kind: kind, targetId: targetId)
        self.init(titel: titel, kennung: OfflinePin.pinId(kind: kind, targetId: targetId), wahl: wahl, freierPlatz: freierPlatz) { client in
            guard let filter else { return [] }
            var alle: [Asset] = []
            var cursor: String?
            for _ in 0..<ZuletztOffline.maxSeiten {
                let seite = try await client.searchAssets(query: AssetSearchQuery(filter: filter, cursor: cursor, size: 1000, withExif: true))
                alle += seite.items ?? []
                guard let weiter = seite.nextCursor, !weiter.isEmpty else { break }
                cursor = weiter
            }
            return alle
        }
    }

    var anzahlFotos: Int { eintraege.filter { !$0.istVideo }.count }
    var anzahlVideos: Int { eintraege.filter(\.istVideo).count }

    var schaetzung: Int64? {
        laden == .fertig ? OfflineSchaetzung.bytes(eintraege, wahl: wahl) : nil
    }

    /// Ohne Schätzung (lädt noch, Fehler) nicht gesperrt — der Knopf soll nicht an
    /// einer Zählung hängen, die offline nie fertig wird.
    var passt: Bool {
        schaetzung.map { OfflineSchaetzung.passt(bytes: $0, frei: freierPlatz) } ?? true
    }

    func lade(apiClient: ImmichAPIClient) async {
        do {
            let assets = try await zaehle(apiClient)
            eintraege = Self.eintraege(aus: assets)
            laden = .fertig
        } catch {
            AppLogger.library.error("Offline-Blatt: \(self.kennung, privacy: .public) nicht gezählt: \(error.localizedDescription, privacy: .public)")
            laden = .fehlgeschlagen
        }
    }

    nonisolated static func eintraege(aus assets: [Asset]) -> [OfflineSchaetzung.Eintrag] {
        assets.map {
            OfflineSchaetzung.Eintrag(
                istVideo: $0.type == .video,
                bytes: $0.exifInfo?.fileSizeInByte.map(Int64.init),
                sekunden: VideoDuration.sekunden($0.duration)
            )
        }
    }

    /// Freier Platz, wie iOS ihn für „wichtige“ Daten zählt (einschließlich dessen,
    /// was das System bei Bedarf räumen würde).
    nonisolated static func freierPlatz() -> Int64? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        return (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }
}
