import Foundation
import CoreGraphics

#if os(macOS)
import AppKit  // erlaubt: plattformweiche
/// Die Bildklasse der jeweiligen Plattform. Auf macOS ist das exakt `NSImage`,
/// deshalb ändert sich für bestehenden Mac-Code und dessen Tests nichts.
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformImage = UIImage
#endif

extension PlatformImage {

    /// Baut ein Bild aus einem fertig gerenderten `CGImage`. Punktgröße gleich
    /// Pixelgröße — die Aufrufer im Kern erzeugen bewusst kleine, unskalierte
    /// Bitmaps und wollen keine Retina-Interpretation.
    static func fromCGImage(_ cgImage: CGImage, width: Int, height: Int) -> PlatformImage {
        #if os(macOS)
        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
        #else
        return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
        #endif
    }
}
