import SwiftUI
import SwiftData

/// Die Seite „Offline“: alle Quellen in Ladereihenfolge, per Ziehen sortierbar
/// (Spec `docs/superpowers/specs/2026-10-22-ios-offline-quellen-design.md`).
///
/// Eine flache Liste statt Gruppen je Art — Ziehen über Gruppengrenzen verwirrt.
/// Ausgeschaltete Arten stehen nicht in der Liste, sondern unter „Hinzufügen“.
struct PhoneOfflineQuellenView: View {
    @Environment(ConnectionManager.self) private var connection
    @Environment(\.modelContext) private var modelContext

    @Query(sort: \OfflinePin.pinnedAt) private var pins: [OfflinePin]
    @State private var quellen: [PhoneOfflineQuelle] = []
    @State private var berechnungsLauf: UInt64 = 0
    @State private var darfPersonen = true
    @State private var freiAufGeraet = PhoneOfflineBlattModell.freierPlatz()

    /// Offenes Blatt „Offline speichern“ für eine neue Quelle.
    @State private var blatt: NeueQuelle?
    @State private var zeigtPersonenAuswahl = false
    @State private var zuEntfernen: PhoneOfflineQuelle?
    /// Die gewählte Person, bis die Auswahl geschlossen ist — erst dann darf das
    /// Offline-Blatt erscheinen (zwei Blätter zugleich zeigt SwiftUI nicht).
    @State private var gewaehltePerson: NeueQuelle?
    /// Eigener Bearbeiten-Zustand: Solange gezogen wird, setzt die Neuberechnung
    /// aus — sonst bezögen sich die Indizes des Ziehens auf eine ersetzte Liste.
    @State private var editMode: EditMode = .inactive

    struct NeueQuelle: Identifiable {
        let kind: OfflinePinKind
        let targetId: String
        let titel: String
        var id: String { OfflinePin.pinId(kind: kind, targetId: targetId) }
    }

    private var tage: Int { ZuletztOffline.tage() }

    var body: some View {
        List {
            speicherAbschnitt
            if !quellen.isEmpty {
                Section {
                    ForEach(quellen) { quelle in
                        NavigationLink {
                            PhoneOfflineQuelleDetailView(quelle: quelle, tage: tage)
                        } label: {
                            zeile(quelle)
                        }
                    }
                    .onMove(perform: verschiebe)
                    .onDelete { indizes in zuEntfernen = indizes.first.map { quellen[$0] } }
                } header: {
                    Text("Loaded in This Order")
                } footer: {
                    Text("Sources at the top are on this iPhone first. Drag to change the order.")
                }
            }
            hinzufuegenAbschnitt
            Section {
                NavigationLink(String(localized: "Download Log")) { PhoneOfflineProtokollView() }
            }
        }
        .navigationTitle("Offline")
        .toolbar { if !quellen.isEmpty { EditButton() } }
        .environment(\.editMode, $editMode)
        .onChange(of: editMode.isEditing) { _, bearbeitet in
            if !bearbeitet { Task { await neuBerechnen() } }
        }
        .task(id: pins.map(\.pinId)) { await neuBerechnen() }
        .task(id: OfflineSyncProgress.shared.isActive) {
            if !OfflineSyncProgress.shared.isActive { await neuBerechnen() }
        }
        .task { await pruefePersonenRecht() }
        .sheet(item: $blatt) { neu in
            if let apiClient = connection.apiClient {
                PhoneOfflineBlatt(
                    modell: PhoneOfflineBlattModell(quelle: neu.kind, targetId: neu.targetId, titel: neu.titel,
                                                    wahl: PhoneOfflineModel.vorgabeWahl, freierPlatz: freiAufGeraet),
                    apiClient: apiClient
                ) { wahl in
                    speichere(neu, wahl: wahl, apiClient: apiClient)
                }
            }
        }
        .sheet(isPresented: $zeigtPersonenAuswahl, onDismiss: {
            blatt = gewaehltePerson
            gewaehltePerson = nil
        }) {
            PhonePersonenAuswahlView(schonOffline: Set(pins.filter { $0.kind == .person }.map(\.targetId))) { id, name in
                gewaehltePerson = NeueQuelle(kind: .person, targetId: id, titel: name)
                zeigtPersonenAuswahl = false
            }
        }
        .confirmationDialog(
            zuEntfernen.map { String(localized: "Remove “\($0.titel(tage: tage))” from this iPhone?") } ?? "",
            isPresented: Binding(get: { zuEntfernen != nil }, set: { if !$0 { zuEntfernen = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let quelle = zuEntfernen { entferne(quelle) }
                zuEntfernen = nil
            }
        } message: {
            Text("The photos stay on the server.")
        }
    }

    // MARK: - Abschnitte

    private var speicherAbschnitt: some View {
        Section {
            let belegt = quellen.reduce(Int64(0)) { $0 + $1.eintrag.bytes }
            LabeledContent(String(localized: "Used by Offline Photos"), value: PhoneStorageSummary.groesse(belegt))
            if let freiAufGeraet {
                LabeledContent(String(localized: "Free on This iPhone"), value: PhoneStorageSummary.groesse(freiAufGeraet))
            }
        }
    }

    @ViewBuilder
    private var hinzufuegenAbschnitt: some View {
        let vorhanden = Set(pins.map(\.kind))
        let arten = PhoneOfflineQuellen.hinzufuegbar(vorhanden: vorhanden, darfPersonen: darfPersonen)
        Section {
            ForEach(arten, id: \.self) { kind in
                Button {
                    fuegeHinzu(kind)
                } label: {
                    Label(Self.hinzufuegenText(kind), systemImage: kind.iconName)
                }
            }
            if !darfPersonen {
                Label(String(localized: "Person…"), systemImage: OfflinePinKind.person.iconName)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Add")
        } footer: {
            if !darfPersonen {
                Text("To keep people offline, the API key needs the “person.read” permission.")
            } else {
                Text("Albums are added from the album itself.")
            }
        }
        .disabled(connection.apiClient == nil)
    }

    private static func hinzufuegenText(_ kind: OfflinePinKind) -> String {
        switch kind {
        case .favoriten: return String(localized: "Favorites")
        case .zuletzt:   return String(localized: "Recent Days")
        case .person:    return String(localized: "Person…")
        case .album, .smartAlbum: return kind.label
        }
    }

    private func zeile(_ quelle: PhoneOfflineQuelle) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: quelle.kind.iconName)
                .foregroundStyle(Marke.akzent)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(quelle.titel(tage: tage))
                    .lineLimit(2)
                Text(quelle.zustand.beschreibung)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(quelle.zustand.istFehler ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text(quelle.untertitel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Aktionen

    private func verschiebe(von quelle: IndexSet, nach ziel: Int) {
        OfflineReihenfolge().verschiebe(quellen.map(\.id), von: quelle, nach: ziel)
        quellen.move(fromOffsets: quelle, toOffset: ziel)
    }

    private func fuegeHinzu(_ kind: OfflinePinKind) {
        guard let apiClient = connection.apiClient else { return }
        switch kind {
        case .favoriten:
            blatt = NeueQuelle(kind: .favoriten, targetId: OfflineQuellenFilter.favoritenTargetId,
                               titel: String(localized: "Favorites"))
        case .zuletzt:
            // Eine Woche als Anfang; Stufe und Qualität ändert die Detailseite.
            PhoneOfflineModel().setzeZuletzt(tage: 7, context: modelContext, apiClient: apiClient)
        case .person:
            zeigtPersonenAuswahl = true
        case .album, .smartAlbum:
            break
        }
    }

    private func speichere(_ neu: NeueQuelle, wahl: OfflineWahl, apiClient: ImmichAPIClient) {
        let modell = PhoneOfflineModel()
        switch neu.kind {
        case .favoriten:
            modell.setzeFavoriten(true, wahl: wahl, context: modelContext, apiClient: apiClient)
        case .person:
            modell.nimmOffline(person: neu.targetId, name: neu.titel, wahl: wahl, context: modelContext, apiClient: apiClient)
        case .album, .smartAlbum, .zuletzt:
            break
        }
    }

    private func entferne(_ quelle: PhoneOfflineQuelle) {
        guard let apiClient = connection.apiClient else { return }
        PhoneOfflineModel.hebeAuf(kind: quelle.kind, targetId: quelle.targetId, displayName: quelle.eintrag.name,
                                  context: modelContext, apiClient: apiClient)
    }

    /// Wie in den Einstellungen: Ein Lauf, der nach seinem `await` eine andere Zahl
    /// vorfindet, wurde überholt und verwirft sein Ergebnis.
    private func neuBerechnen() async {
        berechnungsLauf &+= 1
        let meinLauf = berechnungsLauf
        let speicher = OfflineWahlSpeicher()
        let ergebnis = await PhoneOfflineQuellen.berechne(
            pins.map { PhoneOfflineQuellen.Schnappschuss($0, speicher: speicher) },
            container: modelContext.container)
        guard meinLauf == berechnungsLauf, !editMode.isEditing else { return }
        quellen = PhoneOfflineQuellen.geordnet(ergebnis)
        freiAufGeraet = PhoneOfflineBlattModell.freierPlatz()
    }

    /// Ohne `person.read` antwortet `/api/people` mit 403 — dann keine Personen.
    private func pruefePersonenRecht() async {
        guard let apiClient = connection.apiClient else { return }
        do {
            _ = try await apiClient.getPeople()
            darfPersonen = true
        } catch {
            darfPersonen = PhoneOfflineQuellen.darfPersonen(nach: error)
        }
    }
}
