import SwiftUI

/// Seite 3: Ein Fernseher mit wechselnden Szenen, Signalwellen, darunter das
/// Telefon als Fernbedienung.
struct OnboardingSeiteFernseher: View {
    let aktiv: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var ruhig
    @State private var bild = 0
    @State private var welle = false

    private let folge: [OnboardingSzene] = [.berge, .sonnenuntergang, .wald]

    var body: some View {
        let farben = OnboardingFarben(scheme)
        OnboardingSeitenRahmen(titel: OnboardingTexts.fernseherTitel, text: OnboardingTexts.fernseherText) {
            VStack(spacing: 0) {
                ZStack {
                    ForEach(folge.indices, id: \.self) { i in
                        OnboardingSzenenKachel(folge[i])
                            .scaleEffect(i == bild && !ruhig ? 1.12 : 1)
                            .opacity(i == bild ? 1 : 0)
                    }
                }
                .frame(height: 170)
                .clipShape(.rect(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(farben.text.opacity(0.25), lineWidth: 3))
                .shadow(color: farben.schein, radius: 30)
                .padding(.horizontal, 26)
                Rectangle().fill(farben.text.opacity(0.25)).frame(width: 44, height: 8)
                ZStack(alignment: .top) {
                    Circle().stroke(farben.schein, lineWidth: 2).frame(width: 40)
                        .scaleEffect(welle ? 1.8 : 0.5)
                        .opacity(welle || ruhig ? 0 : 1)
                    RoundedRectangle(cornerRadius: 14).fill(farben.feld)
                        .overlay(RoundedRectangle(cornerRadius: 14).stroke(farben.text.opacity(0.25), lineWidth: 2))
                        .overlay(
                            HStack(spacing: 10) {
                                Image(systemName: "chevron.left")
                                Image(systemName: "pause.fill")
                                Image(systemName: "chevron.right")
                            }
                            .font(.caption2)
                            .foregroundStyle(farben.text.opacity(0.8))
                        )
                        .frame(width: 66, height: 100)
                        .padding(.top, 40)
                }
                .padding(.top, 10)
            }
            .padding(.top, 132)
            .frame(maxHeight: .infinity, alignment: .top)
            .accessibilityHidden(true)
        }
        .task(id: aktiv) {
            guard aktiv else { return }
            if !ruhig {
                welle = false
                withAnimation(.easeOut(duration: 1.5).repeatForever(autoreverses: false)) { welle = true }
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                withAnimation(.easeInOut(duration: ruhig ? 0.6 : 1.2)) { bild = (bild + 1) % folge.count }
            }
        }
    }
}
