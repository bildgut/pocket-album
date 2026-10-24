import Foundation

/// Reihenfolge der Personenauswahl für „Offline speichern“.
enum PhonePersonenSortierung: String, CaseIterable, Identifiable {
    case haeufigkeit, name

    var id: String { rawValue }

    var titel: String {
        switch self {
        case .haeufigkeit: String(localized: "Most Photos")
        case .name: String(localized: "Name")
        }
    }

    /// Unbenannte (nur Leerraum) fallen weg. `.haeufigkeit` behält die
    /// Server-Reihenfolge unverändert (`/api/people` sortiert selbst nach `faceCount`),
    /// `.name` sortiert mit `localizedStandardCompare`. `suche` (getrimmt, leer = alles)
    /// filtert nach dem Sortieren, die Reihenfolge bleibt.
    static func personen(_ vomServer: [Person], sortierung: Self, suche: String) -> [Person] {
        let benannt = vomServer.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
        let sortiert = switch sortierung {
        case .haeufigkeit: benannt
        case .name: benannt.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        let text = suche.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? sortiert : sortiert.filter { $0.name.localizedCaseInsensitiveContains(text) }
    }
}
