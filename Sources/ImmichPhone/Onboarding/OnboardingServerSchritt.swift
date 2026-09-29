import SwiftUI

/// Schritt 1: Server-Adresse, geprüft schon beim Tippen.
struct OnboardingServerSchritt: View {
    let modell: PhoneEinrichtung
    @State private var eingabe = ""
    /// Die nächste Änderung stammt aus „Einfügen“: sofort prüfen statt abzuwarten.
    @State private var eingefuegt = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let farben = OnboardingFarben(scheme)
        OnboardingSchrittRahmen(
            schritt: OnboardingTexts.schritt1,
            titel: OnboardingTexts.serverTitel,
            text: OnboardingTexts.serverText,
            knopf: OnboardingTexts.weiter,
            knopfAktiv: modell.serverURL != nil,
            knopfArbeitet: false,
            aktion: { modell.schritt = .key }
        ) {
            VStack(alignment: .leading, spacing: 10) {
                // Platzhalter als String-Konstante: ein URL-artiges Literal würde
                // SwiftUI zum Link machen und den Tipp aufs Feld schlucken (CLAUDE.md).
                OnboardingFeld(platzhalter: OnboardingTexts.serverPlatzhalter, text: $eingabe, tastatur: .URL) {
                    if modell.server == .prueft {
                        ProgressView().controlSize(.small)
                    } else {
                        // `PasteButton` statt `UIPasteboard`: Der Systemknopf liefert ohne
                        // die Rückfrage „… möchte einfügen“.
                        PasteButton(payloadType: String.self) { texte in
                            guard let text = texte.first else { return }
                            Task { @MainActor in
                                eingefuegt = true
                                eingabe = ServerAdresse.ausZwischenablage(text)
                            }
                        }
                        .labelStyle(.titleOnly)
                        .buttonBorderShape(.capsule)
                        .font(.footnote.weight(.semibold))
                        .tint(farben.text)
                    }
                }
                .onChange(of: eingabe) { _, neu in
                    if eingefuegt {
                        eingefuegt = false
                        modell.serverEingefuegt(neu)
                    } else {
                        modell.serverEingabeGeaendert(neu)
                    }
                }
                .onSubmit { Task { await modell.pruefeServer(eingabe) } }
                status(farben)
                    .font(.footnote)
                    .animation(.snappy, value: modell.server)
            }
        }
    }

    @ViewBuilder private func status(_ farben: OnboardingFarben) -> some View {
        switch modell.server {
        case .gefunden(_, let version):
            Label(OnboardingTexts.serverGefunden(version.description), systemImage: "checkmark.circle.fill")
                .foregroundStyle(farben.erfolg)
                .transition(.move(edge: .top).combined(with: .opacity))
        case .zuAlt(let version):
            Label(OnboardingTexts.serverZuAlt(version.description), systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .keinImmich:
            Label(OnboardingTexts.serverKeinImmich, systemImage: "questionmark.circle")
                .foregroundStyle(.orange)
        case .nichtErreichbar:
            Label(OnboardingTexts.serverNichtErreichbar, systemImage: "wifi.slash")
                .foregroundStyle(.orange)
        case .leer, .prueft:
            EmptyView()
        }
    }
}
