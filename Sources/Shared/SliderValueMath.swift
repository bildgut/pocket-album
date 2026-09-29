import Foundation

/// Die Rechenkerne hinter den Reglern des Bildeditors.
///
/// Sie liegen ausserhalb der Ansicht, weil hier die Feinabstimmung sitzt: wie weit
/// eine Zugbewegung den Wert traegt, wann er am Neutralwert einrastet, wie gross ein
/// Tastenschritt ist und was eine getippte Zahl bedeutet. In der Ansicht waere davon
/// nichts pruefbar.
enum SliderValueMath {

    // MARK: Ziehgeschwindigkeit

    /// Der Faktor, mit dem eine Zugbewegung auf den Wert wirkt.
    ///
    /// Ein Fuenftel beziehungsweise ein Fuenfundzwanzigstel — dasselbe Verhaeltnis,
    /// das Lightroom der Wahl- und der Umschalttaste gibt. Die Umschalttaste allein
    /// tut nichts; sie verschaerft nur den Feinmodus.
    static func speed(fine: Bool, extraFine: Bool) -> Double {
        guard fine else { return 1 }
        return extraFine ? 0.04 : 0.2
    }

    /// Der Wert nach einer Zugbewegung um `dragTranslation` Punkte.
    ///
    /// Der Bezug ist immer der Wert beim Aufsetzen des Fingers, nicht der zuletzt
    /// gesetzte — sonst summierten sich die Rundungen ueber einen langen Zug auf.
    static func value(startValue: Double,
                      dragTranslation: Double,
                      trackWidth: Double,
                      range: ClosedRange<Double>,
                      speed: Double) -> Double {
        // Eine Schiene ohne Breite gaebe es nur im ersten Layout-Durchgang; die
        // Division daraus waere `nan` und damit eine Reglerstellung ohne Rueckweg.
        guard trackWidth > 0 else { return startValue }
        let span = range.upperBound - range.lowerBound
        let neu = startValue + (dragTranslation / trackWidth) * span * speed
        return min(max(neu, range.lowerBound), range.upperBound)
    }

    // MARK: Rastung

    /// Zieht den Wert exakt auf den Neutralwert, solange er naeher als
    /// `thresholdPoints` Punkte daran liegt.
    ///
    /// Ohne das laesst sich der Grundzustand mit der Maus praktisch nie genau treffen —
    /// man landet bei 1,003 statt bei 1.
    static func snapped(_ value: Double,
                        neutral: Double,
                        range: ClosedRange<Double>,
                        trackWidth: Double,
                        thresholdPoints: Double,
                        enabled: Bool) -> Double {
        guard enabled, trackWidth > 0 else { return value }
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return value }
        let abstandInPunkten = abs(value - neutral) / span * trackWidth
        return abstandInPunkten <= thresholdPoints ? neutral : value
    }

    // MARK: Schrittweiten

    /// Die Nachkommastellen, die das Anzeigeformat des Reglers zeigt.
    ///
    /// Das Format ist die einzige Stelle, an der jeder Regler seine Genauigkeit
    /// ohnehin schon nennt — daraus die Schrittweite abzuleiten erspart einen
    /// zweiten Wert an rund fuenfundzwanzig Aufrufstellen.
    static func decimals(format: String) -> Int {
        guard let punkt = format.firstIndex(of: ".") else { return 2 }
        var ziffern = ""
        var i = format.index(after: punkt)
        while i < format.endIndex, format[i].isNumber {
            ziffern.append(format[i])
            i = format.index(after: i)
        }
        return Int(ziffern) ?? 2
    }

    /// Die Schrittweite fuer Pfeiltasten und Scrollrad.
    ///
    /// Fein ist die kleinste Einheit, die das Format ueberhaupt anzeigen kann; grob
    /// teilt den Bereich in etwa hundert Stufen. Bei engen Bereichen faellt Letzteres
    /// unter die Einheit — dann gilt die Einheit, sonst bewegte sich gar nichts.
    static func step(range: ClosedRange<Double>, format: String, fine: Bool) -> Double {
        let einheit = pow(10.0, -Double(decimals(format: format)))
        guard !fine else { return einheit }
        let span = range.upperBound - range.lowerBound
        let grob = (span / 100 / einheit).rounded() * einheit
        return max(einheit, grob)
    }

    // MARK: Zahleneingabe

    /// Deutet den getippten Text als Reglerwert.
    ///
    /// Das Komma gilt wie der Punkt (der deutsche Ziffernblock liefert das Komma),
    /// Vorzeichen und Einheiten wie „EV" stoeren nicht. Nicht endliche Eingaben
    /// werden abgelehnt: `Double("nan")` gelingt und ergaebe eine Reglerstellung,
    /// aus der es kein Zurueck gibt.
    static func parse(_ text: String, range: ClosedRange<Double>) -> Double? {
        let bereinigt = text
            .replacingOccurrences(of: ",", with: ".")
            .filter { "0123456789.+-".contains($0) }
        guard let zahl = Double(bereinigt), zahl.isFinite else { return nil }
        return min(max(zahl, range.lowerBound), range.upperBound)
    }
}
