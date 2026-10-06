import Foundation

/// Detektor A1: der Dateiname nennt ein Datum, das dem gespeicherten widerspricht.
///
/// Der stärkste Beleg, den die Bibliothek hergibt, und der einzige, der ein
/// **exaktes Zieldatum** liefert statt eines geschätzten Versatzes.
/// `Norman_Geburtstag_25_03_2005_Bild125.jpg` steht auf 2015-06-26;
/// `VID_20250825_131112.mp4` steht auf 1970-01-01.
///
/// Rein und abhängigkeitsfrei — kein SQLite, kein Netz, keine Uhr außer der
/// ausdrücklich übergebenen Obergrenze.
enum DateFilenameDetector {

    // MARK: - Schwellen

    /// So weit muss der gespeicherte Zeitstempel vom genannten Datum abweichen.
    ///
    /// 36 Stunden decken zweierlei ab, ohne echte Widersprüche zu verschlucken: den
    /// unbekannten Zeitzonenversatz (höchstens 14 h) und die Unschärfe, die entsteht,
    /// wenn der Dateiname nur den Tag nennt und wir 12:00 ansetzen (höchstens 12 h).
    /// Beides zusammen bleibt darunter.
    static let minimumDeviation: TimeInterval = 36 * 3600

    /// Vor diesem Jahr wird kein Dateinamens-Datum geglaubt.
    ///
    /// Digitalfotografie beginnt später; vierstellige Zahlen aus den Achtzigern in
    /// einem Dateinamen sind fast immer etwas anderes — eine Auflösung, eine
    /// Modellnummer, ein Preis.
    static let earliestYear = 1985

    // MARK: - Erkennung

    /// Sucht Aufnahmen, deren Dateiname einem anderen Tag widerspricht.
    ///
    /// - Parameter now: Obergrenze für plausible Jahreszahlen. Ausdrücklich übergeben
    ///   statt `Date()` gelesen, damit der Detektor ohne Uhr prüfbar bleibt.
    static func findings(in scan: DateLibraryScan, now: Date) -> [DateFinding] {
        let candidates = scan.sortedAll.compactMap { row -> (DateScanRow, ParsedName)? in
            // Nur Aufnahmen ohne Kamera-EXIF.
            //
            // Gemessen an der echten Bibliothek (156 098 Aufnahmen): bei Aufnahmen
            // *mit* Kamera bestätigt der Dateiname den gespeicherten Zeitstempel
            // 16 890-mal und widerspricht 6-mal. Dort gibt es nichts zu holen und nur
            // Fehlalarme zu riskieren. Ohne Kamera widersprechen 447 von 1 851.
            guard !row.hasCamera else { return nil }
            guard let parsed = parse(fileName: row.originalFileName, now: now) else { return nil }
            guard abs(parsed.wallClock.timeIntervalSince(row.timestamp)) > minimumDeviation else {
                return nil
            }
            return (row, parsed)
        }

        return group(candidates)
    }

    // MARK: - Bündelung

    /// Fasst Aufnahmen zusammen, die denselben Tag nennen.
    ///
    /// Ohne das wären die 86 Dateien `Norman_Geburtstag_25_03_2005_Bild###.jpg`
    /// sechsundachtzig Karten.
    ///
    /// Der Zieltag allein ist der Schlüssel, nicht Tag **und** Namensfamilie. An der
    /// echten Bibliothek gemessen zerlegte die feinere Bündelung zusammengehörige
    /// Fälle: `20100526-IMG_0014.jpg` und `20100526-DCP_0543.jpg` nennen denselben
    /// Tag und gehören sichtbar zusammen, landeten aber auf zwei Karten. Wer denselben
    /// Tag nennt, gehört auf dieselbe Karte — was die Aufnahmen davon zeigen, sieht
    /// man im Detail-Blatt.
    private static func group(_ candidates: [(DateScanRow, ParsedName)]) -> [DateFinding] {
        var buckets: [String: [(DateScanRow, ParsedName)]] = [:]

        for candidate in candidates {
            buckets[dayKey(candidate.1.wallClock), default: []].append(candidate)
        }

        return buckets.keys.sorted().compactMap { key in
            guard let members = buckets[key] else { return nil }
            return finding(key: key, members: members)
        }
        // Die größten Befunde zuerst; bei Gleichstand nach Schlüssel, damit die
        // Reihenfolge nicht von der Hash-Reihenfolge abhängt.
        .sorted { a, b in
            a.assetIds.count == b.assetIds.count
                ? a.id < b.id
                : a.assetIds.count > b.assetIds.count
        }
    }

    private static func finding(key: String,
                                members: [(DateScanRow, ParsedName)]) -> DateFinding? {
        guard let first = members.first else { return nil }

        // Bereits chronologisch: `scan.sortedAll` war es, und die Bündelung erhält
        // die Reihenfolge.
        let rows = members.map(\.0)
        let deviations = members.map { abs($0.1.wallClock.timeIntervalSince($0.0.timestamp)) }

        var instants: [String: DateInstant] = [:]
        for (row, parsed) in members {
            instants[row.id] = DateInstant(instant: parsed.wallClock,
                                           precision: parsed.hasTime ? .exact : .dayOnly,
                                           anchor: .wallClock)
        }

        let evidence = FilenameEvidence(
            pattern: first.1.hasTime ? .dateAndTime : .dateOnly,
            sampleFileName: first.0.originalFileName,
            namedDay: first.1.wallClock,
            medianDeviation: median(deviations)
        )

        return DateFinding(
            id: "fn:\(key)",
            kind: .filenameDate(evidence),
            assetIds: rows.map(\.id),
            timestamps: rows.map(\.timestamp),
            repair: .perAssetInstants(instants),
            referenceIds: [],
            referenceTimestamps: [],
            title: title(for: first.1.wallClock)
        )
    }

    /// Ohne Zählung im Text.
    ///
    /// Die Entdopplung kann einem Befund Aufnahmen entziehen; eine im Titel
    /// eingebackene Zahl stünde danach falsch da. Die Anzahl zeigt die Karte aus
    /// `assetIds` — dort stimmt sie immer.
    private static func title(for day: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "d. MMMM yyyy"
        return "Dateiname nennt den \(formatter.string(from: day))"
    }

    /// Der Namensteil vor der laufenden Nummer, klein geschrieben.
    ///
    /// `Norman_Geburtstag_25_03_2005_Bild125.jpg` → `norman_geburtstag_25_03_2005_bild`.
    /// Trennt Namensfamilien, ohne sie an der Nummer auseinanderzureißen.
    static func namePrefix(_ fileName: String) -> String {
        let stem = fileName.contains(".")
            ? String(fileName[..<fileName.lastIndex(of: ".")!])
            : fileName
        let trimmed = stem.reversed().drop { $0.isNumber }
        return String(trimmed.reversed()).lowercased()
    }

    private static func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func median(_ values: [TimeInterval]) -> TimeInterval {
        guard !values.isEmpty else { return 0 }
        return values.sorted()[values.count / 2]
    }

    // MARK: - Dateinamen lesen

    /// Was ein Dateiname über den Aufnahmezeitpunkt sagt.
    struct ParsedName: Sendable, Equatable {
        /// Datum und Uhrzeit in UTC-Feldern — eine Wanduhrzeit, kein Zeitpunkt.
        let wallClock: Date
        /// Ob der Name auch eine Uhrzeit nennt.
        let hasTime: Bool
    }

    // Reihenfolge ist bedeutsam: das längste, eindeutigste Muster zuerst. Sonst
    // fräse `YYYYMMDD` die ersten acht Ziffern aus `20250825_131112` heraus und die
    // Uhrzeit ginge verloren.
    private static let dateTimePattern = try! NSRegularExpression(
        pattern: "(?<![0-9])(\\d{4})(\\d{2})(\\d{2})[-_ ]?(\\d{2})(\\d{2})(\\d{2})(?![0-9])")
    private static let isoDatePattern = try! NSRegularExpression(
        pattern: "(?<![0-9])(\\d{4})[-_.](\\d{2})[-_.](\\d{2})(?![0-9])")
    private static let compactDatePattern = try! NSRegularExpression(
        pattern: "(?<![0-9])(\\d{4})(\\d{2})(\\d{2})(?![0-9])")
    private static let germanDatePattern = try! NSRegularExpression(
        pattern: "(?<![0-9])(\\d{2})[-_.](\\d{2})[-_.](\\d{4})(?![0-9])")

    /// Liest ein Datum aus einem Dateinamen.
    ///
    /// - Returns: `nil`, wenn kein Muster greift oder das Ergebnis kein gültiger
    ///   Kalendertag im plausiblen Bereich ist. Nie ein geratener Wert.
    static func parse(fileName: String, now: Date) -> ParsedName? {
        let range = NSRange(fileName.startIndex..., in: fileName)

        if let m = dateTimePattern.firstMatch(in: fileName, range: range),
           let parsed = build(fileName, m,
                              year: 1, month: 2, day: 3,
                              hour: 4, minute: 5, second: 6, now: now) {
            return parsed
        }
        if let m = isoDatePattern.firstMatch(in: fileName, range: range),
           let parsed = build(fileName, m, year: 1, month: 2, day: 3, now: now) {
            return parsed
        }
        if let m = compactDatePattern.firstMatch(in: fileName, range: range),
           let parsed = build(fileName, m, year: 1, month: 2, day: 3, now: now) {
            return parsed
        }
        if let m = germanDatePattern.firstMatch(in: fileName, range: range),
           let parsed = build(fileName, m, year: 3, month: 2, day: 1, now: now) {
            return parsed
        }
        return nil
    }

    private static func build(_ text: String,
                              _ match: NSTextCheckingResult,
                              year: Int, month: Int, day: Int,
                              hour: Int? = nil, minute: Int? = nil, second: Int? = nil,
                              now: Date) -> ParsedName? {
        func number(_ index: Int) -> Int? {
            guard let range = Range(match.range(at: index), in: text) else { return nil }
            return Int(text[range])
        }

        guard let y = number(year), let mo = number(month), let d = number(day) else {
            return nil
        }

        var components = DateComponents()
        components.year = y
        components.month = mo
        components.day = d

        let hasTime: Bool
        if let hour, let minute, let second,
           let h = number(hour), let mi = number(minute), let s = number(second) {
            guard (0...23).contains(h), (0...59).contains(mi), (0...59).contains(s) else {
                return nil
            }
            components.hour = h
            components.minute = mi
            components.second = s
            hasTime = true
        } else {
            // Ohne Uhrzeit die Tagesmitte: der Wert ist damit höchstens 12 Stunden
            // daneben statt möglicherweise 24, und die Unschärfe ist als
            // `.dayOnly` mitgeführt statt als Genauigkeit getarnt.
            components.hour = 12
            components.minute = 0
            components.second = 0
            hasTime = false
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt

        // `date(from:)` allein akzeptiert den 31. Februar und rollt ihn weiter.
        // Der Rückvergleich verwirft solche Nicht-Tage.
        guard let candidate = calendar.date(from: components) else { return nil }
        let check = calendar.dateComponents([.year, .month, .day], from: candidate)
        guard check.year == y, check.month == mo, check.day == d else { return nil }

        guard y >= earliestYear, candidate <= now else { return nil }

        return ParsedName(wallClock: candidate, hasTime: hasTime)
    }
}
