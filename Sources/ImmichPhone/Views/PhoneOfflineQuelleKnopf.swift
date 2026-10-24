import SwiftUI
import SwiftData

/// Schnellzugriff „Offline speichern“ für Favoriten und Personen: ein Knopf in der
/// Toolbar, der dasselbe Blatt öffnet wie auf der Seite „Offline“. Ist die Quelle
/// schon offline, ändert das Blatt nur ihre Wahl.
private struct PhoneOfflineQuelleKnopf: ViewModifier {
    let kind: OfflinePinKind
    let targetId: String
    let titel: String

    @Environment(ConnectionManager.self) private var connection
    @Environment(\.modelContext) private var modelContext
    @Query private var pins: [OfflinePin]
    @State private var zeigtBlatt = false

    init(kind: OfflinePinKind, targetId: String, titel: String) {
        self.kind = kind
        self.targetId = targetId
        self.titel = titel
        let pinId = OfflinePin.pinId(kind: kind, targetId: targetId)
        _pins = Query(filter: #Predicate<OfflinePin> { $0.pinId == pinId })
    }

    private var pinId: String { OfflinePin.pinId(kind: kind, targetId: targetId) }
    private var badge: OfflineBadge { pins.first.map(OfflineBadge.from(pin:)) ?? .cloud }

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        zeigtBlatt = true
                    } label: {
                        Label(String(localized: "Keep Offline"),
                              systemImage: badge == .cloud ? "arrow.down.circle" : badge.symbolName)
                    }
                    .disabled(connection.apiClient == nil)
                }
            }
            .sheet(isPresented: $zeigtBlatt) {
                if let apiClient = connection.apiClient {
                    PhoneOfflineBlatt(
                        modell: PhoneOfflineBlattModell(
                            quelle: kind, targetId: targetId, titel: titel,
                            wahl: OfflineWahlSpeicher().wahl(fuer: pinId) ?? PhoneOfflineModel.vorgabeWahl,
                            freierPlatz: PhoneOfflineBlattModell.freierPlatz()),
                        apiClient: apiClient
                    ) { wahl in
                        speichere(wahl, apiClient: apiClient)
                    }
                }
            }
    }

    private func speichere(_ wahl: OfflineWahl, apiClient: ImmichAPIClient) {
        let modell = PhoneOfflineModel()
        switch kind {
        case .favoriten:
            modell.setzeFavoriten(true, wahl: wahl, context: modelContext, apiClient: apiClient)
        case .person:
            modell.nimmOffline(person: targetId, name: titel, wahl: wahl, context: modelContext, apiClient: apiClient)
        case .album, .smartAlbum, .zuletzt:
            break
        }
    }
}

extension View {
    func offlineQuelleKnopf(kind: OfflinePinKind, targetId: String, titel: String) -> some View {
        modifier(PhoneOfflineQuelleKnopf(kind: kind, targetId: targetId, titel: titel))
    }
}
