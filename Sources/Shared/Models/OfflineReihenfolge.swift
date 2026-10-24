import Foundation

/// Die vom Nutzer gezogene Reihenfolge der Offline-Quellen — zugleich die
/// Ladereihenfolge (Spec `docs/superpowers/specs/2026-10-22-ios-offline-quellen-design.md`).
///
/// Eine Liste von `pinId`s in `UserDefaults`, kein Feld am ``OfflinePin``: So braucht
/// es keine Schemaänderung, und der Mac, der die Reihenfolge nie setzt, lädt
/// unverändert nach `pinnedAt`.
struct OfflineReihenfolge {
    static let schluessel = "offline.reihenfolge.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = AppEnvironment.defaults) {
        self.defaults = defaults
    }

    /// Gespeicherte IDs zuerst in ihrer Ordnung, Unbekanntes (neu angelegt, oder vom
    /// Mac) danach nach `pinnedAt`. IDs ohne Element fallen still weg. Ohne Schlüssel
    /// gilt die Vorgabe Favoriten → Letzte Tage → Personen → Alben; sie wird erst
    /// geschrieben, wenn der Nutzer zieht.
    func sortiert<T>(_ elemente: [T], pinId: (T) -> String, kind: (T) -> OfflinePinKind,
                     pinnedAt: (T) -> Date) -> [T] {
        let nachZeit = elemente.sorted { pinnedAt($0) < pinnedAt($1) }
        guard let gespeichert = defaults.stringArray(forKey: Self.schluessel) else {
            return nachZeit.sorted { Self.vorgabeRang(kind($0)) < Self.vorgabeRang(kind($1)) }
        }
        let rang = Dictionary(gespeichert.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let bekannt = nachZeit.filter { rang[pinId($0)] != nil }
            .sorted { rang[pinId($0)]! < rang[pinId($1)]! }
        return bekannt + nachZeit.filter { rang[pinId($0)] == nil }
    }

    func setze(_ pinIds: [String]) {
        defaults.set(pinIds, forKey: Self.schluessel)
    }

    /// Nach einem Ziehen in der Liste; `pinIds` ist die Reihenfolge **vor** dem Ziehen.
    func verschiebe(_ pinIds: [String], von quelle: IndexSet, nach ziel: Int) {
        var neu = pinIds
        let bewegt = quelle.map { neu[$0] }
        for index in quelle.sorted(by: >) { neu.remove(at: index) }
        let einfuegen = ziel - quelle.filter { $0 < ziel }.count
        neu.insert(contentsOf: bewegt, at: einfuegen)
        setze(neu)
    }

    /// `sorted` ist stabil, die `pinnedAt`-Ordnung innerhalb einer Art bleibt also.
    private static func vorgabeRang(_ kind: OfflinePinKind) -> Int {
        switch kind {
        case .favoriten:           return 0
        case .zuletzt:             return 1
        case .person:              return 2
        case .album, .smartAlbum:  return 3
        }
    }
}
