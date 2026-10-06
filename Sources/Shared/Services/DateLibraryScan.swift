import Foundation

/// Die abgeleiteten Sichten auf die Bibliothek, die sich alle Detektoren teilen.
///
/// Einmal gebaut statt viermal: der Aufbau geht einmal über 156 000 Zeilen, jeder
/// Detektor greift danach nur noch zu. Rein und abhängigkeitsfrei — kein SQLite,
/// kein Netz, keine Uhr.
///
/// Die Analyse-Einheit ist bewusst die **Bibliothek**, nicht das Album. Die
/// Vorgängerfassung war albumbezogen, und genau daraus entstanden die Vorschläge,
/// die Aufnahmen von einem Tag einer Reise auf einen anderen Tag derselben Reise
/// schoben.
struct DateLibraryScan: Sendable {

    /// Alle beurteilbaren Zeilen, chronologisch.
    let sortedAll: [DateScanRow]

    /// Je Kamera die Zeilen, chronologisch. Zeilen ohne Kamera stehen unter dem
    /// leeren Schlüssel und werden von den Kamera-Detektoren übersprungen.
    let byCamera: [String: [DateScanRow]]

    /// Je Dateiname-ohne-Endung alle Zeilen, die ihn tragen — die Zwillingssuche.
    let byFilenameStem: [String: [DateScanRow]]

    /// Je Sekunde die Anzahl Zeilen. Grundlage der Blockbildung.
    let countsBySecond: [Int: Int]

    /// Je Sekunde die Zeilen. Getrennt von `countsBySecond` gehalten, weil die
    /// Blocksuche zuerst nur zählt und erst danach zugreift.
    let rowsBySecond: [Int: [DateScanRow]]

    /// Zeilen nach ID, für den Zugriff aus einem Befund heraus.
    let byId: [String: DateScanRow]

    /// Die häufigste geschätzte Zeitzone der Bibliothek — die „Heimatzone".
    ///
    /// Detektor C verlangt, dass ein vorgeschlagener Versatz genau der Differenz
    /// zwischen dieser Zone und der des Aufnahmeorts entspricht. Ohne diese
    /// Übereinstimmung gibt es keinen benennbaren Grund, und der Befund entfällt.
    let homeZoneHours: Int?

    var count: Int { sortedAll.count }

    // MARK: - Aufbau

    static func build(rows: [DateScanRow]) -> DateLibraryScan {
        let sorted = rows.sorted(by: chronological)

        var byCamera: [String: [DateScanRow]] = [:]
        var byStem: [String: [DateScanRow]] = [:]
        var rowsBySecond: [Int: [DateScanRow]] = [:]
        var byId: [String: DateScanRow] = [:]
        var zoneCounts: [Int: Int] = [:]

        // Ein Durchlauf über die bereits sortierte Folge: damit sind alle
        // abgeleiteten Listen ohne weiteres Sortieren ebenfalls chronologisch.
        for row in sorted {
            byCamera[row.cameraKey, default: []].append(row)
            byStem[row.filenameStem, default: []].append(row)
            rowsBySecond[row.epochSecond, default: []].append(row)
            byId[row.id] = row
            if let longitude = row.longitude {
                zoneCounts[DateLocalTime.utcOffsetHours(longitude: longitude), default: 0] += 1
            }
        }

        let counts = rowsBySecond.mapValues(\.count)

        // Bei Gleichstand die kleinere Zone, damit das Ergebnis nicht von der
        // Hash-Reihenfolge des Dictionaries abhängt.
        let home = zoneCounts.max { a, b in
            a.value == b.value ? a.key > b.key : a.value < b.value
        }?.key

        return DateLibraryScan(sortedAll: sorted,
                               byCamera: byCamera,
                               byFilenameStem: byStem,
                               countsBySecond: counts,
                               rowsBySecond: rowsBySecond,
                               byId: byId,
                               homeZoneHours: home)
    }

    /// Nach (Zeit, ID) statt nur nach Zeit: bei gleichem Zeitstempel wäre die
    /// Reihenfolge sonst von der Eingabe abhängig — und damit auch jedes Ergebnis,
    /// das darauf aufbaut.
    static func chronological(_ a: DateScanRow, _ b: DateScanRow) -> Bool {
        a.timestamp == b.timestamp ? a.id < b.id : a.timestamp < b.timestamp
    }

    // MARK: - Zugriff

    /// Die Kameras mit mindestens einer Aufnahme, ohne die kameralosen.
    ///
    /// Sortiert, damit die Reihenfolge der Befunde nicht von der Hash-Reihenfolge
    /// abhängt.
    var cameraKeys: [String] {
        byCamera.keys.filter { $0 != "|" && !$0.isEmpty }.sorted()
    }

    /// Zeitstempel aller Kameras **außer** der genannten, chronologisch.
    ///
    /// Der Bezug, gegen den Detektor B die Verzahnung misst. Als sortiertes
    /// `[TimeInterval]` statt als Zeilen, damit die Nachbarsuche binär laufen kann.
    func timestampsExcluding(cameraKey excluded: String) -> [TimeInterval] {
        var result: [TimeInterval] = []
        result.reserveCapacity(sortedAll.count)
        for row in sortedAll where row.cameraKey != excluded {
            result.append(row.timestamp.timeIntervalSince1970)
        }
        return result
    }

    /// Ob in `sortedTimes` ein Wert innerhalb von `window` um `target` liegt.
    ///
    /// Binärsuche: Detektor B ruft das je Lauf-Aufnahme und je Kandidat auf, das
    /// sind schnell einige Millionen Aufrufe.
    static func hasNeighbour(in sortedTimes: [TimeInterval],
                             near target: TimeInterval,
                             window: TimeInterval) -> Bool {
        guard !sortedTimes.isEmpty else { return false }

        var low = 0
        var high = sortedTimes.count
        while low < high {
            let mid = (low + high) / 2
            if sortedTimes[mid] < target { low = mid + 1 } else { high = mid }
        }

        // `low` ist der erste Wert ≥ target; der nächste Nachbar ist einer der beiden
        // um diese Stelle.
        if low < sortedTimes.count, sortedTimes[low] - target <= window { return true }
        if low > 0, target - sortedTimes[low - 1] <= window { return true }
        return false
    }

    /// Anteil der Zeitpunkte, die nach Verschieben um `offset` einen Nachbarn in
    /// `sortedTimes` haben — 0…1.
    ///
    /// Das Maß, an dem Detektor B hängt: ein verstellter Zeitgeber zeigt sich daran,
    /// dass die Aufnahmen **erst nach** der Verschiebung mit den anderen Kameras zur
    /// Deckung kommen.
    static func interleaveFraction(times: [TimeInterval],
                                   against sortedTimes: [TimeInterval],
                                   offset: TimeInterval,
                                   window: TimeInterval) -> Double {
        guard !times.isEmpty else { return 0 }
        let hits = times.count {
            hasNeighbour(in: sortedTimes, near: $0 + offset, window: window)
        }
        return Double(hits) / Double(times.count)
    }
}
