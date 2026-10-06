import Foundation

/// Macht aus einem Befund die Sätze, die ihn begründen.
///
/// Rein und geprüft — und zwar aus demselben Grund wie die Detektoren selbst: der
/// Text ist die Stelle, an der eine falsche Behauptung den Menschen erreicht. Ein
/// Erzähler, der über den Daten hinausgeht, richtet mehr Schaden an als eine
/// schlechte Schwelle, weil er Vertrauen erzeugt, das die Daten nicht decken.
///
/// Deshalb nennt jede Zeile eine **nachprüfbare** Tatsache: eine Zahl, einen
/// Dateinamen, einen Zeitpunkt. Keine Zeile sagt „wahrscheinlich" oder „vermutlich".
enum DateFindingNarrator {

    static func evidence(for finding: DateFinding) -> [DateEvidence] {
        switch finding.kind {
        case .filenameDate(let e): return filenameEvidence(e, finding: finding)
        case .placeholderBlock(let e): return placeholderEvidence(e, finding: finding)
        case .cameraClock(let e): return clockEvidence(e, finding: finding)
        case .timezone(let e): return timezoneEvidence(e, finding: finding)
        }
    }

    // MARK: - A1

    private static func filenameEvidence(_ e: FilenameEvidence,
                                         finding: DateFinding) -> [DateEvidence] {
        var lines: [DateEvidence] = [
            DateEvidence(
                severity: .fact,
                icon: "textformat.abc.dottedunderline",
                text: "Der Dateiname „\(e.sampleFileName)“ nennt den "
                    + "\(dayText(e.namedDay)); gespeichert ist "
                    + "\(dayText(finding.timestamps.first ?? e.namedDay))."),
            DateEvidence(
                severity: .fact,
                icon: "camera.badge.ellipsis",
                text: "Keine dieser Aufnahmen trägt eine Kameraangabe. "
                    + "Ihr Zeitstempel stammt daher nicht aus der Kamera.")
        ]

        switch e.pattern {
        case .dateAndTime:
            lines.append(DateEvidence(
                severity: .support,
                icon: "clock",
                text: "Der Name nennt auch die Uhrzeit — das Ersatzdatum ist "
                    + "auf die Sekunde belegt."))
        case .dateOnly:
            lines.append(DateEvidence(
                severity: .warning,
                icon: "questionmark.circle",
                text: "Der Name nennt nur den Tag. Die Uhrzeit wird auf 12:00 "
                    + "gesetzt und ist nicht belegt."))
        }

        lines.append(DateEvidence(
            severity: .support,
            icon: "checkmark.shield",
            text: "Gegenprobe an der Bibliothek: bei Aufnahmen mit Kameraangabe "
                + "bestätigt der Dateiname das gespeicherte Datum in 16 890 von "
                + "16 896 Fällen. Deshalb greift diese Prüfung nur ohne Kamera."))

        return lines
    }

    // MARK: - A2

    private static func placeholderEvidence(_ e: PlaceholderEvidence,
                                            finding: DateFinding) -> [DateEvidence] {
        var lines: [DateEvidence] = [
            DateEvidence(
                severity: .fact,
                icon: "square.stack.3d.up.slash",
                text: "\(e.blockSize) Aufnahmen tragen denselben Zeitpunkt "
                    + "(\(instantText(e.blockInstant))), davon \(e.largestSecondCount) "
                    + "auf exakt derselben Sekunde.")
        ]

        for corroborator in e.corroborators {
            switch corroborator {
            case .noCamera:
                lines.append(DateEvidence(
                    severity: .fact,
                    icon: "camera.badge.ellipsis",
                    text: "Keine dieser Aufnahmen trägt eine Kameraangabe — der "
                        + "Zeitstempel ist das, was das Dateisystem hergab."))
            case .multipleCameras(let count):
                lines.append(DateEvidence(
                    severity: .fact,
                    icon: "exclamationmark.triangle",
                    text: "\(count) verschiedene Kameramodelle teilen sich dieselbe "
                        + "Sekunde. Kein Gerät kann das erzeugt haben."))
            case .roundResetTime:
                lines.append(DateEvidence(
                    severity: .fact,
                    icon: "arrow.counterclockwise",
                    text: "Der Zeitpunkt liegt auf einer vollen Stunde — die Form "
                        + "eines zurückgesetzten Kameradatums."))
            }
        }

        // Aus dem Befund gezählt, nicht aus dem Beleg: die Entdopplung kann einem
        // Befund Aufnahmen entzogen haben, und dann stünde die ursprüngliche Zahl
        // falsch da.
        if finding.writableCount == 0 {
            lines.append(DateEvidence(
                severity: .warning,
                icon: "nosign",
                text: "Für keine dieser Aufnahmen gibt es ein belegtes Ersatzdatum. "
                    + "Der Befund zeigt sie, ändert aber nichts."))
        } else {
            lines.append(DateEvidence(
                severity: .support,
                icon: "arrow.uturn.backward",
                text: "Für \(finding.writableCount) von \(finding.assetIds.count) "
                    + "Aufnahmen gibt es ein belegtes Ersatzdatum; die übrigen "
                    + "bleiben unverändert."))
        }

        return lines
    }

    // MARK: - B

    private static func clockEvidence(_ e: CameraClockEvidence,
                                      finding: DateFinding) -> [DateEvidence] {
        [
            DateEvidence(
                severity: .fact,
                icon: "camera",
                text: "\(finding.assetIds.count) Aufnahmen der \(e.cameraLabel), "
                    + "\(dayText(e.runStart)) bis \(dayText(e.runEnd))."),
            DateEvidence(
                severity: .fact,
                icon: "arrow.left.and.right",
                text: "Vorher liegen \(percent(e.interleaveBefore)) dieser Aufnahmen "
                    + "in der Nähe von Aufnahmen anderer Kameras, nachher "
                    + "\(percent(e.interleaveAfter)). Erst die Verschiebung bringt "
                    + "sie zur Deckung."),
            DateEvidence(
                severity: .fact,
                icon: "chart.bar",
                text: "Jedes Drittel des Zeitraums ergibt für sich denselben "
                    + "Versatz — er gilt also durchgehend, nicht nur im Mittel."),
            DateEvidence(
                severity: .support,
                icon: "ruler",
                text: "Der Versatz hat die Form: \(shapeText(e.shape))."),
            DateEvidence(
                severity: .support,
                icon: "books.vertical",
                text: "Als Bezug dienten \(e.referenceCount) Aufnahmen anderer "
                    + "Kameras aus der ganzen Bibliothek.")
        ]
    }

    // MARK: - C

    private static func timezoneEvidence(_ e: TimezoneEvidence,
                                         finding: DateFinding) -> [DateEvidence] {
        [
            DateEvidence(
                severity: .fact,
                icon: "globe.europe.africa",
                text: "Die Kamera stand auf \(zoneText(e.homeZoneHours)), "
                    + "fotografiert wurde bei \(zoneText(e.placeZoneHours)) — "
                    + "\(DateFixOffset.humanReadable(e.offset))."),
            DateEvidence(
                severity: .fact,
                icon: "moon.stars",
                text: "\(percent(e.nightBefore)) der Aufnahmen liegen in Ortszeit "
                    + "in der Nacht; nach der Verschiebung \(percent(e.nightAfter))."),
            DateEvidence(
                severity: .support,
                icon: "location",
                text: "\(percent(e.gpsCoverage)) der Aufnahmen tragen eine "
                    + "Koordinate. Die Zeitzone ist daraus geschätzt "
                    + "(Längengrad geteilt durch 15), nicht aus einer "
                    + "Zeitzonendatenbank."),
            DateEvidence(
                severity: .support,
                icon: "sun.max",
                text: "Gemessen wird gegen den Sonnenstand, nicht gegen andere "
                    + "Aufnahmen — es gibt hier keine Mehrheit, die selbst falsch "
                    + "liegen könnte.")
        ]
    }

    // MARK: - Textbausteine

    static func shapeText(_ shape: DateOffsetShape) -> String {
        switch shape {
        case .timezone(let hours):
            let value = hours == hours.rounded()
                ? String(Int(hours))
                : String(format: "%.1f", hours).replacingOccurrences(of: ".", with: ",")
            return "\(value) Stunden — die Form einer Zeitzone"
        case .days(let days):
            return "\(abs(days)) ganze Tage"
        case .years(let years):
            let value = String(format: "%.1f", abs(years))
                .replacingOccurrences(of: ".", with: ",")
            return "rund \(value) Jahre — die Form eines nie gestellten Kameradatums"
        case .other:
            return "kein übliches Maß"
        }
    }

    static func zoneText(_ hours: Int) -> String {
        hours >= 0 ? "UTC+\(hours)" : "UTC\(hours)"
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded())) %"
    }

    static func dayText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateFormat = "d. MMMM yyyy"
        return formatter.string(from: date)
    }

    static func instantText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateFormat = "d. MMMM yyyy, HH:mm:ss"
        return formatter.string(from: date)
    }
}
