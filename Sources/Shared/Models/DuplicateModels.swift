import Foundation

// Wertetypen der Duplikatsuche. Bewusst ohne SwiftData, SwiftUI und SQLite:
// der Matcher (`DuplicateMatcher`) arbeitet allein auf diesen Typen und ist damit
// ohne Datenbank und ohne Netz testbar. Vorbild: `GeoSuggestion.swift`.

// MARK: - Eingabe

/// Eine Zeile der Duplikatsuche — Erkennung und Keeper-Bewertung in einem.
///
/// Bewusst kein `Asset`: über 155.000 Zeilen kostet dessen Aufbau samt
/// verschachteltem `ExifInfo` zig Megabyte. Umgekehrt trägt diese Zeile mehr als
/// `GeoScanRow`, weil die Keeper-Wahl sonst für jede Gruppe nachladen müsste —
/// und die Wahl steht schon fest, bevor die erste Kachel sichtbar ist.
struct DupeScanRow: Sendable, Equatable, Identifiable {
    let id: String
    let type: AssetType
    /// Aufnahmezeit als Unix-Sekunden. `Int` statt `Date`, weil der Matcher nur
    /// Differenzen bildet und über Millionen Vergleiche läuft.
    let timestamp: Int
    let fileName: String
    let fileSize: Int?
    let width: Int?
    let height: Int?
    /// Einmal beim Laden aus Base64 dekodiert. `nil`, wenn der Server keinen
    /// Thumbhash liefert oder er sich nicht lesen ließ.
    let thumbhash: [UInt8]?
    let durationMs: Int?
    let isFavorite: Bool
    let hasCoordinates: Bool
    /// 0…1, Anteil der belegten EXIF-Felder. Fließt in die Keeper-Wahl ein.
    let exifCompleteness: Double
    /// Server-Checksum (SHA-1) aus dem Sync-Stream. `nil`, solange der Backfill
    /// die Zeile noch nicht erreicht hat oder der Polling-Pfad sie ohne
    /// Checksum angelegt hat.
    let checksum: String?

    /// Seitenverhältnis, `nil` wenn die Maße fehlen.
    var aspectRatio: Double? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return Double(width) / Double(height)
    }

    var megapixels: Double? {
        guard let width, let height else { return nil }
        return Double(width * height) / 1_000_000
    }

    /// Die drei Werte, die zusammen den fehlenden `checksum` ersetzen.
    ///
    /// Gleiche Bytezahl **und** gleiche Maße **und** gleicher Typ trifft bei
    /// natürlichen Fotos praktisch nie zufällig zusammen — das ist die
    /// belastbarste lokale Aussage über Dateigleichheit, die ohne Netz zu
    /// bekommen ist. `nil`, solange eine der Angaben fehlt: raten wäre hier
    /// teurer als nicht finden.
    var identityKey: String? {
        guard let fileSize, let width, let height else { return nil }
        return "\(type.rawValue)|\(fileSize)|\(width)x\(height)"
    }
}

/// Was der Grid-Index für einen Scan liefert.
///
/// Die Zähler gehören zum Ergebnis, damit die Oberfläche eine Lücke benennen
/// kann, statt sie stillschweigend zu unterschlagen.
struct DupeIndexSnapshot: Sendable {
    let rows: [DupeScanRow]
    /// Zeilen ohne lesbaren Thumbhash — für sie greifen nur die exakten Regeln.
    let rowsWithoutThumbhash: Int
    /// Zeilen ohne Dateigröße oder Maße — für sie entfällt die Identitätsregel.
    let rowsWithoutSize: Int
    /// Zeilen, deren `fileCreatedAt` sich nicht als Datum lesen ließ.
    let unparsableTimestampCount: Int
}

/// In welche Richtung gesucht wird.
enum DupeMode: String, Sendable, CaseIterable, Identifiable {
    /// Dasselbe Foto mehrfach in der Bibliothek — strenge Regeln.
    case exact
    /// Ähnliche, aber nicht identische Aufnahmen — Serien, mehrere Versuche.
    case similar

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .exact: return "Dubletten"
        case .similar: return "Ähnliche Aufnahmen"
        }
    }
}

/// Schränkt ein, welche Zeilen überhaupt in den Matcher einfließen. Anders als
/// `DupeConfidenceFilter`/die Ersparnis-Schwelle in `DuplicateCheckModel` ist
/// das kein reiner Anzeigefilter — ein Wechsel braucht einen echten Neu-Scan,
/// weil sich sonst die Paarbildung ändert.
enum DupeMediaTypeFilter: String, Sendable, CaseIterable, Identifiable {
    case alle, bild, video

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .alle: return "Alle"
        case .bild: return "Bilder"
        case .video: return "Videos"
        }
    }

    /// `AssetType.audio` und `.other` laufen unter `.alle` mit — sie sind in
    /// der Praxis verschwindend selten (Live-Photo-Videoteile u. Ä.) und
    /// bekommen keine eigene Filter-Option.
    func matches(_ type: AssetType) -> Bool {
        switch self {
        case .alle: return true
        case .bild: return type == .image
        case .video: return type == .video
        }
    }
}

/// Mindestschwelle für die Anzeige — blendet Gruppen unterhalb der gewählten
/// Verlässlichkeit aus `DuplicateCheckModel.groups` aus. Reiner Anzeigefilter,
/// löst **keinen** Neu-Scan aus.
enum DupeConfidenceFilter: String, Sendable, CaseIterable, Identifiable {
    case alle, abWahrscheinlich, nurSicher

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .alle: return "Alle"
        case .abWahrscheinlich: return "Ab Wahrscheinlich"
        case .nurSicher: return "Nur Sicher"
        }
    }

    /// Dieselben Schwellen wie `DupeConfidenceLabel` — bewusst dieselben Zahlen
    /// an zwei Stellen (dort für die Farbe/das Label der Karte, hier für den
    /// Filter), keine gemeinsame Konstante: Die beiden Stellen dürfen sich
    /// unabhängig weiterentwickeln, ohne dass eine Änderung an der einen die
    /// andere heimlich mitverschiebt.
    var minConfidence: Int {
        switch self {
        case .alle: return 0
        case .abWahrscheinlich: return 65
        case .nurSicher: return 85
        }
    }
}

/// Die einstellbaren Schrauben — sie wirken **nur** auf den Modus
/// „Ähnliche Aufnahmen".
///
/// Die Regeln für Dubletten sind bewusst nicht regelbar: Sie sollen bei jedem
/// Nutzer dasselbe finden, und ein aufgeweichter Schwellwert löscht dort echte
/// Fotos. Die Konstanten stehen in `DuplicateMatcher`.
struct DupeParameters: Sendable, Equatable {
    /// Höchster Thumbhash-Abstand, ab dem zwei Aufnahmen noch als ähnlich gelten.
    var similarityDistance: Int = 200
    /// Wie weit zwei ähnliche Aufnahmen zeitlich auseinanderliegen dürfen.
    var timeWindowSeconds: Int = 60
    /// Größe, ab der ein Bucket übersprungen wird — der Schutz gegen n².
    var maxBucketSize: Int = 200

    static let similarityRange = 60...400
    static let timeWindowRange = 2...600
}

// MARK: - Bewertung

/// Woran eine Gruppe erkannt wurde. Mehrere Gründe können zusammentreffen.
struct DupeMatchReason: OptionSet, Sendable, Hashable {
    let rawValue: Int

    /// Gleiche Bytezahl, gleiche Maße, gleicher Typ — der Fallback, wenn eine
    /// Checksum fehlt.
    static let identicalSizeAndDimensions = DupeMatchReason(rawValue: 1 << 0)
    /// Die Dateinamen gehen auf dieselbe Wurzel zurück.
    static let relatedFilename = DupeMatchReason(rawValue: 1 << 1)
    /// Die Vorschaubilder sind praktisch deckungsgleich.
    static let nearIdenticalThumbhash = DupeMatchReason(rawValue: 1 << 2)
    /// Die Aufnahmezeit stimmt auf die Sekunde überein.
    static let sameTimestamp = DupeMatchReason(rawValue: 1 << 3)
    /// Die Aufnahmen liegen im eingestellten Zeitfenster.
    static let closeInTime = DupeMatchReason(rawValue: 1 << 4)
    /// Dieselbe Server-Checksum — byte-identische Datei, die stärkste Aussage.
    static let identicalChecksum = DupeMatchReason(rawValue: 1 << 5)

    /// Kurzbegründungen für die Karte, in absteigender Aussagekraft.
    var summaries: [String] {
        var out: [String] = []
        if contains(.identicalChecksum) { out.append("identische Datei") }
        if contains(.identicalSizeAndDimensions) { out.append("gleiche Datei­größe und Maße") }
        if contains(.nearIdenticalThumbhash) { out.append("deckungsgleiche Vorschau") }
        if contains(.relatedFilename) { out.append("verwandter Dateiname") }
        if contains(.sameTimestamp) { out.append("identische Aufnahmezeit") }
        if contains(.closeInTime) { out.append("zeitlich benachbart") }
        return out
    }
}

/// Wie belastbar eine Gruppe ist. Aus `confidence` abgeleitet, damit Farbe und
/// Text an einer Stelle festliegen.
enum DupeConfidenceLabel: Sendable, Equatable {
    case sicher
    case wahrscheinlich
    case unsicher

    init(confidence: Int) {
        switch confidence {
        case 85...: self = .sicher
        case 65..<85: self = .wahrscheinlich
        default: self = .unsicher
        }
    }

    var displayName: String {
        switch self {
        case .sicher: return "Sicher"
        case .wahrscheinlich: return "Wahrscheinlich"
        case .unsicher: return "Unsicher"
        }
    }
}

// MARK: - Ergebnis

/// Eine Gruppe von Assets, die dasselbe Motiv zeigen.
struct DupeGroup: Sendable, Equatable, Identifiable {
    /// Stabiler Fingerabdruck über die enthaltenen Assets.
    let id: String
    let mode: DupeMode

    /// Alle Mitglieder, absteigend nach Keeper-Punkten sortiert — das erste
    /// Element ist damit immer `suggestedKeeperId`.
    let assetIds: [String]
    /// Vorschlag des Matchers. Die Ansicht darf ihn überstimmen.
    let suggestedKeeperId: String

    let reasons: DupeMatchReason
    /// 0…100.
    let confidence: Int
    let timeSpanSeconds: Int
    /// Was frei würde, wenn alle außer dem Keeper gingen.
    let reclaimableBytes: Int

    var label: DupeConfidenceLabel { DupeConfidenceLabel(confidence: confidence) }
    var count: Int { assetIds.count }

    /// Die Mitglieder, die bei diesem Keeper wegfielen.
    func loserIds(keeperId: String) -> [String] {
        assetIds.filter { $0 != keeperId }
    }

    /// Wie oben, aber auf eine vom Nutzer getroffene Auswahl eingeschränkt.
    ///
    /// Zwei Zusicherungen, die hier hingehören statt in die Ansicht:
    ///
    /// 1. **Der Keeper fällt immer heraus.** Die Detailansicht zeigt für ihn eine Krone
    ///    statt eines Häkchens und räumt die Auswahl beim Keeper-Wechsel auf — aber die
    ///    Liste, die am Ende an den Server geht, entsteht hier. Stünde der Keeper darin,
    ///    wanderte ausgerechnet das Exemplar in den Papierkorb, das bleiben sollte, und
    ///    die Gruppe wäre vollständig weg.
    /// 2. **Fremde Kennungen fallen heraus.** Was nicht zur Gruppe gehört, hat in ihrer
    ///    Löschliste nichts verloren.
    ///
    /// - Parameter selection: `nil` heißt „alle außer dem Keeper".
    func loserIds(keeperId: String, selection: [String]?) -> [String] {
        let mitglieder = Set(assetIds)
        return (selection ?? assetIds).filter { $0 != keeperId && mitglieder.contains($0) }
    }
}

/// Eine Gruppe, die eine Regel knapp gerissen hat.
///
/// Aufbewahrt, damit „nichts gefunden" und „gefunden und verworfen"
/// unterscheidbar bleiben — dieselbe Begründung wie bei `GeoScanResult`.
struct DupeSuppressedGroup: Sendable, Equatable, Identifiable {
    var id: String { group.id }
    let group: DupeGroup
    /// Klartext, woran es scheiterte, z. B. „Vorschau-Abstand 214 statt 200".
    let reason: String
}

/// Das vollständige Ergebnis eines Scans — beide Modi aus einem Durchlauf.
///
/// Ein Scan für beide Modi, damit die zwei Ansichten nie unterschiedliche
/// Bestände melden können.
struct DupeScanResult: Sendable {
    let exactGroups: [DupeGroup]
    let similarGroups: [DupeGroup]
    let suppressed: [DupeSuppressedGroup]

    let scannedRows: Int
    /// Kandidatenpaare vor der Schwellwertprüfung. Trägt den Leerzustand:
    /// „847 geprüft, keins ähnlich genug" statt bloß „nichts gefunden".
    let candidatePairCount: Int
    /// Buckets über `maxBucketSize`, die übersprungen wurden. Gezählt statt
    /// still verworfen — die Hinweiszeile nennt sie.
    let skippedOversizedBuckets: Int
    let rowsWithoutThumbhash: Int

    func groups(for mode: DupeMode) -> [DupeGroup] {
        switch mode {
        case .exact: return exactGroups
        case .similar: return similarGroups
        }
    }

    func suppressed(for mode: DupeMode) -> [DupeSuppressedGroup] {
        suppressed.filter { $0.group.mode == mode }
    }

    static let empty = DupeScanResult(
        exactGroups: [], similarGroups: [], suppressed: [],
        scannedRows: 0, candidatePairCount: 0,
        skippedOversizedBuckets: 0, rowsWithoutThumbhash: 0
    )
}

// MARK: - Umfang

/// Die Aufnahmen eines Albums, auf die ein Scan eingeschränkt wird.
///
/// Trägt den Namen mit, damit die Ansicht ihn zeigen kann, ohne das Album
/// nachzuschlagen — und die IDs als `Set`, weil der Filter über sechsstellige
/// Zeilenzahlen läuft.
struct DupeAlbumScope: Equatable, Sendable {
    let albumId: String
    let albumName: String
    let assetIds: Set<String>
}

/// Wie weit ein Album-Scan greift.
enum DupeReach: String, Sendable, CaseIterable, Identifiable {
    /// Gruppen entstehen ausschließlich aus Album-Aufnahmen.
    case withinAlbum
    /// Gruppen, die mindestens eine Album-Aufnahme enthalten — die Partner dürfen
    /// irgendwo in der Bibliothek stehen.
    case albumAgainstLibrary

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .withinAlbum: return "Nur im Album"
        case .albumAgainstLibrary: return "Album + Bibliothek"
        }
    }
}
