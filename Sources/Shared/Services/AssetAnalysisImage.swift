import Foundation
import CoreGraphics
import ImageIO
import SwiftData
import UniformTypeIdentifiers

/// Besorgt ein JPEG, das man einem Bildmodell vorlegen kann.
///
/// Zwei Quellen, in dieser Reihenfolge: das lokal gecachte Original (wird
/// **nicht** eigens heruntergeladen — wenn es da ist, ist es das bessere Bild)
/// und sonst die Server-Vorschau. Beides landet als orientiertes JPEG in
/// überschaubarer Größe, denn hochgeladen wird es Byte für Byte.
enum AssetAnalysisImage {

    struct Result: Sendable {
        let jpeg: Data
        let pixelSize: CGSize
    }

    enum Failure: LocalizedError {
        case previewUnavailable(status: Int)
        case network(String)

        var errorDescription: String? {
            switch self {
            case .previewUnavailable(let status):
                return "Die Bildvorschau konnte nicht geladen werden (HTTP \(status))."
            case .network(let detail):
                return "Die Bildvorschau konnte nicht geladen werden: \(detail)"
            }
        }
    }

    /// Lädt das Analysebild. Läuft nebenläufig; der teure Teil (Dekodieren und
    /// Skalieren) liegt in einem abgesetzten Task.
    ///
    /// - Parameter localOriginalURL: Pfad des gecachten Originals, falls bekannt.
    ///   Über ``cachedOriginalURL(assetId:modelContext:)` zu ermitteln.
    static func load(assetId: String,
                     localOriginalURL: URL?,
                     maxPixel: CGFloat,
                     apiClient: ImmichAPIClient,
                     logLabel: String) async throws -> Result {

        if let localOriginalURL {
            let local = await Task.detached(priority: .userInitiated) {
                jpeg(fromLocalFile: localOriginalURL, maxPixel: maxPixel)
            }.value
            if let local {
                AppLogger.ui.debug("\(logLabel): Analysebild aus lokalem Original (\(Int(local.pixelSize.width))×\(Int(local.pixelSize.height)))")
                return local
            }
        }

        var request = URLRequest(url: apiClient.thumbnailURL(assetId: assetId, size: .preview))
        request.setValue(apiClient.apiKey, forHTTPHeaderField: "x-api-key")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request, delegate: SichereWeiterleitung.shared)
        } catch {
            throw Failure.network(error.localizedDescription)
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            AppLogger.ui.error("\(logLabel): Vorschau nicht dekodierbar (HTTP \(status))")
            throw Failure.previewUnavailable(status: status)
        }
        return Result(jpeg: data,
                      pixelSize: CGSize(width: cg.width, height: cg.height))
    }

    /// Pfad des lokal gecachten Originals, falls vorhanden — ohne Download.
    @MainActor
    static func cachedOriginalURL(assetId: String, modelContext: ModelContext?) -> URL? {
        guard let modelContext else { return nil }
        var descriptor = FetchDescriptor<CachedAsset>(
            predicate: #Predicate { $0.assetId == assetId }
        )
        descriptor.fetchLimit = 1
        guard let cached = try? modelContext.fetch(descriptor).first,
              let relativePath = cached.localFilePath else { return nil }
        let url = LocalFileCacheManager.cacheDirectory.appending(path: relativePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Orientiertes JPEG aus einer lokalen Originaldatei (bei DNGs greift die
    /// eingebettete Vorschau).
    static func jpeg(fromLocalFile url: URL, maxPixel: CGFloat) -> Result? {
        guard let cg = decode(fromLocalFile: url, maxPixel: maxPixel),
              let data = encodeJPEG(cg) else { return nil }
        return Result(jpeg: data, pixelSize: CGSize(width: cg.width, height: cg.height))
    }

    /// Wie ``jpeg(fromLocalFile:maxPixel:)``, gibt zusätzlich das Bild selbst
    /// zurück — der Zuschnitt braucht es für die Vorschau.
    static func decodedJPEG(fromLocalFile url: URL, maxPixel: CGFloat) -> (Data, CGImage)? {
        guard let cg = decode(fromLocalFile: url, maxPixel: maxPixel),
              let data = encodeJPEG(cg) else { return nil }
        return (data, cg)
    }

    private static func decode(fromLocalFile url: URL, maxPixel: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Orientierung anwenden: Sonst zeigt das Modell auf ein Bild, das der
            // Nutzer nie zu sehen bekommt.
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// JPEG aus einem Bild, das schon im Speicher liegt — die Look-Empfehlung schickt die
    /// Editorvorschau, nicht eine Datei. Derselbe Kodierer wie für den Dateiweg, damit es
    /// im Projekt nur einen gibt.
    static func jpeg(from image: CGImage) -> Data? { encodeJPEG(image) }

    private static func encodeJPEG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(
            dest, image,
            [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary
        )
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
