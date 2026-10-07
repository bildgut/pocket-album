import SwiftUI

/// Spalten der Raster, abhängig von der verfügbaren Breite statt fest verdrahtet.
///
/// Mit festen 2 bzw. 3 Spalten würden die Kacheln auf dem iPad riesig. `.adaptive`
/// füllt die Zeile mit so vielen Spalten, wie der Mindestwert zulässt: auf dem
/// iPhone ergibt das dieselben 3 bzw. 2 Spalten wie vorher, auf dem iPad Air mehr.
enum PhoneRasterSpalten {

    /// Mindestbreite einer Foto-Kachel. Auf dem iPhone (≥ 375 pt) bleibt es bei 3 Spalten.
    static let fotoMinimum: CGFloat = 120
    /// Mindestbreite einer Album-/Länderkachel. Auf dem iPhone bleibt es bei 2 Spalten.
    static let kachelMinimum: CGFloat = 160

    /// Dichtes Foto-Raster (2 pt Abstand).
    static let fotos = [GridItem(.adaptive(minimum: fotoMinimum), spacing: 2)]
    /// Kachelraster für Alben und Länder (12 pt Abstand).
    static let kacheln = [GridItem(.adaptive(minimum: kachelMinimum), spacing: 12)]

    /// Wie viele Spalten SwiftUI bei `.adaptive` bildet — für Tests und Rechnungen.
    static func anzahl(breite: CGFloat, minimum: CGFloat, abstand: CGFloat) -> Int {
        guard breite >= minimum else { return 1 }
        return max(1, Int(((breite + abstand) / (minimum + abstand)).rounded(.down)))
    }
}
