import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

// MARK: - Errors

enum ImageEditingError: LocalizedError {
    case decodeFailed
    case ciFilterFailed
    case encodeFailed
    /// Beim Ersetzen konnten Favoritenstatus und Albumzugehörigkeit des Originals
    /// nicht gelesen werden.
    ///
    /// Eigener Fall, weil hier **nichts** geändert werden darf: Das Original wandert
    /// beim Ersetzen in den Papierkorb, und was vorher nicht ausgelesen wurde, lässt
    /// sich danach nicht mehr auf die bearbeitete Fassung übertragen. Sie stünde in
    /// keinem Album.
    case originalMetadataUnavailable(underlying: String)

    var errorDescription: String? {
        switch self {
        case .decodeFailed: return "Das Bild konnte nicht gelesen werden."
        case .ciFilterFailed: return "Die Bildbearbeitung ist fehlgeschlagen."
        case .encodeFailed: return "Das bearbeitete Bild konnte nicht gespeichert werden."
        case .originalMetadataUnavailable(let underlying):
            return """
                Alben und Favoritenstatus des Originals konnten nicht gelesen werden \
                (\(underlying)). Es wurde nichts geändert — sonst stünde die \
                bearbeitete Fassung in keinem Album.
                """
        }
    }
}

// MARK: - Service

/// Pure static image editing utilities — no shared state.
enum ImageEditingService {

    // MARK: Public

    /// Rotate `imageData` by `angle` degrees, preserving all original metadata (EXIF, GPS, IPTC).
    ///
    /// - Parameters:
    ///   - imageData: Raw image bytes (JPEG, HEIC, PNG…)
    ///   - angle:     Drehung in Grad, **positiv = im Uhrzeigersinn** — dieselbe
    ///                Konvention wie SwiftUIs `.rotationEffect(.degrees(_:))`, mit der
    ///                die Vorschau dreht. Sinnvoller Bereich −45…+45 zum Geradeziehen.
    ///
    ///                Hier stand einmal „positive = counter-clockwise (matches UIKit
    ///                convention)" — beides zusammen ist falsch, denn in UIKit und
    ///                SwiftUI dreht ein positiver Wert im Uhrzeigersinn. Der Encoder
    ///                rechnete tatsächlich gegen den Uhrzeigersinn und lief damit der
    ///                Vorschau entgegen: Wer den Horizont in der Vorschau gerade zog,
    ///                bekam ihn im Ergebnis um denselben Betrag in die andere Richtung
    ///                gekippt — und machte es beim Nachkorrigieren doppelt schief.
    ///   - crop:      Beschnitt als Rechteck in 0…1, relativ zum einbeschriebenen Rechteck
    ///                des Winkels. `nil` oder `CropGeometry.full` heißt: kein Beschnitt.
    /// - Returns: Encoded image in the same format as the input with original metadata merged.
    static func applyStraighten(imageData: Data, angle: Double, crop: CGRect? = nil) throws -> Data {
        // 1. Decode
        let cfData = imageData as CFData
        guard let source = CGImageSourceCreateWithData(cfData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw ImageEditingError.decodeFailed
        }

        // 1a. EXIF-Orientierung anwenden — ab hier gilt die ANGEZEIGTE Lage.
        //
        // `CGImageSourceCreateImageAtIndex` liefert die Pixel in Sensor-Lage: Ein
        // hochkant fotografiertes iPhone-Bild kommt als 8064×6048 quer heraus und wird
        // erst durch `orientation = 6` aufgerichtet. Winkel und Beschnitt wählt der
        // Nutzer aber im aufgerichteten Bild.
        //
        // Ohne dieses Aufrichten landete der Beschnitt im falschen Bildteil und die
        // Drehrichtung kippte (am 06.09.2026 an einer iPhone-16-Pro-HEIC belegt). Der
        // KI-Zuschnitt rechnete das früher mit `GeminiCropService.rawFraction` von Hand
        // heraus — diese Krücke ist damit überflüssig.
        let sourceProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let exifOrientation = (sourceProperties?[kCGImagePropertyOrientation] as? Int) ?? 1

        // 2. Detect output UTType (keep same format as input)
        let typeId = (CGImageSourceGetType(source) as String?) ?? UTType.jpeg.identifier
        let utType = UTType(typeId) ?? .jpeg

        // 3. Rotate via Core Image
        // Negativ, weil Core Image in einem y-aufwärts-System rechnet: Dort dreht ein
        // positiver Winkel gegen den Uhrzeigersinn, in der Vorschau aber mit ihm.
        let radians = CGFloat(-angle * .pi / 180.0)
        // `.oriented` richtet auf; der Ursprung wandert dabei, deshalb zurück auf (0,0)
        // normalisieren — die Beschnittrechnung unten setzt das voraus.
        let aufgerichtet = CIImage(cgImage: cgImage).oriented(forExifOrientation: Int32(exifOrientation))
        let ciImage = aufgerichtet.transformed(
            by: CGAffineTransform(translationX: -aufgerichtet.extent.minX,
                                  y: -aufgerichtet.extent.minY))
        let rotated = ciImage.transformed(by: CGAffineTransform(rotationAngle: radians))

        // 4. Einbeschriebenes Rechteck bestimmen (keine schwarzen Ecken) und darin den
        //    Nutzerbeschnitt anwenden. Die Formel dafür liegt in `CropGeometry` — dieselbe,
        //    die die Vorschau benutzt, damit Anzeige und Ergebnis nicht auseinanderlaufen.
        // Die Maße der ANGEZEIGTEN Lage — bei Orientierung 5–8 sind Breite und Höhe
        // gegenüber `cgImage.width/height` getauscht.
        let orig = ciImage.extent.size
        let isRotated = abs(angle) >= 0.01
        let hasCrop = crop != nil && crop != CropGeometry.full

        let workingImage: CIImage = isRotated ? rotated : ciImage
        let inscribed: CGRect
        if isRotated {
            let scale = CropGeometry.inscribedScale(size: orig, angleDegrees: angle)
            let ext = rotated.extent
            // Sicherheitsabstand von 0,5 px gegen Rundungsfehler, die den Rand knapp
            // außerhalb des gedrehten Inhalts platzieren und schwarze Schlieren erzeugen.
            inscribed = CGRect(
                x: ext.midX - scale * orig.width / 2,
                y: ext.midY - scale * orig.height / 2,
                width:  scale * orig.width,
                height: scale * orig.height
            ).intersection(ext.insetBy(dx: 0.5, dy: 0.5))
        } else {
            inscribed = ciImage.extent
        }

        let croppedCGImage: CGImage
        if !isRotated && !hasCrop {
            // Auch ohne Bearbeitung muss aufgerichtet werden, wenn die Orientierung
            // gleich mit auf 1 gesetzt wird — sonst läge das Bild quer und die Datei
            // behauptete, es sei schon richtig.
            if exifOrientation == 1 {
                croppedCGImage = cgImage
            } else {
                guard let cg = CIContext().createCGImage(ciImage, from: ciImage.extent) else {
                    throw ImageEditingError.ciFilterFailed
                }
                croppedCGImage = cg
            }
        } else {
            var finalRect = inscribed
            if let crop, hasCrop {
                finalRect = CropGeometry.ciRect(fraction: crop, inscribed: inscribed)
                finalRect = finalRect.intersection(inscribed)
            }
            guard !finalRect.isNull, finalRect.width > 1, finalRect.height > 1 else {
                throw ImageEditingError.ciFilterFailed
            }

            let ciContext = CIContext()
            let cropped = workingImage.cropped(to: finalRect)
            guard let cg = ciContext.createCGImage(cropped, from: finalRect) else {
                throw ImageEditingError.ciFilterFailed
            }
            croppedCGImage = cg
        }

        // 5. Encode + merge original metadata via CGImageDestination
        let outputData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            outputData,
            utType.identifier as CFString,
            1,
            nil
        ) else {
            throw ImageEditingError.encodeFailed
        }

        // Metadaten übernehmen, aber die Orientierung auf „schon richtig" setzen: Die
        // Pixel liegen jetzt in der angezeigten Lage. Bliebe das Tag des Originals
        // stehen, drehte jeder Betrachter das Ergebnis ein zweites Mal — und wer das
        // Tag ignoriert, sähe es anders als wer es liest. Genau diese Uneinigkeit
        // zwischen Immich und der Mac-App war der gemeldete Fehler.
        var props = (sourceProperties ?? [:])
        props[kCGImagePropertyOrientation] = 1
        if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            props[kCGImagePropertyTIFFDictionary] = tiff
        }
        // Die Maße des Originals würden sonst den Beschnitt überstimmen.
        props[kCGImagePropertyPixelWidth] = croppedCGImage.width
        props[kCGImagePropertyPixelHeight] = croppedCGImage.height
        CGImageDestinationAddImage(destination, croppedCGImage, props as CFDictionary)
        let destOptions: [CFString: Any] = [kCGImageDestinationMergeMetadata: true]
        CGImageDestinationSetProperties(destination, destOptions as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw ImageEditingError.encodeFailed
        }

        return outputData as Data
    }

    /// Pixelmaße der **angezeigten** Lage aus Bilddaten, ohne das Bild zu dekodieren.
    ///
    /// Wird gebraucht, um einem gerade hochgeladenen Asset seine Maße mitzugeben:
    /// Immich extrahiert sie asynchron, und bis dahin kennt die App das
    /// Seitenverhältnis nicht — Raster und Detailansicht rechneten dann mit 1×1.
    ///
    /// Bei Orientierung 5–8 sind Breite und Höhe der Datei getauscht; hier zählt, was
    /// der Betrachter sieht.
    static func pixelMasse(of imageData: Data) -> (breite: Int, hoehe: Int)? {
        guard !imageData.isEmpty,
              let quelle = CGImageSourceCreateWithData(imageData as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(quelle, 0, nil) as? [CFString: Any],
              let breite = props[kCGImagePropertyPixelWidth] as? Int,
              let hoehe = props[kCGImagePropertyPixelHeight] as? Int,
              breite > 0, hoehe > 0
        else { return nil }
        let orientierung = (props[kCGImagePropertyOrientation] as? Int) ?? 1
        return (5...8).contains(orientierung) ? (hoehe, breite) : (breite, hoehe)
    }

    // MARK: - MIME Type Helper

    static func mimeType(for data: Data) -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let typeId = CGImageSourceGetType(source) as String?
        else {
            return "image/jpeg"
        }
        return UTType(typeId)?.preferredMIMEType ?? "image/jpeg"
    }
}
