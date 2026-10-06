import SwiftUI

/// Seite 2: Drei Chips rasten nacheinander ein, das Raster dünnt aus, der
/// Zähler fällt — „in zwei Tipps gefunden“.
struct OnboardingSeiteFinden: View {
    let aktiv: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var ruhig
    @State private var stufe = 0

    // Beispielwerte der Animation, keine Daten — bewusst nicht übersetzt.
    private let chips = ["Italy", "2019", "Anna", "Rome", "Tom"]
    private let zaehler = [2841, 612, 94, 23]
    /// Ab welcher Stufe eine Kachel verschwindet (99 = bleibt).
    private let wegAb = [99, 1, 2, 99, 1, 3, 99, 1, 2, 3, 99, 2]

    var body: some View {
        let farben = OnboardingFarben(scheme)
        OnboardingSeitenRahmen(titel: OnboardingTexts.findenTitel, text: OnboardingTexts.findenText) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 6) {
                    ForEach(chips.indices, id: \.self) { i in
                        let an = i < stufe
                        Text(chips[i])
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 11).padding(.vertical, 6)
                            .foregroundStyle(an ? farben.knopfText : farben.text.opacity(0.6))
                            .background(an ? farben.knopf : farben.feld, in: Capsule())
                            .scaleEffect(an || ruhig ? 1 : 0.94)
                    }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 4), spacing: 5) {
                    ForEach(wegAb.indices, id: \.self) { i in
                        OnboardingSzenenKachel(OnboardingSzene.allCases[i % 6], stellung: i / 6)
                            .frame(height: 58)
                            .clipShape(.rect(cornerRadius: 7))
                            .opacity(stufe >= wegAb[i] ? 0 : 1)
                            .scaleEffect(ruhig || stufe < wegAb[i] ? 1 : 0.6)
                    }
                }
                Text(OnboardingTexts.fotoZahl(zaehler[stufe]))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(farben.nebentext)
                    .contentTransition(ruhig ? .opacity : .numericText(countsDown: true))
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 16)
            .padding(.top, 132)
            .frame(maxHeight: .infinity, alignment: .top)
            .animation(ruhig ? .easeInOut(duration: 0.3) : .spring(duration: 0.45, bounce: 0.35), value: stufe)
        }
        .task(id: aktiv) {
            guard aktiv else { return }
            while !Task.isCancelled {
                stufe = 0
                for s in 1...3 {
                    try? await Task.sleep(for: .seconds(0.9))
                    stufe = s
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
}
