import Foundation

/// Die Offline-Wahl je Vermerk (`OfflinePin.pinId`) und die zuletzt getroffene.
///
/// Absichtlich in `UserDefaults` statt als Feld an `OfflinePin`: Eine
/// SwiftData-Schemaänderung bräuchte eine Migrationsstufe, und der Mac nutzt die
/// Wahl nicht. Fehlt ein Eintrag, lädt der Lader wie bisher Originale.
struct OfflineWahlSpeicher: @unchecked Sendable {
    static let schluessel = "offline.wahl.v1"
    static let letzteSchluessel = "offline.wahl.letzte.v1"

    let defaults: UserDefaults

    init(defaults: UserDefaults = AppEnvironment.defaults) {
        self.defaults = defaults
    }

    func wahl(fuer pinId: String) -> OfflineWahl? { alle()[pinId] }

    func setze(_ wahl: OfflineWahl, fuer pinId: String) {
        var neu = alle()
        neu[pinId] = wahl
        schreibe(neu)
        defaults.set(try? JSONEncoder().encode(wahl), forKey: Self.letzteSchluessel)
    }

    func entferne(pinId: String) {
        var neu = alle()
        guard neu.removeValue(forKey: pinId) != nil else { return }
        schreibe(neu)
    }

    /// Vorgabe für das nächste Blatt; ohne frühere Wahl der Standard.
    var letzte: OfflineWahl {
        defaults.data(forKey: Self.letzteSchluessel)
            .flatMap { try? JSONDecoder().decode(OfflineWahl.self, from: $0) } ?? OfflineWahl()
    }

    private func alle() -> [String: OfflineWahl] {
        defaults.data(forKey: Self.schluessel)
            .flatMap { try? JSONDecoder().decode([String: OfflineWahl].self, from: $0) } ?? [:]
    }

    private func schreibe(_ wahlen: [String: OfflineWahl]) {
        defaults.set(try? JSONEncoder().encode(wahlen), forKey: Self.schluessel)
    }
}
