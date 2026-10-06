import SwiftUI

/// Das App-Symbol als Vektor in SwiftUI — dieselben Formen wie
/// `Resources/PocketAlbum.icon` (1024er Raster), für Stellen in der App, an denen
/// das System-Symbol nicht greifbar ist (Einführung). Ohne Glaseffekt: den setzt
/// iOS nur auf dem Home-Bildschirm.
struct PocketAlbumSymbol: View {
    var groesse: CGFloat = 64

    var body: some View {
        Canvas { kontext, flaeche in
            let s = flaeche.width / 1024
            func dreh(_ k: inout GraphicsContext, _ grad: Double, um p: CGPoint) {
                k.translateBy(x: p.x, y: p.y)
                k.rotate(by: .degrees(grad))
                k.translateBy(x: -p.x, y: -p.y)
            }
            func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
                CGRect(x: x * s, y: y * s, width: w * s, height: h * s)
            }
            // Hintergrund: Pfirsich → Koralle, diagonal
            kontext.fill(Path(CGRect(origin: .zero, size: flaeche)), with: .linearGradient(
                Gradient(colors: [Marke.pfirsich, Marke.koralle]),
                startPoint: .zero, endPoint: CGPoint(x: flaeche.width, y: flaeche.height)))
            // Gelber Abzug
            var gelb = kontext
            dreh(&gelb, -14, um: CGPoint(x: 435 * s, y: 365 * s))
            gelb.fill(Path(roundedRect: r(300, 200, 270, 330), cornerRadius: 28 * s), with: .color(Marke.sonne))
            gelb.fill(Path(roundedRect: r(330, 236, 210, 190), cornerRadius: 14 * s), with: .color(Color(red: 1, green: 0.549, blue: 0.259)))
            // Türkiser Abzug
            var tuerkis = kontext
            dreh(&tuerkis, 11, um: CGPoint(x: 605 * s, y: 355 * s))
            tuerkis.fill(Path(roundedRect: r(470, 190, 270, 330), cornerRadius: 28 * s), with: .color(Marke.tuerkis))
            tuerkis.fill(Path(ellipseIn: r(594, 244, 92, 92)), with: .color(.white.opacity(0.85)))
            // Tasche
            var tasche = Path()
            tasche.move(to: CGPoint(x: 232 * s, y: 450 * s))
            tasche.addLine(to: CGPoint(x: 792 * s, y: 450 * s))
            tasche.addLine(to: CGPoint(x: 792 * s, y: 640 * s))
            tasche.addCurve(to: CGPoint(x: 512 * s, y: 840 * s),
                            control1: CGPoint(x: 792 * s, y: 780 * s), control2: CGPoint(x: 672 * s, y: 840 * s))
            tasche.addCurve(to: CGPoint(x: 232 * s, y: 640 * s),
                            control1: CGPoint(x: 352 * s, y: 840 * s), control2: CGPoint(x: 232 * s, y: 780 * s))
            tasche.closeSubpath()
            kontext.fill(tasche, with: .color(Marke.jeans))
            kontext.fill(Path(r(232, 450, 560, 70)), with: .color(Color(red: 0.165, green: 0.333, blue: 0.878)))
            // Naht
            var naht = Path()
            naht.move(to: CGPoint(x: 280 * s, y: 590 * s))
            naht.addLine(to: CGPoint(x: 744 * s, y: 590 * s))
            kontext.stroke(naht, with: .color(Marke.sonne),
                           style: StrokeStyle(lineWidth: 24 * s, lineCap: .round, dash: [44 * s, 34 * s]))
        }
        .frame(width: groesse, height: groesse)
        .clipShape(.rect(cornerRadius: groesse * 0.225, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// „Pocket Album“ in SF Rounded Heavy, „Album“ in Koralle; darunter „for Immich“.
struct PocketAlbumSchriftzug: View {
    var groesse: CGFloat = 30
    var mitUnterzeile = true
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: groesse * 0.12) {
            Text(Self.markenname)
                .font(.system(size: groesse, weight: .heavy, design: .rounded))
                .kerning(-groesse * 0.02)
            if mitUnterzeile {
                Text(OnboardingTexts.zeigenMarke)
                    .font(.system(size: groesse * 0.42, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Ein `AttributedString` statt `Text + Text` (seit iOS 26 veraltet) — und
    /// statt Textinterpolation, die einen übersetzbaren Schlüssel „%@%@“ im
    /// Katalog erzeugte. Der Markenname wird nicht übersetzt.
    private static var markenname: AttributedString {
        var name = AttributedString("Pocket ")
        var album = AttributedString("Album")
        album.foregroundColor = Marke.akzent
        name.append(album)
        return name
    }
}
