import Foundation

/// Je eine Kurve für Rot, Grün und Blau — das, was Pixelmators Presets als `r`/`g`/`b`
/// mitbringen und was ein einzelner `CIToneCurve` (wirkt auf alle Kanäle gleich) nicht
/// kann. Der Renderer tastet sie ab und gibt sie `CIColorCurves` als dreikanalige
/// Tabelle.
struct KanalKurven: Codable, Equatable, Sendable {
    var rot: ToneCurve
    var gruen: ToneCurve
    var blau: ToneCurve

    static let identity = KanalKurven(rot: .identity, gruen: .identity, blau: .identity)

    var isIdentity: Bool { rot.isIdentity && gruen.isIdentity && blau.isIdentity }

    /// Verschränkte Tabelle `r0 g0 b0 r1 g1 b1 …` mit `anzahl` Stützstellen je Kanal —
    /// das Layout von `CIColorCurves.curvesData` (Float32).
    func tabelle(_ anzahl: Int) -> [Float] {
        let r = rot.abtastung(anzahl), g = gruen.abtastung(anzahl), b = blau.abtastung(anzahl)
        var out = [Float](); out.reserveCapacity(anzahl * 3)
        for i in 0 ..< anzahl { out.append(r[i]); out.append(g[i]); out.append(b[i]) }
        return out
    }
}
