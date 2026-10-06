import SwiftUI

/// Optional: einmal anmelden, die App legt den Key selbst an.
struct OnboardingAnmelden: View {
    @Bindable var modell: PhoneEinrichtung
    @State private var email = ""
    /// Lebt nur hier und im Aufruf. Nach Erfolg geleert; nach einem Fehlschlag
    /// bleibt es stehen, damit ein Tippfehler in der E-Mail kein Neutippen erzwingt.
    @State private var passwort = ""
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let farben = OnboardingFarben(scheme)
        OnboardingSchrittRahmen(
            schritt: OnboardingTexts.schritt2,
            titel: OnboardingTexts.anmeldenTitel,
            text: OnboardingTexts.anmeldenText,
            knopf: OnboardingTexts.anmeldenKnopf,
            knopfAktiv: !email.isEmpty && !passwort.isEmpty,
            knopfArbeitet: modell.anmeldungLaeuft,
            aktion: {
                let wert = passwort
                Task {
                    await modell.meldeAn(email: email, passwort: wert, geraet: UIDevice.current.name)
                    if modell.anmeldeFehler == nil { passwort = "" }
                }
            }
        ) {
            VStack(alignment: .leading, spacing: 10) {
                OnboardingFeld(platzhalter: OnboardingTexts.email, text: $email, tastatur: .emailAddress) { EmptyView() }
                OnboardingFeld(platzhalter: OnboardingTexts.passwort, text: $passwort, sicher: true) { EmptyView() }
                Picker(selection: $modell.umfang) {
                    Text(OnboardingTexts.nurAnsehen).tag(PhoneEinrichtung.Umfang.nurAnsehen)
                    Text(OnboardingTexts.allesErlaubt).tag(PhoneEinrichtung.Umfang.voll)
                } label: {
                    EmptyView()
                }
                .pickerStyle(.segmented)
                if let fehler = modell.anmeldeFehler {
                    Label(fehler, systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.orange)
                }
                Text(OnboardingTexts.ssoHinweis)
                    .font(.caption).foregroundStyle(farben.nebentext)
                Button(OnboardingTexts.stattdessenKey) { modell.schritt = .key }
                    .font(.footnote).foregroundStyle(farben.nebentext)
            }
        }
    }
}
