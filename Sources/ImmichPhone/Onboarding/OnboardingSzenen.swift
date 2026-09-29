import SwiftUI

/// Gezeichnete Szenen statt Fotos: Beim ersten Start gibt es noch keine eigenen,
/// und mitgelieferte Fotos brächten Lizenzfragen und Speicher mit.
enum OnboardingSzene: CaseIterable {
    case sonnenuntergang, berge, portraet, stadt, strand, wald

    /// Himmel oben/unten je Farbstellung.
    func himmel(_ stellung: Int) -> [Color] {
        // Farbstellungen aus der Markenpalette (Koralle, Pfirsich, Sonne, Türkis,
        // Jeans) — Einführung und App-Symbol sollen wie aus einem Guss wirken.
        let paare: [[UInt32]] = switch self {
        case .sonnenuntergang: [[0xFF7A59, 0xFF3D77], [0xFFD23F, 0xFF7A59], [0x2EC4B6, 0x1D3FBB]]
        case .berge: [[0x8FE3DA, 0xEAFBF8], [0xFFE58A, 0xFFF6D6], [0xFFB3C7, 0xFFE9EF]]
        case .portraet: [[0xFFB199, 0xFF7A59], [0x8FE3DA, 0x2EC4B6], [0xFFE58A, 0xFFD23F]]
        case .stadt: [[0x1D3FBB, 0x7B5CFF], [0x3A1E5A, 0xFF3D77], [0x0F2A3A, 0x2EC4B6]]
        case .strand: [[0x8FE3DA, 0xFFE58A], [0xFFB199, 0xFFE58A], [0xB8C6FF, 0xFFE9EF]]
        case .wald: [[0xBDF0E8, 0x2EC4B6], [0xFFE58A, 0xE0A800], [0xB8C6FF, 0x1D3FBB]]
        }
        return paare[stellung % paare.count].map { Color(hex: $0) }
    }
}

struct OnboardingSzenenKachel: View {
    let szene: OnboardingSzene
    let stellung: Int

    init(_ szene: OnboardingSzene, stellung: Int = 0) {
        self.szene = szene
        self.stellung = stellung
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                LinearGradient(colors: szene.himmel(stellung), startPoint: .top, endPoint: .bottom)
                motiv(w: w, h: h)
            }
        }
        .clipped()
        .accessibilityHidden(true)
    }

    @ViewBuilder private func motiv(w: CGFloat, h: CGFloat) -> some View {
        switch szene {
        case .sonnenuntergang:
            Circle().fill(Color(hex: 0xFFF3C4)).frame(width: w * 0.34)
                .shadow(color: Color(hex: 0xFFE7A0), radius: 10)
                .position(x: w / 2, y: h * 0.45)
            Rectangle()
                .fill(LinearGradient(colors: [Color(hex: 0x7A3B6B), Color(hex: 0x3B2150)], startPoint: .top, endPoint: .bottom))
                .frame(height: h * 0.33).position(x: w / 2, y: h * 0.835)
        case .berge:
            Dreieck(spitze: 0.45).fill(Color(hex: 0x4F6D8F))
                .frame(width: w, height: h * 0.66).position(x: w * 0.35, y: h * 0.67)
            Dreieck(spitze: 0.55).fill(Color(hex: 0x36506E))
                .frame(width: w * 0.95, height: h * 0.56).position(x: w * 0.8, y: h * 0.72)
            Dreieck(spitze: 0.5).fill(.white)
                .frame(width: w * 0.18, height: h * 0.13).position(x: w * 0.3, y: h * 0.4)
        case .portraet:
            Circle().fill(Color(hex: 0x5A3A2E)).frame(width: w * 0.3).position(x: w / 2, y: h * 0.4)
            UnevenRoundedRectangle(topLeadingRadius: w * 0.33, topTrailingRadius: w * 0.33)
                .fill(Color(hex: 0x5A3A2E)).frame(width: w * 0.66, height: h * 0.46)
                .position(x: w / 2, y: h * 0.77)
        case .stadt:
            Circle().fill(Color(hex: 0xFFF6D5)).frame(width: w * 0.15)
                .shadow(color: Color(hex: 0xFFF6D5), radius: 6).position(x: w * 0.8, y: h * 0.22)
            ForEach(Array(Self.haeuser.enumerated()), id: \.offset) { _, t in
                Rectangle().fill(Color(hex: 0x0F1330))
                    .frame(width: w * t.breite, height: h * t.hoehe)
                    .position(x: w * t.x, y: h - h * t.hoehe / 2)
            }
        case .strand:
            Rectangle().fill(Color(hex: 0x3AA0C8)).frame(height: h * 0.23).position(x: w / 2, y: h * 0.57)
            Rectangle().fill(Color(hex: 0x6B4A2E)).frame(width: 2, height: h * 0.2).position(x: w * 0.36, y: h * 0.9)
            UnevenRoundedRectangle(topLeadingRadius: w * 0.19, topTrailingRadius: w * 0.19)
                .fill(Color(hex: 0xE0567A)).frame(width: w * 0.38, height: h * 0.18)
                .position(x: w * 0.36, y: h * 0.74)
        case .wald:
            ForEach(Array(Self.baeume.enumerated()), id: \.offset) { _, t in
                Dreieck(spitze: 0.5).fill(Color(hex: 0x2C5A3A))
                    .frame(width: w * 0.26, height: h * t.hoehe)
                    .position(x: w * t.x, y: h - h * t.hoehe / 2)
            }
        }
    }

    private static let haeuser: [(x: CGFloat, hoehe: CGFloat, breite: CGFloat)] = [
        (0.12, 0.5, 0.18), (0.32, 0.7, 0.15), (0.52, 0.4, 0.2), (0.76, 0.6, 0.16),
    ]
    private static let baeume: [(x: CGFloat, hoehe: CGFloat)] = [
        (0.14, 0.45), (0.34, 0.64), (0.58, 0.56), (0.8, 0.43),
    ]
}

private struct Dreieck: Shape {
    let spitze: CGFloat
    func path(in r: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: r.minX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX + r.width * spitze, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.closeSubpath()
        }
    }
}

fileprivate extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}
