import Foundation

/// OkLab / OkLCh (Björn Ottosson, 2020) auf **Display-P3-kodierten** Werten (0…1, sRGB-Kennlinie).
///
/// Der Würfel für `CIColorCubeWithColorSpace` bekommt seine Gitterpunkte in der Kodierung des
/// angegebenen Farbraums — hier Display P3, wie beim HSL-Würfel. Die Matrizen gehen deshalb
/// von linearem P3 aus. Reine Mathematik ohne CoreImage: deterministisch und unit-testbar.
enum OkLab {

    // MARK: - Matrizen

    private typealias Mat = [[Double]]

    /// Lineares Display P3 (D65) → XYZ.
    private static let p3ToXYZ: Mat = [
        [0.4865709486, 0.2656676932, 0.1982172852],
        [0.2289745641, 0.6917385218, 0.0792869141],
        [0.0,          0.0451133819, 1.0439443689],
    ]
    /// XYZ → LMS (Ottosson, M1).
    private static let xyzToLMS: Mat = [
        [0.8189330101, 0.3618667424, -0.1288597137],
        [0.0329845436, 0.9293118715,  0.0361456387],
        [0.0482003018, 0.2643662691,  0.6338517070],
    ]
    /// Kubikwurzel-LMS → Lab (Ottosson, M2).
    private static let lmsToLab: Mat = [
        [0.2104542553,  0.7936177850, -0.0040720468],
        [1.9779984951, -2.4285922050,  0.4505937099],
        [0.0259040371,  0.7827717662, -0.8086757660],
    ]

    /// Zeilen auf Summe 1 normiert: Weiß (1,1,1) wird so exakt zu gleichem LMS und damit zu
    /// a = b = 0. Mit den auf zehn Stellen gerundeten Konstanten bliebe sonst eine kleine
    /// Chroma auf der ganzen Grauachse, und Lebendigkeit färbte Grau leicht ein.
    private static let toLMS: Mat = multiply(xyzToLMS, p3ToXYZ).map { zeile in
        let summe = zeile.reduce(0, +)
        return zeile.map { $0 / summe }
    }
    private static let fromLMS: Mat = invert(toLMS)
    private static let fromLab: Mat = invert(lmsToLab)

    // MARK: - Konvertierung

    /// Display-P3-kodiert (0…1) → OkLab `(L, a, b)`.
    static func fromEncodedP3(r: Double, g: Double, b: Double) -> (L: Double, a: Double, b: Double) {
        let lin = [decode(r), decode(g), decode(b)]
        let lms = apply(toLMS, lin).map { cbrt($0) }
        let lab = apply(lmsToLab, lms)
        return (lab[0], lab[1], lab[2])
    }

    /// OkLab → Display-P3-kodiert. **Nicht geclampt** — der Aufrufer entscheidet, ob er die
    /// Gamut-Grenze beachtet (siehe `FarbCube`).
    static func toEncodedP3(L: Double, a: Double, b: Double) -> (r: Double, g: Double, b: Double) {
        let lmsCbrt = apply(fromLab, [L, a, b])
        let lms = lmsCbrt.map { $0 * $0 * $0 }
        let lin = apply(fromLMS, lms)
        return (encode(lin[0]), encode(lin[1]), encode(lin[2]))
    }

    /// Ob alle drei Kanäle im darstellbaren Bereich liegen (mit kleiner Rundungstoleranz).
    static func istImGamut(_ rgb: (r: Double, g: Double, b: Double)) -> Bool {
        let e = 1e-6
        return (-e ... 1 + e).contains(rgb.r) && (-e ... 1 + e).contains(rgb.g) && (-e ... 1 + e).contains(rgb.b)
    }

    // MARK: - sRGB-Kennlinie (P3 teilt sie)

    static func decode(_ v: Double) -> Double {
        let a = abs(v)
        let lin = a <= 0.04045 ? a / 12.92 : pow((a + 0.055) / 1.055, 2.4)
        return v < 0 ? -lin : lin
    }

    static func encode(_ v: Double) -> Double {
        let a = abs(v)
        let enc = a <= 0.0031308 ? a * 12.92 : 1.055 * pow(a, 1 / 2.4) - 0.055
        return v < 0 ? -enc : enc
    }

    // MARK: - 3×3-Helfer

    private static func apply(_ m: Mat, _ v: [Double]) -> [Double] {
        [
            m[0][0] * v[0] + m[0][1] * v[1] + m[0][2] * v[2],
            m[1][0] * v[0] + m[1][1] * v[1] + m[1][2] * v[2],
            m[2][0] * v[0] + m[2][1] * v[1] + m[2][2] * v[2],
        ]
    }

    private static func multiply(_ a: Mat, _ b: Mat) -> Mat {
        (0 ..< 3).map { i in (0 ..< 3).map { j in (0 ..< 3).reduce(0.0) { $0 + a[i][$1] * b[$1][j] } } }
    }

    private static func invert(_ m: Mat) -> Mat {
        let (a, b, c) = (m[0][0], m[0][1], m[0][2])
        let (d, e, f) = (m[1][0], m[1][1], m[1][2])
        let (g, h, i) = (m[2][0], m[2][1], m[2][2])
        let det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
        let k = 1 / det
        return [
            [(e * i - f * h) * k, (c * h - b * i) * k, (b * f - c * e) * k],
            [(f * g - d * i) * k, (a * i - c * g) * k, (c * d - a * f) * k],
            [(d * h - e * g) * k, (b * g - a * h) * k, (a * e - b * d) * k],
        ]
    }
}
