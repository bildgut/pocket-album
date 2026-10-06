import Foundation
import Testing
@testable import ImmichPhone

@Suite("PhoneOrtsUebersicht")
struct PhoneOrtsUebersichtTests {
    private func laender(_ n: Int) -> [PhoneOrtsLand] {
        (0..<n).map { PhoneOrtsLand(name: "L\($0)", anzahl: 1, zuletzt: nil, titelbildId: nil, staedte: [], regionen: []) }
    }

    @Test("Sechs Länder als Kacheln, der Rest in die Liste — Reihenfolge bleibt")
    func sechsKacheln() {
        let teile = PhoneOrtsUebersicht.aufteilen(laender(9))
        #expect(teile.kacheln.map(\.name) == ["L0", "L1", "L2", "L3", "L4", "L5"])
        #expect(teile.rest.map(\.name) == ["L6", "L7", "L8"])
    }

    @Test("Bis sechs Länder gibt es keine Liste")
    func wenige() {
        #expect(PhoneOrtsUebersicht.aufteilen(laender(6)).rest.isEmpty)
        #expect(PhoneOrtsUebersicht.aufteilen(laender(2)).kacheln.count == 2)
        #expect(PhoneOrtsUebersicht.aufteilen([]).kacheln.isEmpty)
    }
}
