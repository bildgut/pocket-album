import Testing
import Foundation
@testable import ImmichPhone

@Suite("OfflineWiederholung")
struct OfflineWiederholungTests {

    private struct Netzfehler: Error {}

    /// Zählt Aufrufe über Aufrufe hinweg, ohne Datenwettlauf.
    private actor Zaehler {
        private(set) var wert = 0
        func erhoehe() -> Int { wert += 1; return wert }
    }

    @Test("Gelingt beim ersten Mal ohne Wiederholung")
    func ersterVersuchGelingt() async throws {
        let zaehler = Zaehler()
        let ergebnis = try await OfflineWiederholung.mitWiederholung(versuche: 3, pause: .zero) {
            _ = await zaehler.erhoehe()
            return "ok"
        }
        #expect(ergebnis == "ok")
        #expect(await zaehler.wert == 1)
    }

    @Test("Wiederholt nach Timeout und gelingt dann")
    func wiederholtNachTimeout() async throws {
        let zaehler = Zaehler()
        let ergebnis = try await OfflineWiederholung.mitWiederholung(versuche: 3, pause: .zero) {
            if await zaehler.erhoehe() < 3 { throw URLError(.timedOut) }
            return "ok"
        }
        #expect(ergebnis == "ok")
        #expect(await zaehler.wert == 3)
    }

    @Test("Gibt nach allen Versuchen den letzten Fehler weiter")
    func gibtAuf() async {
        let zaehler = Zaehler()
        await #expect(throws: URLError.self) {
            try await OfflineWiederholung.mitWiederholung(versuche: 3, pause: .zero) {
                _ = await zaehler.erhoehe()
                throw URLError(.networkConnectionLost)
            } as String
        }
        #expect(await zaehler.wert == 3)
    }

    @Test("4xx wird nicht wiederholt")
    func clientFehlerBleibt() async {
        let zaehler = Zaehler()
        await #expect(throws: APIError.self) {
            try await OfflineWiederholung.mitWiederholung(versuche: 3, pause: .zero) {
                _ = await zaehler.erhoehe()
                throw APIError.httpError(404)
            } as String
        }
        #expect(await zaehler.wert == 1)
    }

    @Test("5xx wird wiederholt")
    func serverFehlerWirdWiederholt() async {
        let zaehler = Zaehler()
        await #expect(throws: APIError.self) {
            try await OfflineWiederholung.mitWiederholung(versuche: 2, pause: .zero) {
                _ = await zaehler.erhoehe()
                throw APIError.httpError(503)
            } as String
        }
        #expect(await zaehler.wert == 2)
    }

    @Test("Abbruch wird nicht wiederholt")
    func abbruchBleibt() async {
        let zaehler = Zaehler()
        await #expect(throws: CancellationError.self) {
            try await OfflineWiederholung.mitWiederholung(versuche: 3, pause: .zero) {
                _ = await zaehler.erhoehe()
                throw CancellationError()
            } as String
        }
        #expect(await zaehler.wert == 1)
    }

    @Test("URLError.cancelled wird nicht wiederholt")
    func urlAbbruchBleibt() async {
        let zaehler = Zaehler()
        await #expect(throws: URLError.self) {
            try await OfflineWiederholung.mitWiederholung(versuche: 3, pause: .zero) {
                _ = await zaehler.erhoehe()
                throw URLError(.cancelled)
            } as String
        }
        #expect(await zaehler.wert == 1)
    }
}
