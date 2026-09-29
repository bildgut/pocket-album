import Foundation
import Testing
@testable import ImmichPhone

private func land(_ name: String, zuletzt: String?, anzahl: Int = 10) -> PhoneOrtsLand {
    PhoneOrtsLand(name: name, anzahl: anzahl, zuletzt: zuletzt, titelbildId: nil, staedte: [], regionen: [])
}

private func katalog(_ laender: [PhoneOrtsLand], aufgebautAm: Date? = nil, basis: String = "https://immich.example") -> PhoneOrtsKatalog {
    PhoneOrtsKatalog(basis: basis, laender: laender, aufgebautAm: aufgebautAm)
}

@Suite("PhoneOrtsKatalog")
struct PhoneOrtsKatalogTests {

    @Test("Jüngstes Foto zuerst, Länder ohne Datum ans Ende")
    func sortierung() {
        let k = katalog([
            land("Austria", zuletzt: nil),
            land("Greece", zuletzt: "2026-06-29T12:00:00.000Z"),
            land("Japan", zuletzt: nil),
            land("Germany", zuletzt: "2026-09-06T08:00:00.000Z"),
        ])
        #expect(k.nachZuletzt.map(\.name) == ["Germany", "Greece", "Austria", "Japan"])
    }

    @Test("Bei gleichem Zeitstempel entscheidet der Name")
    func gleicheZeit() {
        let k = katalog([
            land("Poland", zuletzt: "2026-04-03T10:00:00.000Z"),
            land("Ireland", zuletzt: "2026-04-03T10:00:00.000Z"),
        ])
        #expect(k.nachZuletzt.map(\.name) == ["Ireland", "Poland"])
    }

    @Test("Frisch heißt jünger als 15 Minuten; ohne Zeitstempel nie frisch")
    func frische() {
        let t = Date(timeIntervalSince1970: 1_000_000)
        #expect(katalog([], aufgebautAm: t).istFrisch(jetzt: t.addingTimeInterval(14 * 60)))
        #expect(!katalog([], aufgebautAm: t).istFrisch(jetzt: t.addingTimeInterval(15 * 60)))
        #expect(!katalog([], aufgebautAm: nil).istFrisch(jetzt: t))
    }

    @Test("land(_:) findet ein Land über den Namen")
    func landSuchen() {
        let k = katalog([land("Japan", zuletzt: nil)])
        #expect(k.land("Japan")?.name == "Japan")
        #expect(k.land("Peru") == nil)
    }
}

@Suite("PhoneOrtsKatalogSpeicher")
struct PhoneOrtsKatalogSpeicherTests {

    private let basis = URL(string: "https://immich.example")!

    private func speicher() -> PhoneOrtsKatalogSpeicher {
        let ordner = FileManager.default.temporaryDirectory.appending(path: "orte-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true)
        return PhoneOrtsKatalogSpeicher(datei: ordner.appending(path: "orte_katalog.json"))
    }

    @Test("Geschriebener Katalog kommt unverändert zurück")
    func hinUndZurueck() throws {
        let s = speicher()
        var k = katalog([land("Japan", zuletzt: "2025-11-24T08:10:23.000Z")], aufgebautAm: Date(timeIntervalSince1970: 42))
        k.staedteAnzahlen["Japan"] = [PhoneOrtsChip(id: "Kyoto", titel: "Kyoto", anzahl: 758)]
        try s.speichern(k)
        #expect(s.laden(basis: basis) == k)
    }

    @Test("Keine Datei ergibt keinen Katalog")
    func fehlend() {
        #expect(speicher().laden(basis: basis) == nil)
    }

    @Test("Defektes JSON ergibt keinen Katalog statt eines Wurfs")
    func defekt() throws {
        let s = speicher()
        try Data("{kaputt".utf8).write(to: s.datei)
        #expect(s.laden(basis: basis) == nil)
    }

    @Test("Eine fremde Version wird nicht gelesen")
    func fremdeVersion() throws {
        let s = speicher()
        var k = katalog([])
        k.version = PhoneOrtsKatalog.aktuelleVersion + 1
        try s.speichern(k)
        #expect(s.laden(basis: basis) == nil)
    }

    @Test("Der Katalog eines anderen Servers wird nicht gezeigt")
    func andererServer() throws {
        let s = speicher()
        try s.speichern(katalog([], basis: "https://anderer.example"))
        #expect(s.laden(basis: basis) == nil)
    }

    @Test("loeschen entfernt die Datei")
    func loeschen() throws {
        let s = speicher()
        try s.speichern(katalog([]))
        s.loeschen()
        #expect(!FileManager.default.fileExists(atPath: s.datei.path))
    }
}
