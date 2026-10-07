import Testing
import CoreGraphics
@testable import ImmichPhone

@Suite("PhoneRasterSpalten")
struct PhoneRasterSpaltenTests {

    @Test("iPhone behält 3 Foto-Spalten", arguments: [375, 390, 393, 430] as [CGFloat])
    func iPhoneFotos(breite: CGFloat) {
        #expect(PhoneRasterSpalten.anzahl(breite: breite - 4, minimum: PhoneRasterSpalten.fotoMinimum, abstand: 2) == 3)
    }

    @Test("iPhone behält 2 Kachel-Spalten", arguments: [375, 390, 393, 430] as [CGFloat])
    func iPhoneKacheln(breite: CGFloat) {
        #expect(PhoneRasterSpalten.anzahl(breite: breite - 32, minimum: PhoneRasterSpalten.kachelMinimum, abstand: 12) == 2)
    }

    @Test("iPad Air bekommt mehr Spalten")
    func iPad() {
        #expect(PhoneRasterSpalten.anzahl(breite: 820, minimum: PhoneRasterSpalten.fotoMinimum, abstand: 2) == 6)
        #expect(PhoneRasterSpalten.anzahl(breite: 1180, minimum: PhoneRasterSpalten.fotoMinimum, abstand: 2) == 9)
        #expect(PhoneRasterSpalten.anzahl(breite: 788, minimum: PhoneRasterSpalten.kachelMinimum, abstand: 12) == 4)
    }

    @Test("Schmale Breite ergibt eine Spalte")
    func schmal() {
        #expect(PhoneRasterSpalten.anzahl(breite: 50, minimum: 120, abstand: 2) == 1)
    }
}
