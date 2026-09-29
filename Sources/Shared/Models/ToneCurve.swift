import CoreGraphics
import Foundation

/// Fünf frei gesetzte Stützpunkte für `CIToneCurve` — die Kurve eines Film-Looks.
///
/// Anders als `RawDevelopEngine.toneCurvePoints`, das seine Punkte aus den Reglern
/// Lichter/Schatten/Weiß/Schwarz *ableitet*, werden sie hier direkt angegeben: Nur so
/// lassen sich angehobene Schwarztöne (Classic Chrome, Eterna) oder eine abgeflachte
/// Schulter beschreiben.
///
/// Invariante, vom Initialisierer erzwungen: genau fünf Punkte, nach x sortiert, alle
/// Werte in 0…1, x strikt steigend (Mindestabstand 0.01 — sonst ist die Spline von
/// `CIToneCurve` undefiniert). Jede andere Punktzahl ergibt die Identität: `CIToneCurve`
/// kennt nur `inputPoint0` … `inputPoint4`.
struct ToneCurve: Codable, Equatable, Sendable {

    static let pointCount = 5

    let points: [CGPoint]

    init(_ points: [CGPoint]) {
        guard points.count == Self.pointCount else {
            self.points = Self.identityPoints
            return
        }
        var sorted = points
            .sorted { $0.x < $1.x }
            .map { CGPoint(x: Self.clamp01($0.x), y: Self.clamp01($0.y)) }
        for i in 1 ..< sorted.count {
            sorted[i].x = max(sorted[i].x, sorted[i - 1].x + 0.01)
        }
        self.points = sorted
    }

    static let identityPoints: [CGPoint] = [
        CGPoint(x: 0, y: 0), CGPoint(x: 0.25, y: 0.25), CGPoint(x: 0.5, y: 0.5),
        CGPoint(x: 0.75, y: 0.75), CGPoint(x: 1, y: 1),
    ]

    static let identity = ToneCurve(identityPoints)

    var isIdentity: Bool { points == Self.identityPoints }

    private static func clamp01(_ v: CGFloat) -> CGFloat { min(1, max(0, v)) }

    // MARK: - Auswertung

    /// Kurvenwert an einer Stelle 0…1 — monotone kubische Hermite-Interpolation
    /// (Fritsch–Carlson): trifft die Stützpunkte exakt und überschwingt zwischen
    /// monoton steigenden Punkten nicht. Dient der Abtastung für `CIColorCurves`;
    /// `CIToneCurve` interpoliert selbst und braucht nur die Stützpunkte.
    func wert(bei x: Double) -> Double {
        let xs = points.map { Double($0.x) }, ys = points.map { Double($0.y) }
        let n = xs.count
        if x <= xs[0] { return ys[0] }
        if x >= xs[n - 1] { return ys[n - 1] }
        var d = [Double](repeating: 0, count: n - 1)
        for i in 0 ..< n - 1 { d[i] = (ys[i + 1] - ys[i]) / (xs[i + 1] - xs[i]) }
        var m = [Double](repeating: 0, count: n)
        m[0] = d[0]; m[n - 1] = d[n - 2]
        for i in 1 ..< n - 1 { m[i] = d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2 }
        for i in 0 ..< n - 1 {
            if d[i] == 0 { m[i] = 0; m[i + 1] = 0; continue }
            let a = m[i] / d[i], b = m[i + 1] / d[i], s = a * a + b * b
            if s > 9 { let t = 3 / s.squareRoot(); m[i] = t * a * d[i]; m[i + 1] = t * b * d[i] }
        }
        var i = 0
        while i < n - 2 && x > xs[i + 1] { i += 1 }
        let h = xs[i + 1] - xs[i], t = (x - xs[i]) / h
        let h00 = 2 * t * t * t - 3 * t * t + 1, h10 = t * t * t - 2 * t * t + t
        let h01 = -2 * t * t * t + 3 * t * t, h11 = t * t * t - t * t
        return min(1, max(0, h00 * ys[i] + h10 * h * m[i] + h01 * ys[i + 1] + h11 * h * m[i + 1]))
    }

    /// `anzahl` gleichmäßig verteilte Werte von x = 0 bis 1.
    func abtastung(_ anzahl: Int) -> [Float] {
        (0 ..< anzahl).map { Float(wert(bei: Double($0) / Double(max(1, anzahl - 1)))) }
    }

    // MARK: - Codable

    /// Beim Decodieren läuft die Eingabe durch denselben Initialisierer wie im Code —
    /// die Invariante gilt damit auch für Werte aus JSON.
    private enum CodingKeys: String, CodingKey { case points }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(try container.decode([CGPoint].self, forKey: .points))
    }
}
