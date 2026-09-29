import Foundation

/// Ortszeit ohne Zeitzonendatenbank.
///
/// Rein und abhängigkeitsfrei — kein SQLite, kein Netz, keine Uhr. Beantwortet
/// genau eine Frage: **war es dort Tag oder Nacht?** Das reicht, um zu prüfen, ob
/// eine Verschiebung die Aufnahmen plausibler oder unplausibler macht.
///
/// Ausdrücklich **nicht** dafür gedacht, einen Versatz zu *berechnen*. Dafür ist
/// die Schätzung aus dem Längengrad zu grob — sie kennt keine Sommerzeit und keine
/// politischen Zonengrenzen.
enum DateLocalTime {

    /// Außerhalb dieser Stunden gilt eine Aufnahme als „nachts".
    ///
    /// Großzügig gewählt: 6 bis 22 Uhr Ortszeit. Wer um 23 Uhr fotografiert, tut das
    /// durchaus — die Prüfung soll grobe Verschiebungen aufdecken, nicht Nachtfotos
    /// verdächtigen.
    static let dayHours = 6...22

    /// Schätzt den UTC-Versatz eines Aufnahmeorts aus dem Längengrad.
    ///
    /// `round(Längengrad / 15)` — ohne Zeitzonendatenbank und ohne Sommerzeit auf
    /// ±1 Stunde genau. Für Nara (135,8° O) ergibt das UTC+9, also genau richtig.
    static func utcOffsetHours(longitude: Double) -> Int {
        max(-12, min(14, Int((longitude / 15).rounded())))
    }

    /// Schätzt den UTC-Versatz aus dem Median mehrerer Längengrade.
    ///
    /// - Returns: `nil`, wenn keine Koordinate vorliegt.
    static func utcOffsetHours(longitudes: [Double]) -> Int? {
        let sorted = longitudes.sorted()
        guard !sorted.isEmpty else { return nil }
        return utcOffsetHours(longitude: sorted[sorted.count / 2])
    }

    /// Die Stunde des Tages am Aufnahmeort.
    static func localHour(_ date: Date, utcOffsetHours: Int) -> Int {
        let shifted = date.timeIntervalSince1970 + Double(utcOffsetHours) * 3600
        var withinDay = shifted.truncatingRemainder(dividingBy: 86400)
        if withinDay < 0 { withinDay += 86400 }
        return Int(withinDay / 3600)
    }

    static func isAtNight(_ date: Date, utcOffsetHours: Int) -> Bool {
        !dayHours.contains(localHour(date, utcOffsetHours: utcOffsetHours))
    }

    /// Anteil der Zeitpunkte, die in die Nacht fallen — 0…1.
    ///
    /// Der Maßstab, an dem die Detektoren B und C messen, ob eine Verschiebung
    /// etwas verbessert. Bei leerer Eingabe 0, damit ein leerer Abschnitt nie als
    /// verdächtig gilt.
    static func nightFraction(_ dates: [Date], utcOffsetHours: Int) -> Double {
        guard !dates.isEmpty else { return 0 }
        let night = dates.count { isAtNight($0, utcOffsetHours: utcOffsetHours) }
        return Double(night) / Double(dates.count)
    }

    /// Anteil der um `offset` verschobenen Zeitpunkte, die in die Nacht fallen.
    static func nightFraction(_ dates: [Date],
                              shiftedBy offset: TimeInterval,
                              utcOffsetHours: Int) -> Double {
        nightFraction(dates.map { $0.addingTimeInterval(offset) },
                      utcOffsetHours: utcOffsetHours)
    }
}
