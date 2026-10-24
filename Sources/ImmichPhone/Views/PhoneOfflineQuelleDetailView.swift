import SwiftUI
import SwiftData

/// Detailseite einer Offline-Quelle: Qualität, Mobilfunk, bei „Letzte Tage“ die
/// Stufe, unten Entfernen. Jede Änderung gilt sofort — wie in den Einstellungen.
struct PhoneOfflineQuelleDetailView: View {
    let quelle: PhoneOfflineQuelle

    @Environment(ConnectionManager.self) private var connection
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var wahl: OfflineWahl
    @State private var tage: Int
    @State private var zeigtEntfernen = false

    init(quelle: PhoneOfflineQuelle, tage: Int) {
        self.quelle = quelle
        _wahl = State(initialValue: quelle.wahl ?? PhoneOfflineModel.vorgabeWahl)
        _tage = State(initialValue: tage)
    }

    var body: some View {
        Form {
            Section {
                LabeledContent(String(localized: "Status"), value: quelle.zustand.beschreibung)
                LabeledContent(String(localized: "On This iPhone"), value: quelle.eintrag.groesse)
            }
            if quelle.kind == .zuletzt {
                Section {
                    Picker(String(localized: "Days"), selection: $tage) {
                        ForEach(ZuletztOffline.stufen.filter { $0 > 0 }, id: \.self) { stufe in
                            Text(String(localized: "\(stufe) days")).tag(stufe)
                        }
                    }
                } footer: {
                    Text(String(localized: "Photos you took in the last days stay on this iPhone and are replaced automatically as new ones arrive. Photos from shared albums are not included."))
                }
            }
            Section(String(localized: "Photos")) {
                Picker(String(localized: "Photos"), selection: $wahl.fotos) {
                    Text(String(localized: "Preview")).tag(OfflineWahl.Fotos.vorschau)
                    Text(String(localized: "Original")).tag(OfflineWahl.Fotos.original)
                }
                .pickerStyle(.segmented)
            }
            Section(String(localized: "Videos")) {
                Picker(String(localized: "Videos"), selection: $wahl.videos) {
                    Text(String(localized: "None")).tag(OfflineWahl.Videos.keine)
                    Text(String(localized: "Small")).tag(OfflineWahl.Videos.klein)
                    Text(String(localized: "Original")).tag(OfflineWahl.Videos.original)
                }
                .pickerStyle(.segmented)
            }
            Section {
                Toggle(String(localized: "Also over Cellular"), isOn: $wahl.mobilfunk)
            }
            Section {
                Button(String(localized: "Remove from This iPhone"), role: .destructive) { zeigtEntfernen = true }
            }
        }
        .navigationTitle(quelle.titel(tage: tage))
        .navigationBarTitleDisplayMode(.inline)
        .disabled(connection.apiClient == nil)
        .onChange(of: wahl) { _, neu in
            guard let apiClient = connection.apiClient else { return }
            PhoneOfflineModel.aendereWahl(neu, kind: quelle.kind, targetId: quelle.targetId,
                                          displayName: quelle.eintrag.name, context: modelContext, apiClient: apiClient)
        }
        .onChange(of: tage) { _, neu in
            guard let apiClient = connection.apiClient else { return }
            PhoneOfflineModel().setzeZuletzt(tage: neu, context: modelContext, apiClient: apiClient)
        }
        .confirmationDialog(String(localized: "Remove “\(quelle.titel(tage: tage))” from this iPhone?"),
                            isPresented: $zeigtEntfernen, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                guard let apiClient = connection.apiClient else { return }
                PhoneOfflineModel.hebeAuf(kind: quelle.kind, targetId: quelle.targetId, displayName: quelle.eintrag.name,
                                          context: modelContext, apiClient: apiClient)
                dismiss()
            }
        } message: {
            Text("The photos stay on the server.")
        }
    }
}
