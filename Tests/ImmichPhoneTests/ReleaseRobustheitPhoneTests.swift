import Foundation
import Network
import Testing
@testable import ImmichPhone

@Suite("Versionsprüfung beim Wiederverbinden")
@MainActor
struct PhoneVersionsTorTests {

    @Test func zuAlterServerErgibtDieOnboardingMeldung() {
        #expect(PhoneVersionsTor.meldung(fuerVersion: "3.1.9") == OnboardingTexts.serverZuAlt("3.1.9"))
        #expect(PhoneVersionsTor.meldung(fuerVersion: "v2.9.0") == OnboardingTexts.serverZuAlt("2.9.0"))
    }

    @Test func aktuellerOderUnlesbarerServerSperrtNicht() {
        #expect(PhoneVersionsTor.meldung(fuerVersion: "3.2.0") == nil)
        #expect(PhoneVersionsTor.meldung(fuerVersion: "4.0.1") == nil)
        #expect(PhoneVersionsTor.meldung(fuerVersion: "unbekannt") == nil)
    }

    @Test func pruefeSetztVerbindungAufFehler() {
        let connection = ConnectionManager()
        connection.state = .connected(version: "3.1.0")
        PhoneVersionsTor.pruefe(connection)
        #expect(connection.state == .error(OnboardingTexts.serverZuAlt("3.1.0")))

        connection.state = .connected(version: "3.2.2")
        PhoneVersionsTor.pruefe(connection)
        #expect(connection.state == .connected(version: "3.2.2"))
    }
}

/// Minimaler HTTP-Server auf einem echten Socket: merkt sich die Anfragen und
/// antwortet mit einem festen Text.
private final class TestServer: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var _anfragen: [String] = []
    var antwort: String = ""

    var anfragen: [String] { lock.withLock { _anfragen } }

    init() throws { listener = try NWListener(using: .tcp, on: .any) }

    func start() async -> UInt16 {
        await withCheckedContinuation { fortsetzung in
            let einmal = NSLock(); var fertig = false
            listener.stateUpdateHandler = { zustand in
                if case .ready = zustand {
                    einmal.withLock { if !fertig { fertig = true; fortsetzung.resume() } }
                }
            }
            listener.newConnectionHandler = { [self] verbindung in
                verbindung.start(queue: .global())
                verbindung.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { daten, _, _, _ in
                    let text = String(decoding: daten ?? Data(), as: UTF8.self)
                    self.lock.withLock { self._anfragen.append(text) }
                    verbindung.send(content: Data(self.antwort.utf8), completion: .contentProcessed { _ in verbindung.cancel() })
                }
            }
            listener.start(queue: .global())
        }
        return listener.port!.rawValue
    }

    func stop() { listener.cancel() }
}

/// Der Beleg hinter ``SichereWeiterleitung``: an echten Sockets, nicht am
/// URLProtocol-Mock — dort bestimmte der Mock selbst, welche Kopfzeilen die
/// umgeleitete Anfrage trägt. 127.0.0.1 und localhost gelten URLSession als zwei Hosts.
@Suite("Weiterleitung an fremden Host", .serialized)
struct SichereWeiterleitungBelegTests {

    private func aufbau() async throws -> (quelle: URL, ziel: TestServer, weg: () -> Void) {
        let ziel = try TestServer()
        ziel.antwort = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
        let zielPort = await ziel.start()
        let umleiter = try TestServer()
        umleiter.antwort = "HTTP/1.1 302 Found\r\nLocation: http://localhost:\(zielPort)/ziel\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        let quellPort = await umleiter.start()
        return (URL(string: "http://127.0.0.1:\(quellPort)/api/albums")!, ziel, { ziel.stop(); umleiter.stop() })
    }

    @Test("Ohne Delegaten landet der Default-Header beim fremden Host")
    func ohneDelegatLecktDerSchluessel() async throws {
        let (quelle, ziel, weg) = try await aufbau()
        defer { weg() }
        let config = URLSessionConfiguration.ephemeral
        config.httpAdditionalHeaders = ["x-api-key": "GEHEIM"]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        _ = try? await session.data(from: quelle)
        #expect(ziel.anfragen.count == 1)
        #expect(ziel.anfragen.first?.lowercased().contains("x-api-key: geheim") == true)
    }

    @Test("Mit Delegaten erreicht den fremden Host gar keine Anfrage")
    func mitDelegatBleibtDerSchluesselDaheim() async throws {
        let (quelle, ziel, weg) = try await aufbau()
        defer { weg() }
        let config = URLSessionConfiguration.ephemeral
        config.httpAdditionalHeaders = ["x-api-key": "GEHEIM"]
        let session = URLSession.mitSichererWeiterleitung(config)
        defer { session.invalidateAndCancel() }
        let (_, antwort) = try await session.data(from: quelle)
        #expect((antwort as? HTTPURLResponse)?.statusCode == 302)
        #expect(ziel.anfragen.isEmpty)
    }

    @Test("Auch der ImmichAPIClient folgt nicht")
    func apiClientFolgtNicht() async throws {
        let (quelle, ziel, weg) = try await aufbau()
        defer { weg() }
        let basis = quelle.deletingLastPathComponent().deletingLastPathComponent()
        let client = ImmichAPIClient(baseURL: basis, apiKey: "GEHEIM", sessionConfiguration: .ephemeral)
        _ = try? await client.getAlbums()
        #expect(ziel.anfragen.isEmpty)
    }
}
