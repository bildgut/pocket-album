import Foundation
import Observation

/// Zustand des Blatts „Offline speichern“: Anzahl, Schätzung, freier Platz, Sperre.
@Observable @MainActor
final class PhoneOfflineBlattModell {
    enum Laden: Equatable { case laedt, fertig, fehlgeschlagen }

    let album: Album
    let freierPlatz: Int64?
    var wahl: OfflineWahl
    private(set) var laden: Laden = .laedt
    private(set) var eintraege: [OfflineSchaetzung.Eintrag] = []

    init(album: Album, wahl: OfflineWahl, freierPlatz: Int64?) {
        self.album = album
        self.wahl = wahl
        self.freierPlatz = freierPlatz
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
            let assets = try await apiClient.getAlbumAssets(albumId: album.id)
            eintraege = Self.eintraege(aus: assets)
            laden = .fertig
        } catch {
            AppLogger.library.error("Offline-Blatt: Album \(self.album.id, privacy: .public) nicht gezählt: \(error.localizedDescription, privacy: .public)")
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
