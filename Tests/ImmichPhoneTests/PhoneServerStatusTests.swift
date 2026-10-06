import Foundation
import Testing
@testable import ImmichPhone

// Prüft die Zuordnung von `ConnectionState` zu dem, was der Einstellungen-Reiter
// zeigt. Der Grund für den eigenen Wertetyp steht im Kopf von
// `Sources/ImmichPhone/PhoneServerStatus.swift`: Zwei der fünf Zustände tragen
// einen Wert vom Server (Version, Fehlermeldung), und genau diese beiden können
// leer hereinkommen — dann darf weder ein Mittelpunkt ohne Fortsetzung noch eine
// leere Zeile entstehen.
//
// Bewusst ohne `ConnectionManager`: Dessen `init` liest den Keychain, und ein Test
// hat auf den Zugangsdaten dieses Geräts nichts zu suchen.

@Suite("PhoneServerStatus")
struct PhoneServerStatusTests {

    @Test("Verbunden nennt die Serverversion und gilt als verbunden")
    func verbundenMitVersion() {
        let status = PhoneServerStatus.from(.connected(version: "1.119.0"))
        #expect(status.text == "Connected · Immich 1.119.0")
        #expect(status.istVerbunden)
        #expect(status.symbol == "checkmark.circle.fill")
    }

    @Test("Leere Version ergibt keinen Mittelpunkt ohne Fortsetzung")
    func verbundenOhneVersion() {
        #expect(PhoneServerStatus.from(.connected(version: "")).text == "Connected")
        #expect(PhoneServerStatus.from(.connected(version: "   ")).text == "Connected")
        #expect(PhoneServerStatus.from(.connected(version: "  ")).istVerbunden)
    }

    @Test("Offline gilt NICHT als verbunden")
    func offlineIstNichtVerbunden() {
        let status = PhoneServerStatus.from(.offline)
        #expect(!status.istVerbunden)
        #expect(status.text == "Offline · showing saved data")
    }

    @Test("Verbindet und nicht verbunden sind unterscheidbar")
    func zwischenzustaende() {
        let verbindet = PhoneServerStatus.from(.connecting)
        let getrennt = PhoneServerStatus.from(.disconnected)
        #expect(verbindet.text == "Connecting…")
        #expect(getrennt.text == "Not Connected")
        #expect(verbindet != getrennt)
        #expect(!verbindet.istVerbunden)
        #expect(!getrennt.istVerbunden)
    }

    @Test("Fehler zeigt die Meldung des Servers")
    func fehlerMitMeldung() {
        let status = PhoneServerStatus.from(.error("Server did not respond to ping"))
        #expect(status.text == "Error · Server did not respond to ping")
        #expect(status.symbol == "exclamationmark.triangle")
        #expect(!status.istVerbunden)
    }

    @Test("Leere Fehlermeldung ergibt keine leere Zeile")
    func fehlerOhneMeldung() {
        #expect(PhoneServerStatus.from(.error("")).text == "Error")
        #expect(PhoneServerStatus.from(.error("\n  ")).text == "Error")
    }

    @Test("Jeder Zustand hat ein Symbol, und keine zwei Zustände sind gleich")
    func alleZustaendeUnterscheidbar() {
        let zustaende: [ConnectionState] = [
            .connected(version: "1.0"), .offline, .connecting, .disconnected, .error("x")
        ]
        let ergebnisse = zustaende.map(PhoneServerStatus.from)
        for ergebnis in ergebnisse {
            #expect(!ergebnis.symbol.isEmpty)
            #expect(!ergebnis.text.isEmpty)
        }
        #expect(Set(ergebnisse.map(\.text)).count == zustaende.count)
        // Genau einer der fünf ist „verbunden" — `.offline` sieht im Raster zwar
        // benutzbar aus, der Server antwortet dabei aber nicht.
        #expect(ergebnisse.filter(\.istVerbunden).count == 1)
    }
}
