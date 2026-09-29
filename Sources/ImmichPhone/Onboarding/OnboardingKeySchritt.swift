import SwiftUI

/// Schritt 2: API-Key einfügen. Danach zeigt die App, was der Key darf.
struct OnboardingKeySchritt: View {
    let modell: PhoneEinrichtung
    @State private var eingabe = ""
    @State private var zeigtHilfe = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let farben = OnboardingFarben(scheme)
        OnboardingSchrittRahmen(
            schritt: OnboardingTexts.schritt2,
            titel: OnboardingTexts.keyTitel,
            text: OnboardingTexts.keyText,
            knopf: OnboardingTexts.verbinden,
            knopfAktiv: modell.kannVerbinden,
            knopfArbeitet: modell.key == .prueft,
            aktion: { Task { await modell.weiterZuFertig() } }
        ) {
            VStack(alignment: .leading, spacing: 14) {
                OnboardingFeld(platzhalter: OnboardingTexts.keyPlatzhalter, text: $eingabe, monospaced: true) {
                    Button(OnboardingTexts.einfuegen) {
                        if let text = UIPasteboard.general.string { eingabe = text }
                    }
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.bordered)
                    .tint(farben.text)
                }
                .onChange(of: eingabe) { _, neu in Task { await modell.pruefeKey(neu) } }
                rechte(farben)
                    .animation(.snappy, value: modell.key)
                VStack(alignment: .leading, spacing: 10) {
                    Button(OnboardingTexts.wieKey) { zeigtHilfe = true }
                    if modell.passwortLoginErlaubt {
                        Button(OnboardingTexts.stattdessenAnmelden) { modell.schritt = .anmelden }
                    }
                }
                .font(.footnote)
                .foregroundStyle(farben.nebentext)
                .padding(.top, 6)
            }
        }
        .sheet(isPresented: $zeigtHilfe) {
            OnboardingHilfe(modell: modell)
        }
        .onAppear {
            // Zurück aus der Anmeldung: den dort angelegten Key zeigen.
            if eingabe.isEmpty, !modell.gepruefterKey.isEmpty { eingabe = modell.gepruefterKey }
        }
    }

    @ViewBuilder private func rechte(_ farben: OnboardingFarben) -> some View {
        switch modell.key {
        case .gueltig(let r):
            let zeilen: [(String, Bool)] = [
                (OnboardingTexts.rechtAlben, r.darf("album.read") && r.darf("asset.read") && r.darf("asset.view")),
                (OnboardingTexts.rechtOrte, r.darf("asset.statistics")),
                (OnboardingTexts.rechtPersonen, r.darf("person.read")),
                (OnboardingTexts.rechtOffline, r.darf("asset.download")),
                (OnboardingTexts.rechtAendern, r.darf(KeyRechte.favorit) && r.darf(KeyRechte.loeschen)),
            ]
            VStack(alignment: .leading, spacing: 6) {
                ForEach(zeilen.indices, id: \.self) { i in
                    Label(zeilen[i].0, systemImage: zeilen[i].1 ? "checkmark" : "minus")
                        .foregroundStyle(zeilen[i].1 ? farben.text : farben.nebentext)
                }
            }
            .font(.footnote)
            .transition(.move(edge: .leading).combined(with: .opacity))
        case .abgelehnt:
            Label(OnboardingTexts.keyAbgelehnt, systemImage: "xmark.circle")
                .font(.footnote).foregroundStyle(.orange)
        case .ohneAlbumRecht:
            Label(OnboardingTexts.keyOhneAlben, systemImage: "lock")
                .font(.footnote).foregroundStyle(.orange)
        case .fehler(let text):
            Label(text, systemImage: "exclamationmark.triangle")
                .font(.footnote).foregroundStyle(.orange)
        case .leer, .prueft:
            EmptyView()
        }
    }
}
