import SwiftUI

/// „How do I get a key?“: drei Schritte, Rechte-Liste zum Kopieren, Link zu Immich.
struct OnboardingHilfe: View {
    @Bindable var modell: PhoneEinrichtung
    @Environment(\.openURL) private var openURL
    @State private var kopiert = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(OnboardingTexts.hilfeSchritt1, systemImage: "1.circle")
                    Label(OnboardingTexts.hilfeSchritt2, systemImage: "2.circle")
                    Label(OnboardingTexts.hilfeSchritt3, systemImage: "3.circle")
                }
                Section {
                    Picker(selection: $modell.umfang) {
                        Text(OnboardingTexts.nurAnsehen).tag(PhoneEinrichtung.Umfang.nurAnsehen)
                        Text(OnboardingTexts.allesErlaubt).tag(PhoneEinrichtung.Umfang.voll)
                    } label: {
                        EmptyView()
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: modell.umfang) { kopiert = false }
                    Text(modell.umfang.rechte.joined(separator: "\n"))
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                    Button(kopiert ? OnboardingTexts.kopiert : OnboardingTexts.kopieren) {
                        UIPasteboard.general.string = modell.umfang.rechte.joined(separator: "\n")
                        kopiert = true
                    }
                }
                if let url = modell.serverURL {
                    Section {
                        Button(OnboardingTexts.immichOeffnen) {
                            // Kein `isOpen`-Parameter: Immichs `OpenQueryParam` kennt keinen
                            // Wert für die API-Schlüssel (geprüft am Web-Quelltext, 28.09.2026).
                            openURL(url.appending(path: "user-settings"))
                        }
                    }
                }
            }
            .navigationTitle(OnboardingTexts.hilfeTitel)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
