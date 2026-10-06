import SwiftUI

/// „Alle“ Personen mit Suche — aus dem Personen-Abschnitt von „Entdecken“.
struct PhonePersonenListe: View {
    let personen: [Person]
    let apiClient: ImmichAPIClient
    let tippen: (Person) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var suchtext = ""

    private var gefiltert: [Person] {
        let text = suchtext.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return personen }
        return personen.filter { $0.name.localizedStandardContains(text) }
    }

    var body: some View {
        List(gefiltert) { person in
            Button {
                tippen(person)
                dismiss()
            } label: {
                HStack(spacing: 12) {
                    PhonePersonenGesicht(person: person, apiClient: apiClient, groesse: 40)
                    Text(person.name)
                    Spacer()
                    if let anzahl = person.assetCount {
                        Text(anzahl.formatted())
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .listStyle(.plain)
        .navigationTitle(PhoneOrtsTexts.personen)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $suchtext)
    }
}
