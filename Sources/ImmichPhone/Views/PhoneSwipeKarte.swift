import ImageIO
import NukeUI
import SwiftData
import SwiftUI
import UIKit

/// Eine einzelne wisch- und zoombare Karte im 30-Tage-Swipe-Deck.
struct PhoneSwipeKarte: View {
    let karte: PhoneSwipeKarteEintrag
    let modus: PhoneSwipeModus
    let istObersteKarte: Bool
    let onEntscheidung: (PhoneSwipeEntscheidung) -> Void

    @Environment(ConnectionManager.self) private var connection
    @Environment(\.modelContext) private var modelContext

    @State private var dragOffset: CGSize = .zero
    @State private var entscheidungAbgeschickt = false
    @State private var localImage: UIImage?
    @State private var pruefungAbgeschlossen = false
    @GestureState private var kneifSkalierung: CGFloat = 1.0

    private static let schwellenAbstand: CGFloat = 110
    private static let vorhersageSchwelle: CGFloat = 160
    private static let stempelSchwelle: CGFloat = 35
    private static let maxKantenlaenge: CGFloat = 2400

    private var stempelFortschritt: Double {
        let abstand = abs(dragOffset.width)
        guard abstand > Self.stempelSchwelle else { return 0 }
        return min(1, Double((abstand - Self.stempelSchwelle) / (Self.schwellenAbstand - Self.stempelSchwelle)))
    }

    private var datumAnzeige: String {
        PhotoFeedGrouping.titel(fuerTagesschluessel: karte.tagesSchluessel, sprache: .current)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(white: 0.09))

            bildflaeche
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

            VStack {
                stempelZeile
                Spacer()
                fusszeile
            }
            .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .scaleEffect(max(1.0, min(4.0, kneifSkalierung)))
        .offset(x: istObersteKarte ? dragOffset.width : 0, y: istObersteKarte ? dragOffset.height * 0.25 : 0)
        .rotationEffect(.degrees(istObersteKarte ? Double(dragOffset.width / 22) : 0))
        .simultaneousGesture(
            MagnifyGesture()
                .updating($kneifSkalierung) { value, state, _ in
                    state = value.magnification
                }
        )
        .gesture(wischGeste, isEnabled: istObersteKarte && !entscheidungAbgeschickt)
        .onChange(of: istObersteKarte) { _, oben in
            if oben {
                dragOffset = .zero
                entscheidungAbgeschickt = false
            }
        }
        .task(id: karte.id) {
            await ladeLokaleDateiFallsVorhanden()
        }
    }

    @ViewBuilder
    private var bildflaeche: some View {
        if let localImage {
            Image(uiImage: localImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if pruefungAbgeschlossen {
            LazyImage(url: connection.apiClient?.thumbnailURL(assetId: karte.id, size: .preview)) { state in
                if let image = state.image {
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else if state.error != nil {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                        .foregroundStyle(.white.opacity(0.6))
                } else {
                    ProgressView().tint(.white)
                }
            }
            .pipeline(connection.imagePipeline ?? .shared)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView()
                .tint(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var stempelZeile: some View {
        HStack {
            if dragOffset.width > Self.stempelSchwelle {
                stempelSchild(
                    text: modus == .favoriten ? PhoneSwipeTexts.stempelFavorit : PhoneSwipeTexts.stempelBehalten,
                    symbol: modus == .favoriten ? "star.fill" : "checkmark",
                    farbe: modus == .favoriten ? Theme.favorite : Marke.tuerkis
                )
                .rotationEffect(.degrees(-12))
                .opacity(stempelFortschritt)
            }
            Spacer()
            if dragOffset.width < -Self.stempelSchwelle {
                stempelSchild(
                    text: modus == .favoriten ? PhoneSwipeTexts.stempelWeiter : PhoneSwipeTexts.stempelPapierkorb,
                    symbol: modus == .favoriten ? "arrow.right" : "trash.fill",
                    farbe: modus == .favoriten ? .white : Marke.koralle
                )
                .rotationEffect(.degrees(12))
                .opacity(stempelFortschritt)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 24)
    }

    private func stempelSchild(text: String, symbol: String, farbe: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.headline.weight(.heavy))
            .foregroundStyle(farbe)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(farbe, lineWidth: 2.5)
            }
    }

    private var fusszeile: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(datumAnzeige)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            if let stadt = karte.stadt {
                Label(stadt, systemImage: "mappin.and.ellipse")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.top, 36)
        .padding(.bottom, 16)
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.75)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var wischGeste: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard !entscheidungAbgeschickt else { return }
                dragOffset = value.translation
            }
            .onEnded { value in
                guard !entscheidungAbgeschickt else { return }
                let x = value.translation.width
                let predictedX = value.predictedEndTranslation.width
                if x > Self.schwellenAbstand || predictedX > Self.vorhersageSchwelle {
                    schliesseAb(.rechts)
                } else if x < -Self.schwellenAbstand || predictedX < -Self.vorhersageSchwelle {
                    schliesseAb(.links)
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                        dragOffset = .zero
                    }
                }
            }
    }

    private func schliesseAb(_ entscheidung: PhoneSwipeEntscheidung) {
        entscheidungAbgeschickt = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let zielX: CGFloat = entscheidung == .rechts ? 540 : -540
        withAnimation(.easeOut(duration: 0.18)) {
            dragOffset = CGSize(width: zielX, height: dragOffset.height)
        } completion: {
            onEntscheidung(entscheidung)
        }
    }

    private func ladeLokaleDateiFallsVorhanden() async {
        localImage = nil
        pruefungAbgeschlossen = false
        guard let url = PhoneOriginaldatei.aufPlatte(assetId: karte.id, context: modelContext) else {
            pruefungAbgeschlossen = true
            return
        }
        localImage = await Self.heruntergerechnetesBild(bei: url, laengsteKante: Self.maxKantenlaenge)
        pruefungAbgeschlossen = true
    }

    private static func heruntergerechnetesBild(bei url: URL, laengsteKante: CGFloat) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: laengsteKante
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return nil
            }
            return UIImage(cgImage: cgImage)
        }.value
    }
}
