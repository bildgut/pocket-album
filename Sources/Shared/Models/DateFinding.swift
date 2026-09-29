import Foundation

// MARK: - Eingabe

/// Was der Grid-Index für einen Datums-Abgleich liefert.
///
/// Rein und ohne Verhalten — die gesamte Erkennung läuft über diesen Typ, damit die
/// Detektoren ohne SQLite, ohne Netz und ohne Uhr prüfbar bleiben.
struct DateScanRow: Sendable, Equatable, Identifiable {
    let id: String
    let timestamp: Date
    let originalFileName: String
    let cameraMake: String?
    let cameraModel: String?
    var latitude: Double? = nil
    var longitude: Double? = nil

    /// Schlüssel der Geräte-Kohorte.
    ///
    /// Voraussetzung dafür, dass das trägt: der Scan liefert nur Zeilen mit
    /// `exifCheckedAt IS NOT NULL`. Sonst sähe ein nie gefragtes Asset genauso aus
    /// wie eines ohne Kamera.
    var cameraKey: String {
        "\(cameraMake ?? "")|\(cameraModel ?? "")"
    }

    /// Anzeigename der Kamera, oder `nil` für „ohne Kameraangabe".
    var cameraLabel: String? {
        let parts = [cameraMake, cameraModel].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Ob die Aufnahme überhaupt eine Kamera nennt.
    ///
    /// Trennt in mehreren Detektoren die Fälle: eingescannte und heruntergeladene
    /// Dateien tragen keine Kamera — und genau bei ihnen ist der Zeitstempel häufig
    /// ein Rückfallwert statt einer Aufnahmezeit.
    var hasCamera: Bool {
        !(cameraMake ?? "").isEmpty || !(cameraModel ?? "").isEmpty
    }

    /// Dateiname ohne Endung, klein geschrieben — der Schlüssel für Zwillingssuche.
    var filenameStem: String {
        let stem = originalFileName.contains(".")
            ? String(originalFileName[..<originalFileName.lastIndex(of: ".")!])
            : originalFileName
        return stem.lowercased()
    }

    /// Die volle Sekunde des Zeitstempels — der Schlüssel für Blockbildung.
    var epochSecond: Int {
        Int(timestamp.timeIntervalSince1970.rounded(.down))
    }
}

/// Was ein Durchlauf des Grid-Index geliefert hat.
struct DateIndexSnapshot: Sendable {
    let rowsById: [String: DateScanRow]
    /// Sichtbare Zeilen, die mangels `exifCheckedAt` nicht beurteilbar sind.
    let unknownExifIds: Set<String>
}

/// Woran ein Versatz der Form nach erinnert.
///
/// Reine Formbeschreibung, keine Diagnose: „sieht aus wie eine Zeitzone" heißt
/// nicht, dass es eine ist.
enum DateOffsetShape: Sendable, Equatable {
    /// Vielfaches einer halben Stunde, höchstens 14 Stunden — die Form jeder realen
    /// Zeitzonenverschiebung.
    case timezone(hours: Double)
    /// Nahe an ganzen Tagen.
    case days(Int)
    /// Über ein Jahr. Meist ein Rückfallwert oder ein nie gestelltes Kameradatum.
    case years(Double)
    case other
}

// MARK: - Reparatur

/// Was ein Befund mit den betroffenen Aufnahmen tun würde.
///
/// Der Typ trägt eine Entscheidung, die sonst nur Disziplin wäre: ein
/// Platzhalter-Block hat **keinen** gemeinsamen Versatz, weil die echten Zeiten
/// verloren sind und je Aufnahme einzeln wiederbeschafft werden müssen. Dass A2
/// niemals `.uniformOffset` liefern kann, erzwingt hier der Compiler.
enum DateRepair: Sendable, Equatable {
    /// Ein Versatz für alle Aufnahmen des Befunds. Nur B und C.
    case uniformOffset(TimeInterval)
    /// Je Aufnahme ein absoluter Ersatzzeitpunkt.
    ///
    /// Die Schlüssel sind eine **Teilmenge** von `assetIds`: Aufnahmen ohne belegtes
    /// Ersatzdatum bleiben im Befund sichtbar, werden aber nicht geschrieben.
    case perAssetInstants([String: DateInstant])
    /// Der Befund existiert, damit man ihn sieht — geschrieben wird nichts.
    case listingOnly
}

/// Ein Ersatzzeitpunkt, wie genau er bekannt ist und worauf er sich bezieht.
///
/// Beide Angaben gehören an den Wert, nicht in die Oberfläche.
///
/// Die **Genauigkeit**, weil ein aus `Norman_Geburtstag_25_03_2005` gelesenes Datum
/// den Tag kennt und nicht die Uhrzeit — als bloßes `Date` getarnt sähe 12:00 wie
/// eine Messung aus.
///
/// Der **Bezug**, weil ein Dateiname eine *Wanduhrzeit* nennt (`VID_20250825_131112`
/// war 13:11 Uhr dort, wo gefilmt wurde) und ein Dateinamens-Zwilling einen echten
/// *Zeitpunkt* (dieselbe Aufnahme, andere Kopie). Beide gleich zu behandeln
/// verschöbe die eine Sorte um den Zeitzonenversatz.
struct DateInstant: Sendable, Equatable {

    enum Precision: Sendable, Equatable {
        /// Datum **und** Uhrzeit sind belegt.
        case exact
        /// Nur der Tag ist belegt; die Uhrzeit ist auf 12:00 gesetzt.
        case dayOnly
    }

    enum Anchor: Sendable, Equatable {
        /// `instant` trägt eine Wanduhrzeit, in UTC-Feldern abgelegt. Sie soll am
        /// Bild genau so ablesbar sein, wie sie hier steht — der UTC-Versatz des
        /// Bildes bleibt dabei stehen.
        case wallClock
        /// `instant` ist ein echter Zeitpunkt, von einer anderen Aufnahme übernommen.
        case absolute
    }

    let instant: Date
    let precision: Precision
    let anchor: Anchor

    /// Die Aufnahme, von der dieser Zeitpunkt stammt — bei einem
    /// Dateinamens-Zwilling.
    ///
    /// Wichtig für den Schreibpfad: `instant` kommt hier aus dem Grid-Index, der
    /// `fileCreatedAt` führt. Geschrieben wird aber `dateTimeOriginal`, und beide
    /// sind nicht dasselbe. Wo diese ID gesetzt ist, holt das ViewModel den echten
    /// Wert vom Server, statt den Indexwert einzubacken.
    var sourceAssetId: String? = nil

    var isDayOnly: Bool { precision == .dayOnly }

    /// Wie der Wert dem Menschen gezeigt wird.
    ///
    /// Eine Wanduhrzeit muss in UTC gelesen werden — dort stehen ihre Felder. Ein
    /// echter Zeitpunkt in der Zeitzone des Betrachters, wie überall sonst.
    var displayTimeZone: TimeZone {
        anchor == .wallClock ? (TimeZone(identifier: "UTC") ?? .gmt) : .current
    }
}

// MARK: - Befund

/// Ein Befund: für diese Aufnahmen gibt es einen benennbaren Beweis, dass der
/// gespeicherte Zeitstempel nicht die Aufnahmezeit ist.
///
/// Das Album kommt hier bewusst nicht mehr vor. Die Vorgängerfassung nahm die
/// Albumzugehörigkeit als Behauptung „das gehört zeitlich zusammen" und maß dann
/// nur noch den Abstand zweier Mediane. An der echten Bibliothek erzeugte das 28
/// Vorschläge, die Aufnahmen von einem Tag eines mehrtägigen Albums auf einen
/// anderen Tag **desselben** Albums schoben. Kein Detektor ist darum noch
/// albumbezogen.
struct DateFinding: Sendable, Equatable, Identifiable {
    let id: String
    let kind: DateFindingKind
    /// Betroffene Aufnahmen, chronologisch und dedupliziert.
    let assetIds: [String]
    /// Parallel zu `assetIds`.
    let timestamps: [Date]
    let repair: DateRepair
    /// Was als Beleg dient: bei B die verzahnenden Fremdkamera-Aufnahmen, bei A die
    /// Spender, bei C leer.
    let referenceIds: [String]
    let referenceTimestamps: [Date]

    /// Überschrift der Karte.
    let title: String

    /// Die Aufnahmen, für die tatsächlich etwas geschrieben würde.
    var writableIds: [String] {
        switch repair {
        case .uniformOffset:
            return assetIds
        case .perAssetInstants(let map):
            // Reihenfolge aus `assetIds`, nicht aus dem Dictionary — sonst hinge die
            // Anzeige an der Hash-Reihenfolge.
            return assetIds.filter { map[$0] != nil }
        case .listingOnly:
            return []
        }
    }

    var writableCount: Int { writableIds.count }

    /// Ob der Befund überhaupt etwas zu schreiben hat.
    var isActionable: Bool { !writableIds.isEmpty }

    /// Der Versatz, falls es einen gemeinsamen gibt.
    var uniformOffset: TimeInterval? {
        if case .uniformOffset(let offset) = repair { return offset }
        return nil
    }

    /// Ersatzzeitpunkt einer einzelnen Aufnahme.
    func instant(for assetId: String) -> DateInstant? {
        if case .perAssetInstants(let map) = repair { return map[assetId] }
        return nil
    }

    /// Derselbe Befund, beschränkt auf die genannten Aufnahmen.
    ///
    /// Die Entdopplung braucht das: überschneiden sich zwei Befunde, behält der
    /// spezifischere die gemeinsamen Aufnahmen und der andere schrumpft. Timestamps
    /// und Ersatzzeitpunkte müssen dabei mitschrumpfen, sonst zeigte die Oberfläche
    /// Zeiten zu Aufnahmen, die gar nicht mehr dazugehören.
    func retaining(_ keep: Set<String>) -> DateFinding {
        var ids: [String] = []
        var times: [Date] = []
        for (index, id) in assetIds.enumerated() where keep.contains(id) {
            ids.append(id)
            times.append(timestamps[index])
        }

        let reducedRepair: DateRepair
        switch repair {
        case .uniformOffset, .listingOnly:
            reducedRepair = repair
        case .perAssetInstants(let map):
            let reduced = map.filter { keep.contains($0.key) }
            reducedRepair = reduced.isEmpty ? .listingOnly : .perAssetInstants(reduced)
        }

        return DateFinding(id: id,
                           kind: kind,
                           assetIds: ids,
                           timestamps: times,
                           repair: reducedRepair,
                           referenceIds: referenceIds,
                           referenceTimestamps: referenceTimestamps,
                           title: title)
    }
}

/// Welcher Detektor den Befund erzeugt hat — und womit er ihn belegt.
enum DateFindingKind: Sendable, Equatable {
    case filenameDate(FilenameEvidence)
    case placeholderBlock(PlaceholderEvidence)
    case cameraClock(CameraClockEvidence)
    case timezone(TimezoneEvidence)

    /// Rangfolge der Entdopplung: spezifischer schlägt allgemeiner.
    ///
    /// Ein ausgeschriebenes Datum im Dateinamen ist eine Aussage über *diese*
    /// Aufnahme; ein Kamerauhr-Versatz nur eine Theorie über einen Zeitraum.
    /// Überschneiden sich beide, gewinnt die Aussage.
    var priority: Int {
        switch self {
        case .filenameDate: return 0
        case .placeholderBlock: return 1
        case .cameraClock: return 2
        case .timezone: return 3
        }
    }

    /// Wie viele Aufnahmen ein Befund dieser Art mindestens behalten muss, damit er
    /// nach der Entdopplung noch etwas aussagt.
    ///
    /// Bei A1 genügt eine: das Datum steht im Namen, da braucht es keine Mehrheit.
    /// B und C behaupten dagegen ein gemeinsames Muster — das ist bei drei Aufnahmen
    /// keine Aussage mehr.
    var minimumAssetCount: Int {
        switch self {
        case .filenameDate: return 1
        case .placeholderBlock: return 2
        case .cameraClock: return 5
        case .timezone: return 5
        }
    }

    var iconName: String {
        switch self {
        case .filenameDate: return "textformat.abc.dottedunderline"
        case .placeholderBlock: return "square.stack.3d.up.slash"
        case .cameraClock: return "clock.badge.exclamationmark"
        case .timezone: return "globe.europe.africa"
        }
    }

    /// Kurzname der Sektion.
    var sectionTitle: String {
        switch self {
        case .filenameDate: return "Datum im Dateinamen"
        case .placeholderBlock: return "Blockzeitpunkte"
        case .cameraClock: return "Kamerauhr"
        case .timezone: return "Zeitzone"
        }
    }

    /// Was dieser Detektor beweist — Kopfzeile der Sektion.
    var sectionExplanation: String {
        switch self {
        case .filenameDate:
            return "Der Dateiname nennt ein Datum, das dem gespeicherten widerspricht."
        case .placeholderBlock:
            return "Viele Aufnahmen tragen denselben Zeitpunkt — ein Rückfallwert, keine Aufnahmezeit."
        case .cameraClock:
            return "Die Uhr einer Kamera lief über einen Zeitraum um einen festen Betrag falsch."
        case .timezone:
            return "Die Kamera stand auf einer anderen Zeitzone als der Aufnahmeort."
        }
    }
}

// MARK: - Belege

/// Detektor A1: der Dateiname nennt ein Datum.
struct FilenameEvidence: Sendable, Equatable {

    enum Pattern: Sendable, Equatable {
        /// `VID_20250825_131112`, `Screenshot_20250607-205931` — Datum und Uhrzeit.
        case dateAndTime
        /// `2005-03-25`, `20050325` — nur der Tag.
        case dateOnly
    }

    let pattern: Pattern
    /// Beispielname für die Begründung.
    let sampleFileName: String
    /// Der Tag, den die Dateinamen nennen.
    let namedDay: Date
    /// Wie weit der gespeicherte Zeitstempel davon abweicht (Median über den Befund).
    let medianDeviation: TimeInterval
}

/// Detektor A2: ein Block identischer Zeitstempel.
struct PlaceholderEvidence: Sendable, Equatable {

    /// Woran sich zeigt, dass der Block kein echter Aufnahmezeitpunkt ist.
    ///
    /// Ohne mindestens einen davon wird der Block **verworfen**. Das ist der
    /// Unterschied zwischen einem Kamera-Reset und einer echten Serienaufnahme: eine
    /// Kamera kann durchaus acht Bilder in einer Sekunde schreiben.
    enum Corroborator: Sendable, Equatable {
        /// Keine Aufnahme des Blocks nennt eine Kamera.
        case noCamera
        /// Mehrere Kameramodelle teilen sich dieselbe Sekunde — physisch unmöglich.
        case multipleCameras(count: Int)
        /// Alle Seed-Sekunden liegen auf einer vollen Stunde.
        case roundResetTime
    }

    /// Der Zeitpunkt, den der ganze Block trägt.
    let blockInstant: Date
    /// Wie viele Aufnahmen im Block liegen.
    let blockSize: Int
    /// Die dichteste Sekunde des Blocks.
    let largestSecondCount: Int
    let corroborators: [Corroborator]
    /// Wie viele Aufnahmen ein belegtes Ersatzdatum bekommen haben.
    let repairableCount: Int
}

/// Detektor B: die Uhr einer Kamera lief über einen Lauf falsch.
struct CameraClockEvidence: Sendable, Equatable {
    let cameraLabel: String
    let runStart: Date
    let runEnd: Date
    let offset: TimeInterval
    let shape: DateOffsetShape
    /// Anteil der Lauf-Aufnahmen mit Fremdkamera-Nachbarn **vor** der Verschiebung.
    /// Muss klein sein: ein Lauf, der schon verzahnt ist, hat keinen Uhrfehler.
    let interleaveBefore: Double
    /// Anteil **nach** der Verschiebung. Muss groß sein — das ist der eigentliche
    /// Beweis: erst die Verschiebung bringt die Aufnahmen mit den anderen Kameras
    /// zur Deckung.
    let interleaveAfter: Double
    /// Wie viele Fremdkamera-Aufnahmen als Bezug dienten.
    let referenceCount: Int
}

/// Detektor C: die Kamera stand auf einer fremden Zeitzone.
struct TimezoneEvidence: Sendable, Equatable {
    /// Häufigste geschätzte Zone der ganzen Bibliothek.
    let homeZoneHours: Int
    /// Geschätzte Zone des Aufnahmeorts.
    let placeZoneHours: Int
    let offset: TimeInterval
    let segmentStart: Date
    let segmentEnd: Date
    /// Nachtanteil vor der Verschiebung — der Auslöser.
    let nightBefore: Double
    /// Nachtanteil danach — der Beleg, dass es besser wird.
    let nightAfter: Double
    /// Anteil der Aufnahmen mit Koordinate.
    let gpsCoverage: Double
}

// MARK: - Begründung

/// Eine benennbare Begründungszeile.
///
/// Der Text ist die Stelle, an der eine falsche Behauptung den Menschen erreicht.
/// Er entsteht darum aus einem reinen, geprüften Erzähler und nicht verstreut in
/// den Views.
struct DateEvidence: Sendable, Equatable, Identifiable {

    enum Severity: Sendable, Equatable {
        /// Eine nachprüfbare Tatsache über die Daten.
        case fact
        /// Ein stützender Umstand.
        case support
        /// Etwas, das gegen den Befund spricht.
        case warning
    }

    let severity: Severity
    let icon: String
    let text: String

    var id: String { "\(icon)#\(text)" }
}
