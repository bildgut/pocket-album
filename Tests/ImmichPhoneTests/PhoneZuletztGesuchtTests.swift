import Foundation
import Testing
@testable import ImmichPhone

@Suite("PhoneZuletztGesucht")
struct PhoneZuletztGesuchtTests {
    private func frisch() -> UserDefaults { UserDefaults(suiteName: "Zuletzt-\(UUID().uuidString)")! }
    private func eintrag(_ jahr: Int) -> PhoneZuletztEintrag {
        PhoneZuletztEintrag(auswahl: .jahr(jahr), personenNamen: [:], titel: "\(jahr)", anzahl: 1)
    }

    @Test("Höchstens fünf, jüngster zuerst")
    func fuenf() {
        let d = frisch()
        for j in 2010...2016 { PhoneZuletztGesucht.merke(eintrag(j), basis: "A", defaults: d) }
        #expect(PhoneZuletztGesucht.lade(basis: "A", defaults: d).map(\.titel) == ["2016", "2015", "2014", "2013", "2012"])
    }

    @Test("Gleiche Auswahl rückt nach oben statt doppelt")
    func nachOben() {
        let d = frisch()
        PhoneZuletztGesucht.merke(eintrag(2019), basis: "A", defaults: d)
        PhoneZuletztGesucht.merke(eintrag(2020), basis: "A", defaults: d)
        PhoneZuletztGesucht.merke(eintrag(2019), basis: "A", defaults: d)
        #expect(PhoneZuletztGesucht.lade(basis: "A", defaults: d).map(\.titel) == ["2019", "2020"])
    }

    @Test("Je Server getrennt")
    func jeServer() {
        let d = frisch()
        PhoneZuletztGesucht.merke(eintrag(2019), basis: "A", defaults: d)
        #expect(PhoneZuletztGesucht.lade(basis: "B", defaults: d).isEmpty)
    }

    @Test("Entfernen und Vergessen")
    func entfernen() {
        let d = frisch()
        PhoneZuletztGesucht.merke(eintrag(2019), basis: "A", defaults: d)
        PhoneZuletztGesucht.merke(eintrag(2020), basis: "A", defaults: d)
        PhoneZuletztGesucht.entferne(.jahr(2020), basis: "A", defaults: d)
        #expect(PhoneZuletztGesucht.lade(basis: "A", defaults: d).map(\.titel) == ["2019"])
        PhoneZuletztGesucht.vergiss(defaults: d)
        #expect(PhoneZuletztGesucht.lade(basis: "A", defaults: d).isEmpty)
    }
}
