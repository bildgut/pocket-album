import Foundation
import CoreGraphics
import ImageIO
import Nuke
import os

/// Dekodiert Raster-Thumbnails auf Nukes Hintergrund-Queue zu einer fertigen
/// Bitmap, statt das Dekodieren Core Animation zu überlassen.
///
/// **Befund (Messlauf `scroll`, 19.09.2026):** Nukes Standard-Decoder liefert auf
/// macOS ein `NSImage`, das ImageIO erst beim Zeichnen dekodiert — im Commit von
/// Core Animation, also auf dem Hauptthread (`NSImage CA_prepareRenderValue` →
/// `WebPReadPlugin::decodeImageImp`) — und danach per ColorSync ins Display-Profil
/// umgerechnet. Zusammen 2,1 s von 7,6 s Hauptthread-Arbeit in 20 s Scrollen; mit
/// diesem Decoder 28 ms, Hauptthread gesamt −22 %, Ruckler −16 % (je 3 Läufe,
/// Tabelle in PERFORMANCE.md).
///
/// **Warum nicht `isDecompressionEnabled = true`:** Der Schalter wirkt auf macOS
/// nicht. Nuke markiert ein Bild nur außerhalb von macOS als dekompressionsbedürftig
/// (`#if !os(macOS)` in `ImageDecoding.decode`), ohne Markierung überspringt die
/// Pipeline die Dekompression — der Schalter bliebe folgenlos.
///
/// **Warum nur Thumbnails und nur WebP:** Dieselbe Pipeline lädt die Vorschauen der
/// Einzelansicht, und die zeigt sie mit `.allowedDynamicRange(.high)` — ein Umweg
/// über einen 8-Bit-Kontext schnitte Gain-Map-HDR ab. Die Raster-Thumbnails erzeugt
/// der Server als SDR-WebP; bei einem anderen Format (Server-Einstellung JPEG)
/// bleibt alles beim Standard-Decoder, auch weil JPEG Gain-Maps tragen kann.
///
/// Der Cache-Schlüssel ändert sich nicht (anders als bei einem `ImageProcessor`):
/// `invalidateAssetCaches` räumt weiter dieselben Einträge.
struct ThumbnailVorDekodierer: ImageDecoding {

    /// Farbraum des Bildschirms, auf dem das Raster liegt — gesetzt von der
    /// Mac-Seite (`ThumbnailFarbraum`), gelesen auf Nukes Dekodier-Queue.
    ///
    /// **Der eigentliche Hebel.** Allein das Dekodieren im Hintergrund senkte die
    /// Bildarbeit auf dem Hauptthread nur von 2,1 auf 0,7 s: Den Rest verbrachte
    /// Core Animation damit, jede Kachel per ColorSync in den Farbraum des Displays
    /// umzurechnen (`CGColorTransformConvertUsingCMSConverter` in
    /// `create_image_by_rendering`). Generisches Display P3 traf ihn nicht — das
    /// wurde sogar teurer (1,5 s); es muss das Profil des Bildschirms selbst sein.
    ///
    /// Ohne Wert (Tests, iOS) bleibt der Farbraum der Quelle.
    static var zielFarbraum: CGColorSpace? {
        get { farbraumSperre.withLock { $0 } }
        set { farbraumSperre.withLock { $0 = newValue } }
    }
    private static let farbraumSperre = OSAllocatedUnfairLock<CGColorSpace?>(uncheckedState: nil)

    /// Ob eine Antwort hierher gehört: Raster-Thumbnail (`size=thumbnail`) im
    /// WebP-Format.
    static func passt(url: URL?, data: Data) -> Bool {
        guard let url,
              let teile = URLComponents(url: url, resolvingAgainstBaseURL: false),
              teile.queryItems?.contains(where: { $0.name == "size" && $0.value == "thumbnail" }) == true
        else { return false }
        return Nuke.AssetType(data) == .webp
    }

    /// Nukes Decoder-Fabrik mit dieser Ausnahme; alles andere wie bisher.
    static func fabrik(_ kontext: ImageDecodingContext) -> (any ImageDecoding)? {
        if kontext.isCompleted, passt(url: kontext.request.url, data: kontext.data) {
            return ThumbnailVorDekodierer()
        }
        return ImageDecoderRegistry.shared.decoder(for: kontext)
    }

    func decode(_ data: Data) throws -> ImageContainer {
        guard let bitmap = Self.bitmap(aus: data) else { throw ImageDecodingError.unknown }
        return ImageContainer(
            image: PlatformImage.fromCGImage(bitmap, width: bitmap.width, height: bitmap.height),
            type: Nuke.AssetType(data)
        )
    }

    /// Dekodiert `data` und zeichnet das Ergebnis in einen eigenen Bitmap-Kontext.
    ///
    /// Das Zeichnen ist der eigentliche Zweck: Ein aus ImageIO kommendes `CGImage`
    /// ist verzögert und würde beim ersten Zeichnen erneut dekodiert. Das Ergebnis
    /// von `makeImage()` trägt dagegen fertige Pixel.
    static func bitmap(aus data: Data) -> CGImage? {
        let optionen = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let quelle = CGImageSourceCreateWithData(data as CFData, optionen),
              let roh = CGImageSourceCreateImageAtIndex(quelle, 0, optionen)
        else { return nil }
        let breite = roh.width, hoehe = roh.height
        guard breite > 0, hoehe > 0 else { return nil }

        // BGRA (32 Bit little-endian, Alpha vorn) ist das Format, das Core Animation
        // unverändert übernimmt. Mit RGBA (`…Last`, Nukes Wahl) sank die Dekodierung
        // auf dem Hauptthread zwar von 2,1 s auf 0,74 s, doch der Rest war Core
        // Animation, das jede Kachel per vImage in sein Format umzeichnete
        // (`create_image_by_rendering`) — Messlauf `scroll` vom 19.09.2026.
        let alpha: CGImageAlphaInfo = switch roh.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: .noneSkipFirst
        default: .premultipliedFirst
        }
        let bitmapInfo = alpha.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        // Graustufen- und andere Nicht-RGB-Räume nimmt ein 8-Bit-RGBA-Kontext nicht
        // an — dann sRGB, wie Nuke es in derselben Lage tut.
        let farbraum = [zielFarbraum, roh.colorSpace]
            .compactMap { $0 }
            .first { $0.model == .rgb }
            ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let kontext = CGContext(
            data: nil, width: breite, height: hoehe, bitsPerComponent: 8, bytesPerRow: 0,
            space: farbraum, bitmapInfo: bitmapInfo
        ) else { return nil }
        kontext.interpolationQuality = .none
        kontext.draw(roh, in: CGRect(x: 0, y: 0, width: breite, height: hoehe))
        return kontext.makeImage()
    }
}
