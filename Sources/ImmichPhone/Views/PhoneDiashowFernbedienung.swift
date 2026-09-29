import SwiftUI
import UIKit

/// Das Telefon, während das Foto auf dem Fernseher steht: Albumname, kleine
/// Vorschau dessen, was drüben zu sehen ist, Zähler und die drei Knöpfe, die
/// es braucht.
///
/// **Warum eine eigene Ansicht und nicht ein paar `if` in `PhoneDiashowView`.**
/// Die beiden Zustände haben fast nichts gemeinsam: Der eine ist ein
/// randloses Vollbild ohne Schrift, der andere eine gewöhnliche
/// Bedienoberfläche mit Titeln, Abständen und dauerhaft sichtbaren Knöpfen.
/// Ineinandergeschoben wäre der Body von `PhoneDiashowView` doppelt so lang
/// und an jeder Stelle mit einer Rollenabfrage durchsetzt.
///
/// **Die Vorschau ist genau das Bild vom Fernseher** — dasselbe `UIImage`, das
/// in ``PhoneBuehne/bild`` liegt. Nichts wird dafür ein zweites Mal geladen,
/// und es kann nicht auseinanderlaufen: Was hier zu sehen ist, ist per
/// Konstruktion das, was drüben steht.
struct PhoneDiashowFernbedienung: View {

    let albumName: String
    let vorschau: UIImage?
    /// 1-basiert, wie es dasteht — die Umrechnung macht der Aufrufer.
    let position: Int
    let anzahl: Int
    let laeuft: Bool

    let zurueck: () -> Void
    let weiter: () -> Void
    let pauseUmlegen: () -> Void
    let schliessen: () -> Void

    // Immer Konstanten, nie Text-Literale (Markdown-Falle, siehe
    // `PhoneAlbumTile`). `albumName` kommt ohnehin als Variable herein.
    private static let hinweis = String(localized: "Playing on TV")
    private static let zurueckLabel = String(localized: "Previous Photo")
    private static let weiterLabel = String(localized: "Next Photo")
    private static let pauseLabel = String(localized: "Pause")
    private static let fortsetzenLabel = String(localized: "Play")
    private static let schliessenLabel = String(localized: "End Slideshow")

    private var zaehler: String { String(localized: "\(position) of \(anzahl)") }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 24) {
                kopf
                vorschaubild
                zaehlerzeile
                knopfreihe
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
        }
        .preferredColorScheme(.dark)
    }

    private var kopf: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Label {
                    Text(Self.hinweis)
                } icon: {
                    Image(systemName: "tv")
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Marke.akzent)

                Text(albumName)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
            }
            Spacer()
            Button(action: schliessen) {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .accessibilityLabel(Self.schliessenLabel)
        }
    }

    @ViewBuilder
    private var vorschaubild: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14)
                .fill(.white.opacity(0.06))
            if let vorschau {
                Image(uiImage: vorschau)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 260)
    }

    private var zaehlerzeile: some View {
        Text(zaehler)
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(.white.opacity(0.6))
    }

    private var knopfreihe: some View {
        HStack(spacing: 36) {
            knopf(symbol: "backward.fill", label: Self.zurueckLabel, gross: false, aktion: zurueck)
            knopf(
                symbol: laeuft ? "pause.fill" : "play.fill",
                label: laeuft ? Self.pauseLabel : Self.fortsetzenLabel,
                gross: true,
                aktion: pauseUmlegen
            )
            knopf(symbol: "forward.fill", label: Self.weiterLabel, gross: false, aktion: weiter)
        }
    }

    private func knopf(symbol: String, label: String, gross: Bool, aktion: @escaping () -> Void) -> some View {
        Button(action: aktion) {
            Image(systemName: symbol)
                .font(gross ? .title.weight(.semibold) : .title3.weight(.semibold))
                .foregroundStyle(Marke.akzent)
                .frame(width: gross ? 84 : 64, height: gross ? 84 : 64)
                .background(.ultraThinMaterial, in: Circle())
        }
        .accessibilityLabel(label)
    }
}
