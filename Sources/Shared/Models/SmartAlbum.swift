import Foundation
import SwiftData

// MARK: - Match Mode

enum SmartAlbumMatchMode: String, Codable, CaseIterable {
    case all = "all"   // AND — alle Regeln müssen passen
    case any = "any"   // OR  — mindestens eine Regel muss passen

    var label: String {
        switch self {
        case .all: return "allen"
        case .any: return "einer"
        }
    }
}

// MARK: - Sort Order

enum SmartAlbumSortOrder: String, Codable, CaseIterable {
    case dateDesc  = "dateDesc"
    case dateAsc   = "dateAsc"
    case nameAsc   = "nameAsc"

    var label: String {
        switch self {
        case .dateDesc: return "Datum ↓"
        case .dateAsc:  return "Datum ↑"
        case .nameAsc:  return "Name A–Z"
        }
    }
}

// MARK: - Rule Entry (rule + optional negation)

/// Wraps a ``SmartAlbumRule`` with an optional negation flag.
/// When `isNegated == true` the rule must *not* match for an asset to pass.
struct SmartAlbumRuleEntry: Codable, Equatable, Identifiable {
    var rule: SmartAlbumRule
    var isNegated: Bool

    /// Laufzeit-Identität für den Editor. Nicht im JSON, nicht in der Gleichheit:
    /// Die Zeilen des Editors liefen über `rules.indices`, und beim Entfernen einer
    /// Regel griff SwiftUI noch einmal mit dem alten Index zu — Absturz außerhalb des
    /// Arrays. Zwei inhaltlich gleiche Regeln müssen trotzdem zwei Zeilen sein.
    let id = UUID()

    private enum CodingKeys: String, CodingKey { case rule, isNegated }

    init(_ rule: SmartAlbumRule, negated: Bool = false) {
        self.rule = rule
        self.isNegated = negated
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.rule == rhs.rule && lhs.isNegated == rhs.isNegated
    }

    /// Human-readable label shown in the editor row.
    var displayLabel: String {
        isNegated ? "Nicht: \(rule.displayLabel)" : rule.displayLabel
    }

    var iconName: String { rule.iconName }
}

// MARK: - Rules

/// A single filter rule inside a Smart Album.
/// Stored as JSON in the SwiftData model.
enum SmartAlbumRule: Codable, Equatable {

    // ── Zeit ─────────────────────────────────────────────────
    case dateRange(from: Date, to: Date)
    case lastXDays(Int)              // rollendes Fenster: heute − X Tage bis heute
    case monthOfYear(month: Int)     // 1 = Januar … 12 = Dezember
    case yearIs(year: Int)

    // ── Person ───────────────────────────────────────────────
    case containsPerson(id: String, name: String)

    // ── Ort ──────────────────────────────────────────────────
    case city(String)
    case country(String)
    case hasLocation
    /// Bewusst ein eigener Fall statt `hasLocation` mit Negation: `Nicht: Hat GPS`
    /// bedeutet wörtlich `!(latitude != nil)` und schlösse damit jedes Asset ein,
    /// dessen EXIF nie vom Server geholt wurde. Als eigener Fall trägt die Regel
    /// die konservative Semantik in sich (siehe SmartAlbumEvaluator).
    case hasNoLocation

    // ── Kamera / EXIF ────────────────────────────────────────
    case cameraModel(String)
    case fNumberMax(Double)          // max Blende, z.B. 2.0 → f/2.0
    case isoMin(Int)
    /// Weder Hersteller noch Modell — typisch für Web-Downloads und Messenger-Bilder.
    case hasNoCameraInfo
    /// Obergrenze der Dateigröße in Kilobyte.
    case fileSizeMaxKB(Int)

    // ── Typ & Status ─────────────────────────────────────────
    case assetTypeIs(AssetType)
    case isFavorite
    case isRAW
    case isScreenshot
    case isPanorama
    case isStacked          // Asset gehört zu einem Stack (Original + Bearbeitungen)
    /// Dateiendung ohne Punkt, klein geschrieben — "webp", "gif", "png".
    case fileExtensionIs(String)
    /// Pauschale Heuristik, siehe ``WebOriginDetector``.
    case isWebOrMessenger
    /// Asset gehört zu keinem einzigen Album (eigene + geteilte). Ausgewertet gegen den
    /// lokalen ``AlbumMembershipStore`` — bewusst ohne Server-Filter (`isNotInAlbum`),
    /// weil ein gespiegeltes Smart Album selbst ein Album ist und der Server-Filter die
    /// gerade eingespiegelten Assets beim nächsten Lauf wieder ausschlösse (Oszillieren).
    /// Lokal wird das eigene Spiegel-Album stattdessen vom Zählen ausgenommen.
    case isInNoAlbum

    // MARK: Human-readable label (für Editor)
    var displayLabel: String {
        switch self {
        case .dateRange(let from, let to):
            let fmt = DateFormatter()
            fmt.dateStyle = .medium
            fmt.timeStyle = .none
            // Offene Seiten aus „seit 2020"/„bis 2018" — sonst stünde hier das Jahr 4001.
            if from == .distantPast { return "bis \(fmt.string(from: to))" }
            if to == .distantFuture { return "seit \(fmt.string(from: from))" }
            return "\(fmt.string(from: from)) – \(fmt.string(from: to))"
        case .lastXDays(let x):
            return "Letzte \(x) Tage"
        case .monthOfYear(let m):
            let fmt = DateFormatter()
            fmt.dateFormat = "MMMM"
            let date = Calendar.current.date(from: DateComponents(month: m)) ?? Date()
            return "Monat = \(fmt.string(from: date))"
        case .yearIs(let y):
            return "Jahr = \(y)"
        case .containsPerson(_, let name):
            return "Person: \(name)"
        case .city(let c):
            return "Stadt: \(c)"
        case .country(let c):
            return "Land: \(c)"
        case .hasLocation:
            return "Hat GPS-Daten"
        case .cameraModel(let m):
            return "Kamera: \(m)"
        case .fNumberMax(let f):
            return "Blende ≤ f/\(String(format: "%.1f", f))"
        case .isoMin(let i):
            return "ISO ≥ \(i)"
        case .assetTypeIs(let t):
            return t == .image ? "Nur Fotos" : "Nur Videos"
        case .isFavorite:
            return "Favorit"
        case .isRAW:
            return "RAW-Datei"
        case .isScreenshot:
            return "Bildschirmfoto"
        case .isPanorama:
            return "Panorama"
        case .isStacked:
            return "Hat Bearbeitungen (Stack)"
        case .hasNoLocation:
            return "Kein GPS"
        case .hasNoCameraInfo:
            return "Keine Kamera-Daten"
        case .fileSizeMaxKB(let kb):
            return "Datei ≤ \(kb) KB"
        case .fileExtensionIs(let ext):
            return "Endung: \(ext.lowercased())"
        case .isWebOrMessenger:
            return "Aus Web/Messenger"
        case .isInNoAlbum:
            return "In keinem Album"
        }
    }

    var iconName: String {
        switch self {
        case .dateRange, .lastXDays, .monthOfYear, .yearIs:   return "calendar"
        case .containsPerson:                      return "person.fill"
        case .city, .country, .hasLocation:        return "location.fill"
        case .cameraModel:                         return "camera.fill"
        case .fNumberMax:                          return "camera.aperture"
        case .isoMin:                              return "sensor.tag.radiowaves.forward.fill"
        case .assetTypeIs(let t):
            return t == .image ? "photo" : "video.fill"
        case .isFavorite:                          return "heart.fill"
        case .isRAW:                               return "r.square.fill"
        case .isScreenshot:                        return "camera.viewfinder"
        case .isPanorama:                          return "pano.fill"
        case .isStacked:                           return "photo.stack.fill"
        case .hasNoLocation:                       return "location.slash"
        case .hasNoCameraInfo:                     return "camera.badge.ellipsis"
        case .fileSizeMaxKB:                       return "doc.badge.arrow.up"
        case .fileExtensionIs:                     return "doc.text"
        case .isWebOrMessenger:                    return "globe"
        case .isInNoAlbum:                         return "rectangle.stack.badge.minus"
        }
    }
}

// MARK: - Spiegel-Alben

extension SmartAlbum {

    /// IDs aller Immich-Alben, die als Spiegel eines Smart Albums entstanden sind.
    ///
    /// Für jede Frage nach „in keinem Album" die Ausschlussliste: Diese Alben stehen
    /// zwar auf dem Server, sind aber automatisch aus Regeln erzeugt — wer ein Foto
    /// dort findet, hat es nicht einsortiert. Betrifft den Filter „Nur ohne Album"
    /// wie die Regel ``SmartAlbumRule/isInNoAlbum`` gleichermaßen; liefen die beiden
    /// hier auseinander, zeigten Mediathek und Smart Album verschiedene Fotos.
    ///
    /// Wird ein Smart Album gelöscht und sein Spiegel auf dem Server behalten, fällt
    /// es aus dieser Liste — von da an ist es ein gewöhnliches Album und zählt wieder
    /// als Ablage. Das ist beabsichtigt: Ohne das Smart Album pflegt es niemand mehr
    /// automatisch.
    static func mirroredServerAlbumIds(in context: ModelContext) -> Set<String> {
        let albums = (try? context.fetch(FetchDescriptor<SmartAlbum>())) ?? []
        return Set(albums.compactMap(\.mirrorAlbumId))
    }
}

// MARK: - Person-ID Rewrite (nach Personen-Merge)

extension SmartAlbumRule {
    /// Person-ID, falls dies eine ``containsPerson(id:name:)``-Regel ist — sonst `nil`.
    var personId: String? {
        if case .containsPerson(let id, _) = self { return id }
        return nil
    }
}

extension Array where Element == SmartAlbumRuleEntry {

    /// Schreibt alle ``SmartAlbumRule/containsPerson(id:name:)``-Regeln, die auf eine der
    /// `sourceIds` zeigen, auf `targetId` um — und entfernt dabei entstehende Duplikate.
    ///
    /// Hintergrund: Nach einem Personen-Merge auf dem Server existieren die Quell-IDs nicht
    /// mehr. Ein Smart Album mit einer Regel darauf liefert sonst stillschweigend keine
    /// Treffer — ohne Fehler, ohne Hinweis.
    ///
    /// Dedupliziert wird ausschließlich über Personen-Regeln, Schlüssel
    /// `(personId, isNegated)`; der erste Treffer gewinnt, die Reihenfolge bleibt erhalten.
    /// Andere Regeltypen bleiben unangetastet — sie zu deduplizieren würde Verhalten ändern,
    /// das mit dem Merge nichts zu tun hat.
    ///
    /// `Person X` und `Nicht: Person X` sind bewusst **keine** Duplikate. Fallen sie durch
    /// das Umschreiben zusammen, bleibt der Widerspruch im Regel-Editor sichtbar, statt dass
    /// eine der beiden Regeln still verschwindet.
    ///
    /// - Parameters:
    ///   - sourceIds: IDs der zusammengeführten Quell-Personen.
    ///   - targetId: ID der Zielperson, die den Merge überlebt hat.
    ///   - targetName: Anzeigename der Zielperson. `nil` behält den bisher in der Regel
    ///     gespeicherten Namen bei.
    func rewritingPersonIds(
        from sourceIds: Set<String>,
        to targetId: String,
        targetName: String?
    ) -> [SmartAlbumRuleEntry] {
        guard !sourceIds.isEmpty else { return self }

        var result: [SmartAlbumRuleEntry] = []
        result.reserveCapacity(count)
        var seenPersonKeys = Set<String>()

        for var entry in self {
            if case .containsPerson(let id, let name) = entry.rule, sourceIds.contains(id) {
                entry.rule = .containsPerson(id: targetId, name: targetName ?? name)
            }
            if let personId = entry.rule.personId {
                // Person-IDs sind UUIDs, das "!"-Präfix kann darum nicht kollidieren.
                let key = "\(entry.isNegated ? "!" : "")\(personId)"
                guard seenPersonKeys.insert(key).inserted else { continue }
            }
            result.append(entry)
        }
        return result
    }
}

// MARK: - Mirror Sync Status

enum MirrorSyncStatus: String, Codable {
    case idle       // Noch nie synchronisiert
    case syncing    // Läuft gerade
    case upToDate   // Letzter Sync war erfolgreich, nichts zu tun
    case error      // Letzter Sync ist fehlgeschlagen

    var icon: String {
        switch self {
        case .idle:      return "arrow.triangle.2.circlepath"
        case .syncing:   return "arrow.triangle.2.circlepath"
        case .upToDate:  return "checkmark.circle.fill"
        case .error:     return "exclamationmark.triangle.fill"
        }
    }

    var color: String {   // Als String damit Codable einfach bleibt
        switch self {
        case .idle:      return "secondary"
        case .syncing:   return "blue"
        case .upToDate:  return "green"
        case .error:     return "orange"
        }
    }
}

// MARK: - SwiftData Model

@Model
final class SmartAlbum {

    @Attribute(.unique) var id: UUID
    var name: String
    var iconSymbol: String          // SF Symbol name
    var matchModeRaw: String        // SmartAlbumMatchMode.rawValue
    var sortOrderRaw: String        // SmartAlbumSortOrder.rawValue
    var rulesData: Data             // JSON-encoded [SmartAlbumRule]
    var createdAt: Date

    // MARK: - Folder & Sort
    /// ID des lokalen ``SmartAlbumFolder``, dem dieses Album zugeordnet ist. Nil = ungroupiert.
    var folderID: UUID?
    /// Reihenfolge innerhalb des Ordners (oder in der ungroupierten Liste).
    var sortIndex: Int = 0

    // MARK: - Server Mirror (Phase 2)
    /// ID des gespiegelten Immich-Albums auf dem Server. Nil = kein Spiegel.
    var mirrorAlbumId: String?
    /// Zeitstempel des letzten erfolgreichen Mirror-Syncs.
    var mirrorLastSyncedAt: Date?
    /// Zuletzt gesyncte Asset-IDs — gecachter "ist"-Stand, vermeidet unnötige GET-Calls.
    var mirrorLastSyncedIdsData: Data?  // JSON-encoded [String]
    /// Status des letzten Sync-Versuchs (raw MirrorSyncStatus).
    var mirrorSyncStatusRaw: String?
    /// Fehlermeldung wenn mirrorSyncStatusRaw == "error"
    var mirrorLastError: String?

    var mirrorSyncStatus: MirrorSyncStatus {
        get { MirrorSyncStatus(rawValue: mirrorSyncStatusRaw ?? "") ?? .idle }
        set { mirrorSyncStatusRaw = newValue.rawValue }
    }

    var mirrorLastSyncedIds: Set<String> {
        get {
            guard let data = mirrorLastSyncedIdsData,
                  let ids = try? JSONDecoder().decode([String].self, from: data)
            else { return [] }
            return Set(ids)
        }
        set {
            mirrorLastSyncedIdsData = try? JSONEncoder().encode(Array(newValue))
        }
    }

    var isMirrored: Bool { mirrorAlbumId != nil }

    // MARK: - Typed accessors (not persisted directly)

    var matchMode: SmartAlbumMatchMode {
        get { SmartAlbumMatchMode(rawValue: matchModeRaw) ?? .all }
        set { matchModeRaw = newValue.rawValue }
    }

    var sortOrder: SmartAlbumSortOrder {
        get { SmartAlbumSortOrder(rawValue: sortOrderRaw) ?? .dateDesc }
        set { sortOrderRaw = newValue.rawValue }
    }

    var rules: [SmartAlbumRuleEntry] {
        get {
            // Try new format first
            if let entries = try? JSONDecoder().decode([SmartAlbumRuleEntry].self, from: rulesData) {
                return entries
            }
            // Migrate legacy format ([SmartAlbumRule] without negation wrapper)
            if let legacy = try? JSONDecoder().decode([SmartAlbumRule].self, from: rulesData) {
                return legacy.map { SmartAlbumRuleEntry($0) }
            }
            return []
        }
        set {
            // Scheitert das Kodieren, bleiben die **alten** Regeln stehen.
            //
            // Zuvor stand hier `?? Data()`: Ein Fehlschlag überschrieb die Regeln des
            // Albums mit einem leeren Rumpf, der Getter lieferte danach `[]`, und die
            // Regeln waren weg — ohne Meldung, ohne Wiederherstellung.
            //
            // Herbeiführbar ist das über jeden nicht-endlichen `Double`:
            // `JSONEncoder` wirft dafür in seiner Voreinstellung, und `fNumberMax`
            // trägt einen. Ein halb eingegebener Wert im Editor genügt also im
            // ungünstigen Fall.
            //
            // Ein Album ohne Regeln ist zudem kein harmloser Zustand: Es trifft auf
            // nichts (siehe `SmartAlbumEvaluator.evaluate`), und beim Spiegeln wäre
            // das früher „räum das Album auf dem Server leer" gewesen — davor steht
            // inzwischen ein eigenes Tor im `SmartAlbumMirrorService`.
            guard let encoded = try? JSONEncoder().encode(newValue) else {
                AppLogger.app.error(
                    "SmartAlbum '\(self.name)': Regeln ließen sich nicht kodieren — die bisherigen bleiben erhalten."
                )
                return
            }
            rulesData = encoded
        }
    }

    // MARK: - Init

    init(
        id: UUID = UUID(),
        name: String,
        iconSymbol: String = "wand.and.stars",
        matchMode: SmartAlbumMatchMode = .all,
        sortOrder: SmartAlbumSortOrder = .dateDesc,
        rules: [SmartAlbumRuleEntry] = []
    ) {
        self.id = id
        self.name = name
        self.iconSymbol = iconSymbol
        self.matchModeRaw = matchMode.rawValue
        self.sortOrderRaw = sortOrder.rawValue
        self.rulesData = (try? JSONEncoder().encode(rules)) ?? Data()
        self.createdAt = Date()
        self.folderID = nil
        self.sortIndex = 0
    }
}
