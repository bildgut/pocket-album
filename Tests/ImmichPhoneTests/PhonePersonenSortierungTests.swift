import Testing
@testable import ImmichPhone

@Suite("PhonePersonenSortierung")
struct PhonePersonenSortierungTests {

    private func person(_ name: String) -> Person {
        Person(id: name, name: name, birthDate: nil, thumbnailPath: nil,
               isHidden: nil, isFavorite: nil, assetCount: nil)
    }

    private func namen(_ personen: [Person]) -> [String] { personen.map(\.name) }

    @Test("Häufigkeit behält die Server-Reihenfolge")
    func haeufigkeitBehaeltServerReihenfolge() {
        let eingabe = [person("Zoe"), person("anna"), person("Mia")]
        let ergebnis = PhonePersonenSortierung.personen(eingabe, sortierung: .haeufigkeit, suche: "")
        #expect(namen(ergebnis) == ["Zoe", "anna", "Mia"])
    }

    @Test("Name sortiert alphabetisch")
    func nameSortiertAlphabetisch() {
        let eingabe = [person("Zoe"), person("anna"), person("Mia")]
        let ergebnis = PhonePersonenSortierung.personen(eingabe, sortierung: .name, suche: "")
        #expect(namen(ergebnis) == ["anna", "Mia", "Zoe"])
    }

    @Test("Unbenannte fallen weg", arguments: PhonePersonenSortierung.allCases)
    func unbenannteFallenWeg(sortierung: PhonePersonenSortierung) {
        let eingabe = [person(""), person("  "), person("Mia")]
        let ergebnis = PhonePersonenSortierung.personen(eingabe, sortierung: sortierung, suche: "")
        #expect(namen(ergebnis) == ["Mia"])
    }

    @Test("Suche filtert ohne umzusortieren")
    func sucheFiltertOhneUmzusortieren() {
        let eingabe = [person("Mia"), person("Max"), person("Lena")]
        let ergebnis = PhonePersonenSortierung.personen(eingabe, sortierung: .haeufigkeit, suche: "m")
        #expect(namen(ergebnis) == ["Mia", "Max"])
    }

    @Test("Suche aus Leerraum zeigt alle")
    func sucheIgnoriertLeerraum() {
        let eingabe = [person("Mia"), person("Max"), person("Lena")]
        let ergebnis = PhonePersonenSortierung.personen(eingabe, sortierung: .haeufigkeit, suche: "  ")
        #expect(namen(ergebnis) == ["Mia", "Max", "Lena"])
    }
}
