import Foundation

/// Robuste Statistik über Zeitpunkte, plus die Formbeschreibung eines Versatzes.
///
/// Rein und abhängigkeitsfrei. Herausgelöst aus `DateOutlierMatcher`, damit die
/// Detektoren sie teilen können, ohne den alten Abgleich mitzuschleppen.
enum DateStatistics {

    /// Der obere Median — bei gerader Anzahl der Wert an Position `count / 2`.
    ///
    /// Bewusst kein Mittelwert der beiden mittleren Werte: der Median soll ein
    /// *tatsächlich vorhandener* Zeitpunkt sein, damit ein daraus berechneter Versatz
    /// sich auf etwas bezieht, das man in der Bibliothek wiederfindet.
    static func median(_ dates: [Date]) -> Date? {
        guard !dates.isEmpty else { return nil }
        return dates.sorted()[dates.count / 2]
    }

    /// Median der absoluten Abweichungen vom Median — das robuste Gegenstück zur
    /// Standardabweichung.
    ///
    /// Robust ist hier keine Feinheit: ein einziger Zeitstempel auf 1970 würde eine
    /// Standardabweichung so aufblähen, dass danach *nichts* mehr als Ausreißer gilt.
    static func medianAbsoluteDeviation(_ dates: [Date]) -> TimeInterval {
        guard let center = median(dates) else { return 0 }
        let deviations = dates.map { abs($0.timeIntervalSince(center)) }.sorted()
        return deviations[deviations.count / 2]
    }

    /// Woran ein Versatz der Form nach erinnert.
    ///
    /// Reine Formbeschreibung, keine Diagnose: „sieht aus wie eine Zeitzone" heißt
    /// nicht, dass es eine ist.
    static func shape(of offset: TimeInterval) -> DateOffsetShape {
        let magnitude = abs(offset)

        // Zeitzonen sind Vielfache einer Viertelstunde; die gängigen sind halbe und
        // ganze Stunden. Mehr als 14 Stunden gibt es nirgends.
        if magnitude <= 14 * 3600 {
            let halfHours = (offset / 1800).rounded()
            if abs(offset - halfHours * 1800) < 60 {
                return .timezone(hours: halfHours / 2)
            }
        }

        if magnitude >= 365 * 86400 {
            return .years((offset / (365.25 * 86400) * 10).rounded() / 10)
        }

        if magnitude >= 86400 {
            let days = (offset / 86400).rounded()
            if abs(offset - days * 86400) < 3600 { return .days(Int(days)) }
        }

        return .other
    }
}
