import Foundation
import CoreGraphics
import ImageIO
import Nuke

/// Woher die Bilder kommen. Hinter einem Protokoll, damit die Tests ohne Server laufen.
protocol InfoBildBildQuelle: Sendable {
    /// 250 px für den Vorfilter — klein genug, um die ganze Mediathek zu laden.
    func thumbnail(assetId: String) async throws -> CGImage
    /// Bis 1024 px für das Modell; damit wurde gemessen.
    func vorschau(assetId: String) async throws -> CGImage
}

/// Die echte Quelle: Thumbnail und Vorschau vom Server, über den bestehenden Weg.
///
/// Bewusst **nicht** über ``AssetAnalysisImage.load(...)``, obwohl der dieselbe
/// Aufgabe für andere Modell-Anfragen löst: Er kennt nur `size: .preview`
/// (`AssetAnalysisImage.swift:55`) und kann damit das 250-px-Thumbnail für den
/// Vorfilter gar nicht liefern. Sein Vorrang fürs lokale Original hängt zudem an
/// ``AssetAnalysisImage.cachedOriginalURL(assetId:modelContext:)`` — `@MainActor`
/// und mit `ModelContext` — was in einer Schleife über die ganze Mediathek einen
/// Hauptthread-Hüpfer je Bild bedeutete, für einen Cache, der ohnehin nur bei
/// bereits heruntergeladenen Originalen greift. Der direkte Weg über
/// `thumbnailURL` bleibt hier der richtige Hebel.
struct ServerBildQuelle: InfoBildBildQuelle {

    /// Nicht der ``ImmichAPIClient`` selbst: Der ist nicht `Sendable`, dieser Typ
    /// schon (er wandert in den Hintergrundlauf des Scanners). Gebraucht werden
    /// nur der Schlüssel und die Thumbnail-URL — beides als `Sendable`-Werte.
    let apiKey: String
    let urlRechner: ThumbnailURLRechner

    init(apiClient: ImmichAPIClient, pipeline: ImagePipeline? = nil) {
        self.apiKey = apiClient.apiKey
        self.urlRechner = ThumbnailURLRechner(baseURL: apiClient.baseURL)
        self.pipeline = pipeline
    }

    /// Die authentifizierte Pipeline aus ``ConnectionManager``. Die
    /// Thumbnail-URL **ist** ihr Cache-Schlüssel (`ImageRequest(url:)` →
    /// `url.absoluteString`, dieselbe Rechnung wie in
    /// `ConnectionManager.purgeCaches`), und der 5-GB-Disk-Cache hält die
    /// meisten 250-px-Bilder ohnehin schon: Über `URLSession.shared` wurden sie
    /// alle 117 000 erneut geladen und weggeworfen, obwohl die Spezifikation mit
    /// „~1,8 GB Thumbnails (größtenteils im Cache)" rechnet. `nil` (Tests, oder
    /// noch keine Verbindung) fällt auf den direkten Weg zurück.
    var pipeline: ImagePipeline?

    func thumbnail(assetId: String) async throws -> CGImage {
        // Schreibt den Cache mit: Ein zweiter Lauf und das Raster haben etwas davon.
        try await bild(assetId: assetId, groesse: .thumbnail, maxPixel: 250, cacheSchreiben: true)
    }

    func vorschau(assetId: String) async throws -> CGImage {
        // **Nicht** in den Cache schreiben: Thumbnails und Vorschauen teilen sich
        // denselben 5-GB-`DataCache`. Die ~14 000 Vorschauen der Vorfilter-Treffer
        // (~4 GB) verdrängten sonst genau die Thumbnails, wegen derer dieser Weg
        // über die Pipeline läuft. Gelesen wird der Cache trotzdem — was die
        // Detailansicht schon geholt hat, ist geschenkt.
        try await bild(assetId: assetId, groesse: .preview, maxPixel: 1024, cacheSchreiben: false)
    }

    private func bild(assetId: String, groesse: ThumbnailSize, maxPixel: CGFloat,
                      cacheSchreiben: Bool) async throws -> CGImage {
        let url = urlRechner.url(assetId: assetId, size: groesse)
        let daten = try await daten(url: url, cacheSchreiben: cacheSchreiben)
        guard let quelle = CGImageSourceCreateWithData(daten as CFData, nil),
              let bild = CGImageSourceCreateThumbnailAtIndex(quelle, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                  kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary)
        else {
            throw URLError(.cannotDecodeContentData)
        }
        return bild
    }

    private func daten(url: URL, cacheSchreiben: Bool) async throws -> Data {
        if let pipeline {
            var optionen: ImageRequest.Options = []
            if !cacheSchreiben { optionen.insert(.disableDiskCacheWrites) }
            // `.low`: Der Hintergrundlauf darf das Nachladen sichtbarer Kacheln
            // (Standardpriorität `.normal`) nicht verdrängen.
            let anfrage = ImageRequest(url: url, priority: .low, options: optionen)
            return try await pipeline.data(for: anfrage).0
        }

        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        let (daten, antwort) = try await URLSession.shared.data(for: request, delegate: SichereWeiterleitung.shared)
        guard (antwort as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.cannotDecodeContentData)
        }
        return daten
    }
}

/// Dieselbe Rechnung wie ``ImmichAPIClient/thumbnailURL(assetId:size:)`` —
/// `edited=true` nur für bearbeitete Assets —, aber als `Sendable`-Wert.
/// Die Gleichheit mit dem Client hält `ThumbnailURLRechnerTests` fest; die URL ist
/// zugleich Nukes Cache-Schlüssel, eine Abweichung verlöre also den Cache.
struct ThumbnailURLRechner: Sendable {
    let baseURL: URL
    var editedAssets: EditedAssetsStore = .shared

    func url(assetId: String, size: ThumbnailSize) -> URL {
        var items = [URLQueryItem(name: "size", value: size.rawValue)]
        if editedAssets.contains(assetId) { items.append(URLQueryItem(name: "edited", value: "true")) }
        return baseURL.appending(path: "api/assets")
            .appending(path: "\(assetId)/thumbnail").appending(queryItems: items)
    }
}
