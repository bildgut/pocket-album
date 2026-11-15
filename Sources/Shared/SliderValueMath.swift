import Foundation

/// Kennlinie für die Umrechnung zwischen Reglerwert und visuellem Spuranteil (`0...1`).
enum SliderResponseCurve: Equatable, Sendable {
    /// Lineare Zuordnung über den gesamten Wertebereich.
    case linear
    /// Feineres Auflösungsvermögen rund um den Neutralwert (`exponent > 1` = präziser in der Mitte).
    case softCenter(exponent: Double = 1.35)
    /// Perzeptuell ausgewogene Kelvin-Skala über verschobene Mireds (~5200 K Tageslicht in der Spurmitte).
    case miredTemperature
}

/// Die Rechenkerne hinter den Reglern des Bildeditors.
///
/// Sie liegen ausserhalb der Ansicht, weil hier die Feinabstimmung sitzt: wie weit
/// eine Zugbewegung den Wert traegt, wann er am Neutralwert einrastet, wie gross ein
/// Tastenschritt ist und was eine getippte Zahl bedeutet. In der Ansicht waere davon
/// nichts pruefbar.
enum SliderValueMath {

    private static let miredPivotFactor = 2.8

    // MARK: Kennlinie

    /// Bildet einen Reglerwert gemäß `curve` auf den visuellen Spuranteil `0...1` ab.
    static func fraction(for value: Double,
                         range: ClosedRange<Double>,
                         neutral: Double = 0,
                         curve: SliderResponseCurve = .linear) -> Double {
        let low = range.lowerBound
        let high = range.upperBound
        let span = high - low
        guard span > 0 else { return 0 }
        let clamped = min(max(value, low), high)

        switch curve {
        case .linear:
            return (clamped - low) / span

        case .softCenter(let exponent):
            let exp = max(exponent, 0.01)
            let mid = min(max(neutral, low), high)
            let midFrac = (mid - low) / span
            if clamped < mid, mid > low {
                let norm = (mid - clamped) / (mid - low)
                return midFrac * (1 - pow(norm, 1 / exp))
            } else if clamped > mid, high > mid {
                let norm = (clamped - mid) / (high - mid)
                return midFrac + (1 - midFrac) * pow(norm, 1 / exp)
            }
            return midFrac

        case .miredTemperature:
            guard low > 0, high > low else {
                return (clamped - low) / span
            }
            let mLow = 1_000_000.0 / low
            let mHigh = 1_000_000.0 / high
            let mSpan = mLow - mHigh
            guard mSpan > 0 else { return (clamped - low) / span }
            let u = min(max((mLow - 1_000_000.0 / clamped) / mSpan, 0), 1)
            let k = miredPivotFactor
            return u / (k * (1 - u) + u)
        }
    }

    /// Wandelt einen visuellen Spuranteil (`0...1`) gemäß `curve` zurück in einen Reglerwert.
    static func value(atFraction fraction: Double,
                      range: ClosedRange<Double>,
                      neutral: Double = 0,
                      curve: SliderResponseCurve = .linear) -> Double {
        let low = range.lowerBound
        let high = range.upperBound
        let span = high - low
        guard span > 0 else { return low }
        let f = min(max(fraction, 0), 1)

        switch curve {
        case .linear:
            return low + f * span

        case .softCenter(let exponent):
            let exp = max(exponent, 0.01)
            let mid = min(max(neutral, low), high)
            let midFrac = (mid - low) / span
            if f < midFrac, midFrac > 0 {
                let norm = (midFrac - f) / midFrac
                return mid - pow(norm, exp) * (mid - low)
            } else if f > midFrac, midFrac < 1 {
                let norm = (f - midFrac) / (1 - midFrac)
                return mid + pow(norm, exp) * (high - mid)
            }
            return mid

        case .miredTemperature:
            guard low > 0, high > low else {
                return low + f * span
            }
            let mLow = 1_000_000.0 / low
            let mHigh = 1_000_000.0 / high
            let mSpan = mLow - mHigh
            guard mSpan > 0 else { return low + f * span }
            let k = miredPivotFactor
            let u = (k * f) / (1 + (k - 1) * f)
            let mired = mLow - u * mSpan
            guard mired > 0 else { return high }
            return min(max(1_000_000.0 / mired, low), high)
        }
    }

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
                      speed: Double,
                      neutral: Double = 0,
                      curve: SliderResponseCurve = .linear) -> Double {
        // Eine Schiene ohne Breite gaebe es nur im ersten Layout-Durchgang; die
        // Division daraus waere `nan` und damit eine Reglerstellung ohne Rueckweg.
        guard trackWidth > 0 else { return startValue }
        let startFrac = fraction(for: startValue, range: range, neutral: neutral, curve: curve)
        let zielFrac = startFrac + (dragTranslation / trackWidth) * speed
        return value(atFraction: zielFrac, range: range, neutral: neutral, curve: curve)
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
                        enabled: Bool,
                        curve: SliderResponseCurve = .linear) -> Double {
        guard enabled, trackWidth > 0 else { return value }
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return value }
        let fVal = fraction(for: value, range: range, neutral: neutral, curve: curve)
        let fNeutral = fraction(for: neutral, range: range, neutral: neutral, curve: curve)
        let abstandInPunkten = abs(fVal - fNeutral) * trackWidth
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
