import Foundation

/// Die offline gespeicherten Personen für „Entdecken“ ohne Netz. Die Personenreihe
/// dort ist offline gesperrt, weil ein Tipp den Server fragt — gespeicherte
/// Personen waren so im Flugmodus unerreichbar, obwohl ihre Fotos auf dem iPhone
/// lagen (Gerätebefund 26.10.2026). Reiner Wertetyp, liest nur Vermerke.
enum PhoneOfflinePersonen {
    struct Eintrag: Identifiable, Equatable {
        let id: String
        let name: String
        let anzahl: Int
    }

    static func eintraege(aus pins: [OfflinePin]) -> [Eintrag] {
        pins.filter { $0.kind == .person }
            .map { Eintrag(id: $0.targetId, name: $0.displayName, anzahl: $0.assetIds.count) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
