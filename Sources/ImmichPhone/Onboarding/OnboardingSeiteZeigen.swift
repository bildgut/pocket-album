import SwiftUI

/// Seite 1: Ein Raster blüht von der Mitte auf, ein Bild wächst bildfüllend
/// heraus (ein Album öffnet sich), dann schwebt „available offline“ ein.
struct OnboardingSeiteZeigen: View {
    let aktiv: Bool
    @Environment(\.accessibilityReduceMotion) private var ruhig
    @State private var sichtbar = false
    @State private var gross = false
    @State private var abzeichen = false

    private let kacheln: [(OnboardingSzene, Int)] = [
        (.sonnenuntergang, 0), (.berge, 0), (.portraet, 0), (.stadt, 0), (.strand, 0),
        (.wald, 0), (.berge, 1), (.sonnenuntergang, 1), (.portraet, 1),
    ]

    var body: some View {
        OnboardingSeitenRahmen(titel: OnboardingTexts.zeigenTitel, zeigtMarke: true, text: OnboardingTexts.zeigenText) {
            GeometryReader { geo in
                let spalte = (geo.size.width - 28 - 12) / 3
                ZStack {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(spalte), spacing: 6), count: 3), spacing: 6) {
                        ForEach(kacheln.indices, id: \.self) { i in
                            OnboardingSzenenKachel(kacheln[i].0, stellung: kacheln[i].1)
                                .frame(height: spalte * 1.2)
                                .clipShape(.rect(cornerRadius: 10))
                                .opacity(sichtbar ? 1 : 0)
                                .scaleEffect(ruhig || sichtbar ? 1 : 0.3)
                                .animation(
                                    ruhig ? .easeInOut(duration: 0.4)
                                          : .spring(duration: 0.6, bounce: 0.4).delay(abstand(i) * 0.12),
                                    value: sichtbar
                                )
                        }
                    }
                    .padding(.top, 132)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .opacity(gross ? 0 : 1)

                    OnboardingSzenenKachel(.strand)
                        .frame(width: gross ? geo.size.width : spalte,
                               height: gross ? geo.size.height : spalte * 1.2)
                        .clipShape(.rect(cornerRadius: gross ? 0 : 10))
                        .opacity(gross ? 1 : 0)

                    Label(OnboardingTexts.offlineAbzeichen, systemImage: "icloud.and.arrow.down")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .glassEffect(.regular, in: .capsule)
                        .opacity(abzeichen ? 1 : 0)
                        .offset(y: abzeichen || ruhig ? 30 : 44)
                }
            }
        }
        .task(id: aktiv) {
            guard aktiv else { return }
            while !Task.isCancelled {
                sichtbar = false
                gross = false
                abzeichen = false
                try? await Task.sleep(for: .milliseconds(150))
                sichtbar = true
                try? await Task.sleep(for: .seconds(2.6))
                withAnimation(ruhig ? .easeInOut(duration: 0.5) : .smooth(duration: 0.9)) { gross = true }
                try? await Task.sleep(for: .seconds(0.9))
                withAnimation(.easeOut(duration: 0.5)) { abzeichen = true }
                try? await Task.sleep(for: .seconds(2.4))
            }
        }
    }

    /// Ringe um die Mitte (Index 4): 0 für die Mitte, 1 für Kanten, 2 für Ecken.
    private func abstand(_ i: Int) -> Double {
        Double(abs(i / 3 - 1) + abs(i % 3 - 1))
    }
}
