import Foundation
import Testing
@testable import ImmichPhone

// Nutzerwunsch 13.09.2026: Ein erneuter Tipp auf den schon aktiven Reiter führt
// zurück zur Startseite — seit September 2026 für „Entdecken“ (vorher „Orte“).

@Suite("PhoneReiterWahl")
struct PhoneReiterWahlTests {

    @Test("Erneuter Tipp auf den aktiven Entdecken-Reiter setzt zurück")
    func entdeckenNochmal() {
        #expect(PhoneReiterWahl.setztEntdeckenZurueck(aktuell: .entdecken, getippt: .entdecken))
    }

    @Test("Der Wechsel zu Entdecken aus einem anderen Reiter setzt nicht zurück")
    func wechselZuEntdecken() {
        for anderer in [PhoneReiter.alben, .fotos, .einstellungen] {
            #expect(!PhoneReiterWahl.setztEntdeckenZurueck(aktuell: anderer, getippt: .entdecken))
        }
    }

    @Test("Das Verlassen von Entdecken setzt nicht zurück")
    func verlassen() {
        #expect(!PhoneReiterWahl.setztEntdeckenZurueck(aktuell: .entdecken, getippt: .fotos))
    }

    @Test("Erneute Tipps auf andere Reiter setzen nicht zurück")
    func andereReiterNochmal() {
        for reiter in [PhoneReiter.alben, .fotos, .einstellungen] {
            #expect(!PhoneReiterWahl.setztEntdeckenZurueck(aktuell: reiter, getippt: reiter))
        }
    }

    @Test("Vier Reiter in der Standardreihenfolge des Tab-Balkens")
    func reihenfolge() {
        #expect(PhoneReiter.allCases == [.fotos, .alben, .entdecken, .einstellungen])
    }

    @Test("Standardwert des ersten Reiters ist Fotos")
    func ersterReiterStandard() {
        let (defaults, suite) = frischeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(PhoneReiterWahl.ersterReiter(defaults: defaults) == .fotos)
        #expect(PhoneReiterWahl.reihenfolge(erster: .fotos) == [.fotos, .alben, .entdecken, .einstellungen])
    }

    @Test("Ersten Reiter auf Alben umstellen tauscht die ersten beiden Positionen")
    func ersterReiterAlben() {
        let (defaults, suite) = frischeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        PhoneReiterWahl.setzeErstenReiter(.alben, defaults: defaults)
        #expect(PhoneReiterWahl.ersterReiter(defaults: defaults) == .alben)
        #expect(PhoneReiterWahl.reihenfolge(erster: .alben) == [.alben, .fotos, .entdecken, .einstellungen])

        PhoneReiterWahl.setzeErstenReiter(.fotos, defaults: defaults)
        #expect(PhoneReiterWahl.ersterReiter(defaults: defaults) == .fotos)
    }

    @Test("Ungültige Werte in UserDefaults fallen sicher auf Fotos zurück")
    func ersterReiterUngueltig() {
        let (defaults, suite) = frischeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("entdecken", forKey: PhoneReiterWahl.startReiterSchluessel)
        #expect(PhoneReiterWahl.ersterReiter(defaults: defaults) == .fotos)
        #expect(PhoneReiterWahl.reihenfolge(erster: .entdecken) == [.fotos, .alben, .entdecken, .einstellungen])
    }

    // Smart Alben spiegelt nur der Mac-Client auf den Server. Ihr Abschnitt im
    // Alben-Reiter erscheint deshalb erst, wenn es mindestens ein solches Album gibt.

    @Test("Ohne gespiegelte Smart Alben kein Smart-Abschnitt")
    func ohneSpiegel() {
        #expect(!PhoneReiterWahl.zeigtSmartAlben(alben: []))
        #expect(!PhoneReiterWahl.zeigtSmartAlben(alben: [album("Urlaub"), album("✦Wichtig")]))
    }

    @Test("Ein gespiegeltes Smart Album, eigen oder geteilt, zeigt den Abschnitt")
    func mitSpiegel() {
        #expect(PhoneReiterWahl.zeigtSmartAlben(alben: [album("Urlaub"), album("✦ Hunde")]))
    }
}

private func frischeDefaults() -> (UserDefaults, String) {
    let suite = "PhoneReiterWahlTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return (defaults, suite)
}

private func album(_ name: String) -> Album {
    Album(
        id: name, albumName: name, description: nil,
        createdAt: "2026-01-01T00:00:00.000Z", updatedAt: "2026-01-01T00:00:00.000Z",
        startDate: nil, endDate: nil, assetCount: 0, albumThumbnailAssetId: nil,
        shared: nil, hasSharedLink: nil, owner: nil
    )
}
