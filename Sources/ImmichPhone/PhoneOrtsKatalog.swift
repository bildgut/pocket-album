import Foundation

/// Ein Chip mit Anzahl — Stadt, Jahr oder Person. Ein Typ für alle drei Reihen,
/// damit `PhoneChipReihe` nur einen kennt.
struct PhoneOrtsChip: Identifiable, Hashable, Sendable, Codable {
    /// Stadtname, Jahreszahl als Text oder Personen-ID.
    let id: String
    let titel: String
    let anzahl: Int
}

struct PhoneOrtsLand: Identifiable, Hashable, Sendable, Codable {
    let name: String
    /// `nil`, wenn der Schlüssel `asset.statistics` nicht hat — dann zeigt die
    /// Ansicht keine Zahl, statt das Land zu verwerfen.
    var anzahl: Int?
    /// `localDateTime` des jüngsten Fotos („2025-11-24T08:10:23.000Z"); `nil`, wenn
    /// die Sondierung scheiterte oder das Land nur ein Platzhalter ist.
    var zuletzt: String?
    var titelbildId: String?
    var staedte: [String]
    var regionen: [String]

    var id: String { name }
}

/// Der gespeicherte Ortskatalog — siehe
/// `docs/superpowers/specs/2026-09-12-ios-orte-tab-design.md`, „Der Ortskatalog".
struct PhoneOrtsKatalog: Hashable, Sendable, Codable {
    static let aktuelleVersion = 1
    /// Älter als das → der Reiter frischt beim Öffnen im Hintergrund auf.
    static let maxAlter: TimeInterval = 15 * 60

    var version: Int = PhoneOrtsKatalog.aktuelleVersion
    /// Für welchen Server (`baseURL.absoluteString`). `disconnect()` räumt keine
    /// Caches ab — ohne diese Angabe sähe eine Anmeldung an einem anderen Server
    /// die Orte des vorigen.
    var basis: String
    var laender: [PhoneOrtsLand]
    /// Zeitpunkt des letzten **vollständigen** Laufs. `nil` nach einem Teilausfall:
    /// Dann gilt der Katalog nie als frisch, und die nächste Öffnung versucht es neu.
    var aufgebautAm: Date?
    /// Land → gezählte Städte, nach Anzahl absteigend. Gefüllt beim Öffnen eines
    /// Landes, nicht beim Aufbau — und beim Neuaufbau **verworfen**, sonst blieben
    /// die Zahlen für immer auf dem Stand des ersten Öffnens.
    var staedteAnzahlen: [String: [PhoneOrtsChip]] = [:]

    func istFrisch(jetzt: Date) -> Bool {
        guard let aufgebautAm else { return false }
        return jetzt.timeIntervalSince(aufgebautAm) < Self.maxAlter
    }

    /// Jüngstes Foto zuerst. ISO-Zeitstempel desselben Formats lassen sich als Text
    /// vergleichen. Länder ohne Datum stehen hinter allen bekannten — ein fehlendes
    /// Datum darf nicht als „1970" mitten in die Reihenfolge rutschen.
    var nachZuletzt: [PhoneOrtsLand] {
        laender.sorted { a, b in
            switch (a.zuletzt, b.zuletzt) {
            case let (x?, y?): x != y ? x > y : a.name < b.name
            case (.some, .none): true
            case (.none, .some): false
            case (.none, .none): a.name < b.name
            }
        }
    }

    func land(_ name: String) -> PhoneOrtsLand? {
        laender.first { $0.name == name }
    }
}
