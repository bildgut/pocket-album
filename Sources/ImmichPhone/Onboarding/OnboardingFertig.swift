import SwiftUI

/// Fertig: Haken federt ein, dann blühen die echten Albumcover auf.
struct OnboardingFertig: View {
    let modell: PhoneEinrichtung
    let oeffnen: () -> Void
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var ruhig
    @State private var haken = false
    @State private var cover = false
    @State private var verbindet = false
    /// Einmal dekodiert, wenn die Zusammenfassung kommt — nicht bei jedem Zeichnen.
    @State private var bilder: [UIImage] = []

    var body: some View {
        let farben = OnboardingFarben(scheme)
        VStack(spacing: 20) {
            ZStack {
                Circle().stroke(farben.erfolg, lineWidth: 3).frame(width: 84, height: 84)
                Image(systemName: "checkmark")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(farben.erfolg)
            }
            .scaleEffect(haken || ruhig ? 1 : 0.2)
            .opacity(haken ? 1 : 0)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(bilder.indices, id: \.self) { i in
                    Color.clear
                        .frame(height: 96)
                        .overlay(Image(uiImage: bilder[i]).resizable().scaledToFill())
                        .clipShape(.rect(cornerRadius: 10))
                        .opacity(cover ? 1 : 0)
                        .scaleEffect(cover || ruhig ? 1 : 0.3)
                        .animation(
                            ruhig ? .easeInOut : .spring(duration: 0.6, bounce: 0.4).delay(Double(i) * 0.08),
                            value: cover
                        )
                }
            }
            .padding(.horizontal, 14)

            VStack(spacing: 6) {
                Text(OnboardingTexts.fertigTitel)
                    // Textstil statt fester Größe: wächst mit Dynamic Type, gedeckelt,
                    // damit der Titel das Blatt nicht sprengt.
                    .font(.title.weight(.heavy))
                    .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                    .foregroundStyle(farben.text)
                if let z = modell.zusammenfassung {
                    if let zahlen = OnboardingTexts.fertigZahlen(alben: z.alben, fotos: z.fotos) {
                        Text(zahlen)
                            .font(.subheadline)
                            .foregroundStyle(farben.nebentext)
                    }
                } else {
                    ProgressView()
                }
            }
            if let fehler = modell.verbindeFehler {
                Label(fehler, systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.orange)
                    .padding(.horizontal, 24)
            }
            Spacer()
            Button {
                verbindet = true
                oeffnen()
            } label: {
                Group {
                    if verbindet { ProgressView().tint(farben.knopfText) } else { Text(OnboardingTexts.albenOeffnen).font(.headline) }
                }
                .frame(maxWidth: .infinity).frame(height: 52)
                .foregroundStyle(farben.knopfText)
                .background(farben.knopf, in: Capsule())
            }
            .disabled(verbindet)
            .padding(.horizontal, 24).padding(.bottom, 12)
        }
        .padding(.top, 60)
        .onChange(of: modell.zusammenfassung, initial: true) { _, z in
            bilder = (z?.titelbilder ?? []).compactMap(UIImage.init(data:))
        }
        .onChange(of: modell.verbindeFehler) { _, fehler in
            if fehler != nil { verbindet = false }
        }
        .task {
            withAnimation(ruhig ? .easeIn : .spring(duration: 0.5, bounce: 0.5)) { haken = true }
            try? await Task.sleep(for: .seconds(1.0))
            cover = true
        }
    }
}
