import Foundation

/// Detektor C: die Kamera stand auf einer anderen Zeitzone als der Aufnahmeort.
///
/// Der entscheidende Unterschied zu allem, was vorher da war: **dieser Detektor
/// misst gegen die Sonne, nicht gegen eine Mehrheit.** Damit gibt es keine Mehrheit
/// mehr, die selbst die kaputte sein könnte.
///
/// Genau daran scheiterte die Vorgängerfassung im Album „2019 - Mai - Nara": 190
/// Fuji-Aufnahmen lagen in Ortszeit mitten in der Nacht, 24 iPhone-Aufnahmen am Tag
/// — und der Vorschlag lautete, die **24 korrekten** um 6,5 Stunden zu verschieben,
/// bis sie zur kaputten Mehrheit passten.
///
/// Ein Befund entsteht hier nur, wenn sich die Geschichte wörtlich erzählen lässt:
/// „Die Kamera stand noch auf Heimatzeit UTC+1, fotografiert wurde bei UTC+9."
/// Ohne diese Übereinstimmung gibt es keinen benennbaren Grund — und dann keinen
/// Befund.
///
/// Rein und abhängigkeitsfrei.
enum DateTimezoneDetector {

    // MARK: - Schwellen

    /// Ab dieser Lücke beginnt ein neuer Abschnitt.
    static let segmentGap: TimeInterval = 12 * 3600

    /// So viele Aufnahmen muss ein Abschnitt haben.
    static let minimumSegmentSize = 20

    /// So viele Aufnahmen des Abschnitts müssen eine Koordinate tragen.
    static let minimumGPSCoverage = 0.6

    /// So weit dürfen die Längengrade eines Abschnitts auseinanderliegen.
    ///
    /// Darüber ist die Zonenschätzung aus dem Median bedeutungslos — ein Abschnitt,
    /// der über einen Flug hinwegreicht, hat keine gemeinsame Ortszeit.
    static let maximumLongitudeSpread = 15.0

    /// So viele Aufnahmen müssen nachts liegen, damit ein Abschnitt auffällt.
    ///
    /// Die Grundrate der echten Bibliothek liegt bei 5,2 % — 60 % sind weit im
    /// Ausläufer und keine Frage des Geschmacks.
    static let suspiciousNightFraction = 0.60

    /// So wenige dürfen danach noch nachts liegen.
    static let acceptableNightFraction = 0.10

    /// Um so viel muss der Nachtanteil sinken.
    static let minimumImprovement = 0.40

    /// So weit darf der Versatz von der Zonendifferenz abweichen.
    ///
    /// Eine Stunde deckt die Sommerzeit ab, die die Schätzung aus dem Längengrad
    /// nicht kennt.
    static let zoneTolerance: TimeInterval = 3600

    // MARK: - Abschnitte

    struct Segment: Sendable, Equatable {
        let rows: [DateScanRow]
        let placeZoneHours: Int
        let gpsCoverage: Double

        var start: Date { rows.first?.timestamp ?? .distantPast }
        var end: Date { rows.last?.timestamp ?? .distantFuture }
    }

    /// Zerteilt die Bibliothek in Abschnitte gleicher Ortszeit.
    static func segments(in scan: DateLibraryScan, excluding claimed: Set<String>) -> [Segment] {
        let rows = scan.sortedAll.filter { !claimed.contains($0.id) }
        guard !rows.isEmpty else { return [] }

        var groups: [[DateScanRow]] = []
        var current: [DateScanRow] = [rows[0]]

        func zone(_ row: DateScanRow) -> Int? {
            row.longitude.map(DateLocalTime.utcOffsetHours(longitude:))
        }

        for row in rows.dropFirst() {
            let gap = row.timestamp.timeIntervalSince(current[current.count - 1].timestamp)
            let zoneChanged: Bool
            if let new = zone(row), let old = current.compactMap(zone).last {
                zoneChanged = new != old
            } else {
                zoneChanged = false
            }

            if gap > segmentGap || zoneChanged {
                groups.append(current)
                current = [row]
            } else {
                current.append(row)
            }
        }
        groups.append(current)

        return groups.compactMap(segment(from:))
    }

    private static func segment(from rows: [DateScanRow]) -> Segment? {
        guard rows.count >= minimumSegmentSize else { return nil }

        let longitudes = rows.compactMap(\.longitude)
        let coverage = Double(longitudes.count) / Double(rows.count)
        guard coverage >= minimumGPSCoverage else { return nil }

        guard let low = longitudes.min(), let high = longitudes.max(),
              high - low <= maximumLongitudeSpread else { return nil }
        guard let zone = DateLocalTime.utcOffsetHours(longitudes: longitudes) else { return nil }

        return Segment(rows: rows, placeZoneHours: zone, gpsCoverage: coverage)
    }

    // MARK: - Erkennung

    static func findings(in scan: DateLibraryScan, excluding claimed: Set<String>) -> [DateFinding] {
        guard let homeZone = scan.homeZoneHours else { return [] }

        let all = segments(in: scan, excluding: claimed)
        return all.indices
            .compactMap { finding(at: $0, in: all, homeZone: homeZone) }
            .sorted { a, b in
                a.assetIds.count == b.assetIds.count
                    ? a.id < b.id
                    : a.assetIds.count > b.assetIds.count
            }
    }

    private static func finding(at index: Int,
                                in segments: [Segment],
                                homeZone: Int) -> DateFinding? {
        let segment = segments[index]
        let zone = segment.placeZoneHours
        let timestamps = segment.rows.map(\.timestamp)

        // (1) Der Abschnitt muss überhaupt auffallen.
        let nightBefore = DateLocalTime.nightFraction(timestamps, utcOffsetHours: zone)
        guard nightBefore >= suspiciousNightFraction else { return nil }

        // (2) Der benennbare Grund ist Pflicht und steht vor der Suche: der Versatz
        // ist die Differenz zwischen Heimatzone und Ortszone. Nicht „der Versatz, der
        // am besten passt" — der ließe sich immer finden.
        let offset = TimeInterval(homeZone - zone) * 3600
        guard offset != 0 else { return nil }

        // (3) Er muss den Nachtanteil deutlich senken.
        let nightAfter = DateLocalTime.nightFraction(timestamps,
                                                     shiftedBy: offset,
                                                     utcOffsetHours: zone)
        guard nightAfter <= acceptableNightFraction,
              nightBefore - nightAfter >= minimumImprovement else { return nil }

        // (4) Ein besserer Versatz auf dem Halbstundengitter wäre ein Zeichen, dass
        // die Geschichte nicht stimmt — dann lieber nichts behaupten.
        guard isBestOnGrid(offset: offset, timestamps: timestamps, zone: zone) else { return nil }

        // (5) Die Reise darf sich durch die Verschiebung nicht umsortieren.
        guard !overlapsNeighbours(at: index, in: segments, offset: offset) else { return nil }

        let evidence = TimezoneEvidence(
            homeZoneHours: homeZone,
            placeZoneHours: zone,
            offset: offset,
            segmentStart: segment.start,
            segmentEnd: segment.end,
            nightBefore: nightBefore,
            nightAfter: nightAfter,
            gpsCoverage: segment.gpsCoverage
        )

        return DateFinding(
            id: "tz:\(Int(segment.start.timeIntervalSince1970))",
            kind: .timezone(evidence),
            assetIds: segment.rows.map(\.id),
            timestamps: timestamps,
            repair: .uniformOffset(offset),
            referenceIds: [],
            referenceTimestamps: [],
            title: title(for: segment)
        )
    }

    private static func title(for segment: Segment) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateFormat = "d. MMMM yyyy"
        return "Reise ab \(formatter.string(from: segment.start))"
    }

    /// Ob kein anderer Versatz auf dem Halbstundengitter den Nachtanteil stärker
    /// senkt als der erzählbare.
    ///
    /// Der Sinn ist nicht, einen besseren Wert zu finden, sondern zu bemerken, wenn
    /// die Erklärung „Heimatzeit gegen Ortszeit" die Daten *nicht* am besten
    /// beschreibt. Dann liegt etwas anderes vor, und Raten hilft niemandem.
    static func isBestOnGrid(offset: TimeInterval,
                             timestamps: [Date],
                             zone: Int) -> Bool {
        let target = DateLocalTime.nightFraction(timestamps,
                                                 shiftedBy: offset,
                                                 utcOffsetHours: zone)
        for halfHours in -28...28 {
            let candidate = TimeInterval(halfHours) * 1800
            let fraction = DateLocalTime.nightFraction(timestamps,
                                                       shiftedBy: candidate,
                                                       utcOffsetHours: zone)
            if fraction < target { return false }
        }
        return true
    }

    private static func overlapsNeighbours(at index: Int,
                                           in segments: [Segment],
                                           offset: TimeInterval) -> Bool {
        let segment = segments[index]
        let start = segment.start.addingTimeInterval(offset)
        let end = segment.end.addingTimeInterval(offset)

        if index > 0, segments[index - 1].end > start { return true }
        if index + 1 < segments.count, segments[index + 1].start < end { return true }
        return false
    }
}
