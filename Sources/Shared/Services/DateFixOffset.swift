import Foundation

/// Rechnen mit Zeitversätzen und der Umgang mit Immichs ISO-8601-Zeitstempeln.
///
/// Rein, ohne Zustand und ohne Uhr — damit vollständig testbar.
enum DateFixOffset {

    // MARK: - Rasten

    /// Auf dieses Raster wird gerastet: halbe Stunden. Deckt jede reale
    /// Zeitzonenverschiebung ab, einschließlich der halbstündigen (Indien, Adelaide).
    static let snapGrid: TimeInterval = 30 * 60

    /// So nah muss der Rohversatz am Raster liegen, damit gerastet wird.
    ///
    /// Der Rohversatz stammt aus einer Median-Differenz und ist nie exakt: liegen die
    /// betroffenen Bilder nur im ersten Drittel des Zeitraums, ist er systematisch
    /// daneben. Fünf Minuten trennen „offensichtlich eine Zeitzone" von „das war
    /// etwas anderes" — bei mehr würde blind auf eine Zahl gerastet, die niemand
    /// gemeint hat.
    static let snapTolerance: TimeInterval = 5 * 60

    /// Rastet auf das nächste Vielfache von `snapGrid`, wenn es nah genug liegt.
    /// Sonst bleibt der Rohwert stehen — ein Versatz von elf Jahren ist keine
    /// Zeitzone und darf nicht auf halbe Stunden gebogen werden.
    static func snap(_ raw: TimeInterval) -> TimeInterval {
        let nearest = (raw / snapGrid).rounded() * snapGrid
        return abs(raw - nearest) <= snapTolerance ? nearest : raw
    }

    // MARK: - ISO 8601

    /// Zerlegt einen Zeitstempel in Zeitpunkt und den darin festgeschriebenen
    /// UTC-Versatz.
    ///
    /// Der Versatz wird gebraucht, weil beim Zurückschreiben **derselbe** Versatz
    /// stehen bleiben muss: verschoben wird der Zeitpunkt, nicht die Zeitzone.
    /// Würde stattdessen die lokale Zeitzone des Macs eingesetzt, verschöbe sich
    /// jedes Bild aus einem anderen Land zusätzlich um dessen Differenz.
    static func parse(_ text: String) -> (instant: Date, utcOffsetSeconds: Int)? {
        guard let offset = utcOffsetSeconds(in: text) else { return nil }

        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]

        guard let instant = withFraction.date(from: text) ?? plain.date(from: text) else {
            return nil
        }
        return (instant, offset)
    }

    /// Liest den UTC-Versatz aus dem Textende — `Z`, `+02:00` oder `-05:00`.
    static func utcOffsetSeconds(in text: String) -> Int? {
        if text.hasSuffix("Z") || text.hasSuffix("z") { return 0 }
        guard text.count >= 6 else { return nil }

        let tail = String(text.suffix(6))
        guard let sign = tail.first, sign == "+" || sign == "-" else { return nil }

        let parts = tail.dropFirst().split(separator: ":")
        guard parts.count == 2,
              let hours = Int(parts[0]), let minutes = Int(parts[1]),
              (0...23).contains(hours), (0...59).contains(minutes) else { return nil }

        let magnitude = hours * 3600 + minutes * 60
        return sign == "-" ? -magnitude : magnitude
    }

    /// Formatiert einen Zeitpunkt in der Schreibweise, die Immich entgegennimmt.
    ///
    /// `en_US_POSIX` ist Pflicht: mit der Nutzer-Locale würde ein anderer Kalender
    /// oder eine andere Ziffernschreibweise durchschlagen, und der Server bekäme
    /// Unsinn.
    static func format(_ instant: Date, utcOffsetSeconds: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ"
        formatter.timeZone = TimeZone(secondsFromGMT: utcOffsetSeconds) ?? .gmt
        return formatter.string(from: instant)
    }

    /// Verschiebt einen Zeitstempel und behält seinen UTC-Versatz bei.
    ///
    /// - Returns: `nil`, wenn der Ausgangswert nicht lesbar war. Nie einen
    ///   geratenen Wert — ein falsch geschriebenes Aufnahmedatum ist schlimmer als
    ///   ein übersprungenes Bild.
    static func shift(_ text: String, by offset: TimeInterval) -> String? {
        guard let parsed = parse(text) else { return nil }
        return format(parsed.instant.addingTimeInterval(offset),
                      utcOffsetSeconds: parsed.utcOffsetSeconds)
    }

    /// Setzt einen Zeitstempel auf einen absoluten Zeitpunkt und behält seinen
    /// UTC-Versatz bei.
    ///
    /// Gegenstück zu `shift` für die Fälle, in denen ein Zielzeitpunkt bekannt ist
    /// statt eines Versatzes — etwa wenn eine gleichnamige Kopie derselben Aufnahme
    /// das echte Datum trägt.
    ///
    /// - Returns: `nil`, wenn der Ausgangswert nicht lesbar war. Nie einen geratenen
    ///   Wert.
    static func setInstant(_ text: String, to instant: Date) -> String? {
        guard let parsed = parse(text) else { return nil }
        return format(instant, utcOffsetSeconds: parsed.utcOffsetSeconds)
    }

    /// Setzt die **abgelesene Uhrzeit** eines Zeitstempels und behält seinen
    /// UTC-Versatz bei.
    ///
    /// Für aus Dateinamen gelesene Daten: `VID_20250825_131112.mp4` sagt aus, dass am
    /// Aufnahmeort 13:11:12 Uhr war — nicht, welcher UTC-Zeitpunkt das war. Würde man
    /// die Felder als Zeitpunkt schreiben, verschöbe sich die Anzeige um den
    /// Zeitzonenversatz des Bildes und man läge bei einem Abendvideo schnell auf dem
    /// falschen Tag.
    ///
    /// - Parameter wallClock: Datum und Uhrzeit, in UTC-Feldern abgelegt.
    static func setWallClock(_ text: String, to wallClock: Date) -> String? {
        guard let parsed = parse(text) else { return nil }
        // Den Zeitpunkt so wählen, dass er im Versatz des Bildes formatiert genau die
        // gewünschten Felder ergibt.
        let instant = wallClock.addingTimeInterval(-Double(parsed.utcOffsetSeconds))
        return format(instant, utcOffsetSeconds: parsed.utcOffsetSeconds)
    }

    /// Schreibt einen `DateInstant` in einen bestehenden Zeitstempel.
    ///
    /// Die eine Stelle, an der über den Bezug entschieden wird — die Aufrufer müssen
    /// den Unterschied nicht kennen.
    static func apply(_ replacement: DateInstant, to text: String) -> String? {
        switch replacement.anchor {
        case .wallClock: return setWallClock(text, to: replacement.instant)
        case .absolute: return setInstant(text, to: replacement.instant)
        }
    }

    // MARK: - Anzeige

    /// „+2 h 00 min", „−11 J 3 Mon", „+45 min" — für Karten und Knopfbeschriftungen.
    static func humanReadable(_ offset: TimeInterval) -> String {
        let sign = offset < 0 ? "−" : "+"
        var remaining = Int(abs(offset).rounded())

        let days = remaining / 86400
        remaining %= 86400
        let hours = remaining / 3600
        remaining %= 3600
        let minutes = remaining / 60
        let seconds = remaining % 60

        var parts: [String] = []
        if days > 0 { parts.append("\(days) d") }
        if hours > 0 { parts.append("\(hours) h") }
        if minutes > 0 { parts.append("\(minutes) min") }
        if parts.isEmpty { parts.append("\(seconds) s") }

        return sign + parts.joined(separator: " ")
    }
}
