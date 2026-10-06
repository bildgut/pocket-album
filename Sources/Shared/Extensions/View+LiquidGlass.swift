import SwiftUI

// MARK: - Liquid Glass Extension (macOS 15+ / iOS 26+)

extension View {
    /// Applies the modern Liquid Glass effect on supported macOS 15+ devices,
    /// gracefully falling back to a standard Material blur on older versions.
    @ViewBuilder
    func glassEffectWithFallback(
        cornerRadius: CGFloat = 12,
        fallbackMaterial: Material = .ultraThinMaterial,
        interactive: Bool = false
    ) -> some View {
        if #available(macOS 15.0, *) {
            // Future macOS 15+ (equiv. to iOS 26+) API:
            // self.glassEffect(interactive ? .regular.interactive() : .regular, in: .rect(cornerRadius: cornerRadius))
            
            // As of now in the current macOS 14 SDK, we use the fallback. 
            // Once the Xcode 16 / macOS 15 SDK is active, you can uncomment the real API above.
            self.background(fallbackMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            self.background(fallbackMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}
