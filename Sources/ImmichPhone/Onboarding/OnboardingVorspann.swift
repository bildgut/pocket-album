import SwiftUI

/// Die drei Vorspann-Seiten: Zeigen, Finden, Groß zeigen. `fertig` läuft bei
/// „Skip“ und beim letzten Knopf.
struct OnboardingVorspann: View {
    let letzterKnopf: String
    let fertig: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var seite = 0

    var body: some View {
        let farben = OnboardingFarben(scheme)
        ZStack(alignment: .topTrailing) {
            farben.hintergrund.ignoresSafeArea()
            TabView(selection: $seite) {
                OnboardingSeiteZeigen(aktiv: seite == 0).tag(0)
                OnboardingSeiteFinden(aktiv: seite == 1).tag(1)
                OnboardingSeiteFernseher(aktiv: seite == 2).tag(2)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea(edges: .top)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 18) {
                    HStack(spacing: 6) {
                        ForEach(0..<3, id: \.self) { i in
                            Capsule().fill(farben.text.opacity(i == seite ? 1 : 0.3))
                                .frame(width: i == seite ? 18 : 6, height: 6)
                        }
                    }
                    .animation(.snappy, value: seite)
                    .accessibilityHidden(true)
                    Button {
                        if seite < 2 { withAnimation { seite += 1 } } else { fertig() }
                    } label: {
                        Text(seite < 2 ? OnboardingTexts.weiter : letzterKnopf)
                            .font(.headline).frame(maxWidth: .infinity).frame(height: 52)
                            .foregroundStyle(farben.knopfText)
                            .background(farben.knopf, in: Capsule())
                    }
                    .padding(.horizontal, 24)
                }
                .padding(.bottom, 12)
            }
            // Auf der letzten Seite macht der Hauptknopf dasselbe — „Skip“ wäre doppelt.
            Button(OnboardingTexts.ueberspringen, action: fertig)
                .foregroundStyle(farben.nebentext).padding(20)
                .opacity(seite < 2 ? 1 : 0)
                .disabled(seite >= 2)
                .accessibilityHidden(seite >= 2)
                .animation(.snappy, value: seite)
        }
    }
}

/// Gemeinsamer Rahmen einer Seite: Bühne oben, Verlauf, Überschrift und Satz.
struct OnboardingSeitenRahmen<Buehne: View>: View {
    let titel: String
    /// Seite 1: Symbol und Schriftzug der Marke statt des Titels.
    var zeigtMarke = false
    let text: String
    @ViewBuilder let buehne: () -> Buehne
    @Environment(\.colorScheme) private var scheme
    @ScaledMetric(relativeTo: .title) private var titelGroesse: CGFloat = 30

    var body: some View {
        let farben = OnboardingFarben(scheme)
        GeometryReader { geo in
            ZStack(alignment: .top) {
                buehne()
                    .frame(width: geo.size.width, height: geo.size.height * 0.68)
                    .clipped()
                LinearGradient(
                    colors: [farben.hintergrund.opacity(0), farben.hintergrund],
                    startPoint: UnitPoint(x: 0.5, y: 0.44), endPoint: UnitPoint(x: 0.5, y: 0.68)
                )
                .allowsHitTesting(false)
                VStack(spacing: 10) {
                    if zeigtMarke {
                        HStack(spacing: 14) {
                            PocketAlbumSymbol(groesse: 58)
                            PocketAlbumSchriftzug(groesse: 30)
                                .foregroundStyle(farben.text)
                        }
                        .padding(.bottom, 4)
                    } else {
                        Text(titel)
                            // 30 pt wie bisher, aber mit Dynamic Type skaliert und bei 44 gedeckelt.
                            .font(.system(size: min(titelGroesse, 44), weight: .heavy))
                            .foregroundStyle(farben.text)
                            .multilineTextAlignment(.center)
                    }
                    Text(text)
                        .font(.subheadline)
                        .foregroundStyle(farben.nebentext)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 28)
                .frame(maxWidth: .infinity)
                .offset(y: geo.size.height * 0.66)
            }
        }
        // Die Bühne reicht bis unter die Statusleiste; „Skip“ liegt darüber.
        .ignoresSafeArea(edges: .top)
    }
}
