import SwiftUI

/// Wurzel des Onboardings: Vorspann → Server → Key (↔ Anmelden) → Fertig.
struct OnboardingAblauf: View {
    @Environment(ConnectionManager.self) private var connection
    @Environment(\.colorScheme) private var scheme
    @State private var modell: PhoneEinrichtung

    init(mitVorspann: Bool) {
        _modell = State(initialValue: PhoneEinrichtung(mitVorspann: mitVorspann))
    }

    var body: some View {
        ZStack {
            OnboardingFarben(scheme).hintergrund.ignoresSafeArea()
            switch modell.schritt {
            case .vorspann:
                OnboardingVorspann(letzterKnopf: OnboardingTexts.einrichten) {
                    OnboardingStatus.markiereGesehen()
                    modell.schritt = .server
                }
                .transition(.opacity)
            case .server:
                OnboardingServerSchritt(modell: modell)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            case .key:
                OnboardingKeySchritt(modell: modell)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            case .anmelden:
                OnboardingAnmelden(modell: modell)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            case .fertig:
                OnboardingFertig(modell: modell) {
                    Task { await modell.verbinde(mit: connection) }
                }
                .transition(.opacity)
            }
        }
        .animation(.smooth, value: modell.schritt)
    }
}

/// Kopf eines Einrichtungsschritts und Primärknopf unten — gemeinsam für alle Schritte.
struct OnboardingSchrittRahmen<Inhalt: View>: View {
    let schritt: String?
    let titel: String
    let text: String
    let knopf: String
    let knopfAktiv: Bool
    let knopfArbeitet: Bool
    let aktion: () -> Void
    @ViewBuilder let inhalt: () -> Inhalt
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let farben = OnboardingFarben(scheme)
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let schritt {
                        Text(schritt.uppercased())
                            .font(.caption2.weight(.semibold)).kerning(1)
                            .foregroundStyle(farben.nebentext)
                    }
                    Text(titel)
                        // Textstil statt fester Größe: wächst mit Dynamic Type, gedeckelt,
                        // damit der Titel das Blatt nicht sprengt.
                        .font(.title.weight(.heavy))
                        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                        .foregroundStyle(farben.text)
                        .padding(.top, 6)
                    Text(text)
                        .font(.subheadline)
                        .foregroundStyle(farben.nebentext)
                        .padding(.top, 6)
                    inhalt().padding(.top, 18)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.interactively)
            Button(action: aktion) {
                Group {
                    if knopfArbeitet {
                        ProgressView().tint(farben.knopfText)
                    } else {
                        Text(knopf).font(.headline)
                    }
                }
                .frame(maxWidth: .infinity).frame(height: 52)
                .foregroundStyle(farben.knopfText)
                .background(farben.knopf.opacity(knopfAktiv ? 1 : 0.35), in: Capsule())
            }
            .disabled(!knopfAktiv || knopfArbeitet)
            .padding(.top, 12)
        }
        .padding(.horizontal, 24).padding(.top, 40).padding(.bottom, 12)
    }
}

/// Eingabefeld im Onboarding-Stil.
struct OnboardingFeld<Zusatz: View>: View {
    let platzhalter: String
    @Binding var text: String
    var sicher = false
    var tastatur: UIKeyboardType = .default
    var monospaced = false
    @ViewBuilder var zusatz: () -> Zusatz
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let farben = OnboardingFarben(scheme)
        HStack {
            Group {
                if sicher {
                    SecureField(platzhalter, text: $text)
                } else {
                    TextField(platzhalter, text: $text)
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(tastatur)
            .font(monospaced ? .system(.body, design: .monospaced) : .body)
            zusatz()
        }
        .padding(.horizontal, 14).frame(height: 50)
        .background(farben.feld, in: .rect(cornerRadius: 12))
        .foregroundStyle(farben.text)
    }
}
