import Foundation
import Testing
@testable import ImmichPhone

// Wer einen Nur-Lese-Key anlegt, soll Favorit und Löschen gar nicht erst sehen.
// Zwei Quellen: was der Server über den Key meldet (`GET /api/api-keys/me`), und
// was ein Aufruf mit 403 verraten hat.

@Suite("KeyRechte")
struct KeyRechteTests {

    @Test("Unbekannte Rechte sperren nichts")
    func unbekannt() {
        let rechte = KeyRechte()
        #expect(rechte.darf(KeyRechte.favorit))
        #expect(rechte.darf(KeyRechte.loeschen))
    }

    @Test("„all“ darf alles")
    func alles() {
        let rechte = KeyRechte(gemeldet: ["all"])
        #expect(rechte.darf(KeyRechte.favorit))
        #expect(rechte.darf(KeyRechte.loeschen))
    }

    @Test("Ein Nur-Lese-Key darf weder Favorit noch Löschen")
    func nurLesen() {
        let rechte = KeyRechte(gemeldet: ["album.read", "asset.read", "asset.view", "asset.download"])
        #expect(!rechte.darf(KeyRechte.favorit))
        #expect(!rechte.darf(KeyRechte.loeschen))
    }

    @Test("Einzelne Rechte wirken einzeln")
    func einzeln() {
        let rechte = KeyRechte(gemeldet: ["asset.read", "asset.update"])
        #expect(rechte.darf(KeyRechte.favorit))
        #expect(!rechte.darf(KeyRechte.loeschen))
    }

    @Test("Ein 403 sperrt auch dann, wenn der Server nichts gemeldet hat")
    func gelernt() {
        var rechte = KeyRechte()
        rechte.merkeAbgelehnt(KeyRechte.loeschen)
        #expect(!rechte.darf(KeyRechte.loeschen))
        #expect(rechte.darf(KeyRechte.favorit))
    }

    @Test("Meldet der Server ein Recht wieder, gewinnt die Meldung")
    func neueMeldungHebtAuf() {
        // Die Rechte eines Keys lassen sich in Immich nachträglich ändern.
        var rechte = KeyRechte()
        rechte.merkeAbgelehnt(KeyRechte.favorit)
        rechte.uebernimmMeldung(["asset.update"])
        #expect(rechte.darf(KeyRechte.favorit))
        #expect(rechte.abgelehnt.isEmpty)
    }

    @Test("Eine Meldung ohne das Recht lässt die gelernte Sperre stehen")
    func meldungOhneRecht() {
        var rechte = KeyRechte()
        rechte.merkeAbgelehnt(KeyRechte.favorit)
        rechte.uebernimmMeldung(["asset.read"])
        #expect(!rechte.darf(KeyRechte.favorit))
    }
}

@Suite("KeyRechteSpeicher", .serialized)
struct KeyRechteSpeicherTests {

    private func frisch() -> UserDefaults {
        let name = "KeyRechteSpeicherTests-\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }

    @Test("Gelernte Sperren überleben einen Neustart mit demselben Key")
    func gleicherKey() {
        let defaults = frisch()
        KeyRechteSpeicher.speichereAbgelehnt([KeyRechte.loeschen], apiKey: "key-a", defaults: defaults)
        #expect(KeyRechteSpeicher.ladeAbgelehnt(apiKey: "key-a", defaults: defaults) == [KeyRechte.loeschen])
    }

    @Test("Ein anderer Key erbt keine Sperren")
    func andererKey() {
        let defaults = frisch()
        KeyRechteSpeicher.speichereAbgelehnt([KeyRechte.loeschen], apiKey: "key-a", defaults: defaults)
        #expect(KeyRechteSpeicher.ladeAbgelehnt(apiKey: "key-b", defaults: defaults).isEmpty)
    }

    @Test("Der Key selbst steht nicht in den Einstellungen")
    func keinKlartext() {
        let defaults = frisch()
        KeyRechteSpeicher.speichereAbgelehnt([KeyRechte.loeschen], apiKey: "geheimer-schluessel-123", defaults: defaults)
        let alles = defaults.dictionaryRepresentation().description
        #expect(!alles.contains("geheimer-schluessel-123"))
    }
}
