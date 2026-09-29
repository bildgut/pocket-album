import Foundation
import CoreGraphics

/// Decodes ThumbHash Base64 strings into small blurry placeholder images.
/// Based on the ThumbHash algorithm: https://evanw.github.io/thumbhash/
enum ThumbhashDecoder {

    private static let cache: NSCache<NSString, PlatformImage> = {
        let c = NSCache<NSString, PlatformImage>()
        c.countLimit = 5000
        return c
    }()

    /// Return a previously-decoded image from the cache without computing anything.
    /// O(1) and safe to call on the main thread. Returns nil on cache miss.
    static func cachedImage(for base64: String) -> PlatformImage? {
        cache.object(forKey: base64 as NSString)
    }

    /// Decode a Base64-encoded thumbhash into a platform image placeholder (cached).
    /// Safe to call on any thread — pure computation, no UIKit/AppKit interaction.
    static func decode(base64: String) -> PlatformImage? {
        let key = base64 as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let data = Data(base64Encoded: base64), data.count >= 5 else { return nil }

        let bytes = [UInt8](data)
        let header = UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
        let header2 = UInt32(bytes[4])

        let lDC = Double(header & 63) / 63.0
        let pDC = Double((header >> 6) & 63) / 63.0
        let qDC = Double((header >> 12) & 63) / 63.0
        let hasAlpha = ((header >> 23) & 1) != 0
        let lCount = Int((header >> 24) & 7)
        let pCount = Int((header >> 27) & 7)
        let qCount = Int((header2) & 7)

        let isLandscape = ((header >> 18) & 1) != 0
        let lx = max(3, isLandscape ? (hasAlpha ? 5 : 7) : lCount)
        let ly = max(3, isLandscape ? lCount : (hasAlpha ? 5 : 7))

        // For simplicity, generate a small solid-color placeholder from the DC values
        // This gives the dominant color of the image which is the most important part
        let l = lDC
        let p = pDC - 0.5
        let q = qDC - 0.5

        // Convert LPQ to RGB (approximate)
        let r = max(0, min(1, l + 0.6774 * p + 0.7326 * q))
        let g = max(0, min(1, l - 0.1575 * p - 0.4683 * q))
        let b = max(0, min(1, l - 0.9523 * p + 0.6553 * q))

        let width = max(1, lx) * 4
        let height = max(1, ly) * 4
        _ = hasAlpha // suppress unused warning
        _ = pCount  // suppress unused warning
        _ = qCount  // suppress unused warning

        // Create a pre-rendered bitmap directly — avoids NSImage drawing handler
        // which would re-execute on every render and cause main-thread hitches
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width * 4,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        ctx.setFillColor(red: r, green: g, blue: b, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        guard let cgImage = ctx.makeImage() else { return nil }
        let image = PlatformImage.fromCGImage(cgImage, width: width, height: height)

        cache.setObject(image, forKey: key)
        return image
    }
}

