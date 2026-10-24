import SwiftUI

/// Wählt eine Person für „Offline speichern“. Nur benannte Personen — ohne Namen
/// hätte die Zeile auf der Offline-Seite keine Beschriftung.
struct PhonePersonenAuswahlView: View {
    /// Personen, die schon eine Quelle sind; sie stehen ausgegraut im Raster.
    let schonOffline: Set<String>
    let gewaehlt: (_ id: String, _ name: String) -> Void

    @Environment(ConnectionManager.self) private var connection
    @Environment(\.dismiss) private var dismiss

    /// Serverliste, unsortiert: `/api/people` liefert sie schon nach Häufigkeit.
    @State private var personenVomServer: [Person] = []
    @State private var laedt = true
    @State private var fehler: String?
    @State private var suche = ""
    @State private var sortierung: PhonePersonenSortierung = .haeufigkeit

    private var angezeigt: [Person] {
        PhonePersonenSortierung.personen(personenVomServer, sortierung: sortierung, suche: suche)
    }

    var body: some View {
        NavigationStack {
            inhalt
                .searchable(text: $suche)
                .navigationTitle(String(localized: "Choose Person"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(String(localized: "Cancel")) { dismiss() }
                    }
                }
                .task { await lade() }
        }
    }

    @ViewBuilder
    private var inhalt: some View {
        if laedt {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let fehler {
            ContentUnavailableView {
                Label(fehler, systemImage: "exclamationmark.triangle")
            }
        } else {
            ScrollView {
                Picker(String(localized: "Name"), selection: $sortierung) {
                    ForEach(PhonePersonenSortierung.allCases) { Text($0.titel).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.top, 8)

                if angezeigt.isEmpty {
                    ContentUnavailableView(String(localized: "No people found"), systemImage: "person.2")
                } else if let apiClient = connection.apiClient {
                    LazyVGrid(columns: PhoneRasterSpalten.gesichter, spacing: 16) {
                        ForEach(angezeigt) { person in
                            zelle(person, apiClient: apiClient)
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    private func zelle(_ person: Person, apiClient: ImmichAPIClient) -> some View {
        let offline = schonOffline.contains(person.id)
        return Button {
            gewaehlt(person.id, person.name)
        } label: {
            VStack(spacing: 6) {
                PhonePersonenGesicht(person: person, apiClient: apiClient, groesse: 68)
                    .opacity(offline ? 0.4 : 1)
                    .overlay(alignment: .topTrailing) {
                        if offline {
                            Image(systemName: "checkmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(Marke.akzent, .white)
                                .background(Circle().fill(.white))
                        }
                    }
                Text(person.name)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(offline)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(offline
            ? "\(person.name), \(String(localized: "already offline"))"
            : person.name)
    }

    private func lade() async {
        defer { laedt = false }
        guard let apiClient = connection.apiClient else { return }
        do {
            personenVomServer = try await apiClient.getPeople()
        } catch {
            fehler = String(localized: "Couldn't load people: \(error.localizedDescription)")
        }
    }
}
