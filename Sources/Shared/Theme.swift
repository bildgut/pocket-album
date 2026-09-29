import SwiftUI

// MARK: - App Theme

/// Centralised accent color for the entire app.
/// Change the single `accent` value here to re-skin the app.
enum Theme {

    // ── Accent ───────────────────────────────────────────────
    // A warm gold inspired by the app icon.
    // Swap this one value to change every tinted element app-wide.

    /// SwiftUI accent color — use in `.foregroundStyle()`, `.tint()`, overlays, etc.
    static let accent = Color(hue: 0.12, saturation: 0.65, brightness: 0.92)

    /// SwiftUI favorite color — use for stars and favorite toggles.
    static let favorite = Color.yellow
}
