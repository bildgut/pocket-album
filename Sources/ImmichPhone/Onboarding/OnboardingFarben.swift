import SwiftUI

/// Farbwerte des Onboardings, hell und dunkel. Keine Ansicht setzt eigene Farben.
struct OnboardingFarben {
    let hintergrund: Color
    let text: Color
    let nebentext: Color
    let knopf: Color
    let knopfText: Color
    let erfolg: Color
    let schein: Color
    let feld: Color

    init(_ scheme: ColorScheme) {
        if scheme == .dark {
            hintergrund = Color(red: 0.043, green: 0.043, blue: 0.051)
            text = .white
            nebentext = .white.opacity(0.65)
            knopf = .white
            knopfText = .black
            erfolg = Color(red: 0.43, green: 0.91, blue: 0.63)
            schein = Color(red: 0.43, green: 0.55, blue: 1).opacity(0.35)
            feld = .white.opacity(0.08)
        } else {
            hintergrund = Color(red: 0.98, green: 0.98, blue: 0.969)
            text = Color(white: 0.07)
            nebentext = Color(white: 0.07).opacity(0.6)
            knopf = Color(white: 0.07)
            knopfText = .white
            erfolg = Color(red: 0.13, green: 0.6, blue: 0.33)
            schein = Color(red: 0.43, green: 0.55, blue: 1).opacity(0.2)
            feld = .black.opacity(0.05)
        }
    }
}
