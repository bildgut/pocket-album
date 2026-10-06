import Foundation
import Testing
@testable import ImmichPhone

// `ping` und `server/version` brauchen keinen Schlüssel. Ohne eigene Prüfung
// "verband" ein vertippter oder zu schwach berechtigter API-Key scheinbar
// erfolgreich, und danach blieben alle Reiter leer. `pruefeSchluessel` fragt
// deshalb einmal die Albumliste ab (`album.read`, das jede Nutzung braucht).

@Suite("API-Key-Prüfung", .serialized)
struct SchluesselPruefungTests {

    private static let host = "schluessel.test"

    private func pruefe(status: Int) async throws {
        let mitschnitt = OrteMitschnitt()
        OrteMockURLProtocol.registriere(host: Self.host) { request, koerper in
            mitschnitt.merke(request, koerper)
            return (status, Data("[]".utf8))
        }
        defer { OrteMockURLProtocol.entferne(host: Self.host) }
        try await OrteMockURLProtocol.client(host: Self.host).pruefeSchluessel()
        #expect(mitschnitt.alle.map { $0.request.url?.path } == ["/api/albums"])
    }

    @Test("Ein gültiger Key besteht")
    func gueltig() async throws {
        try await pruefe(status: 200)
    }

    @Test("401 heißt: Key ungültig")
    func ungueltig() async {
        await #expect(throws: APIError.apiKeyRejected) { try await pruefe(status: 401) }
    }

    @Test("403 heißt: dem Key fehlt album.read")
    func ohneRecht() async {
        await #expect(throws: APIError.apiKeyLacksPermission("album.read")) { try await pruefe(status: 403) }
    }

    // Früher galt alles außer 401/403 als gültig — auch die 302 eines
    // Authelia-/Cloudflare-Access-Proxys und das 502 eines Proxys ohne Immich dahinter.
    @Test("5xx ist ein Serverfehler, kein gültiger Key")
    func serverFehler() async {
        await #expect(throws: APIError.serverFehler(500)) { try await pruefe(status: 500) }
        await #expect(throws: APIError.serverFehler(502)) { try await pruefe(status: 502) }
    }

    @Test("3xx heißt: ein Proxy will eine Anmeldung")
    func weiterleitung() async {
        await #expect(throws: APIError.anmeldeseiteDazwischen) { try await pruefe(status: 302) }
    }

    @Test("Nur 2xx ist gültig, anderes ist ein allgemeiner Fehler")
    func bewertung() throws {
        try ImmichAPIClient.bewerteSchluesselAntwort(status: 204)
        #expect(throws: APIError.httpError(404)) { try ImmichAPIClient.bewerteSchluesselAntwort(status: 404) }
    }

    @Test("Die eigenen Key-Rechte kommen aus /api/api-keys/me")
    func eigeneRechte() async throws {
        let mitschnitt = OrteMitschnitt()
        OrteMockURLProtocol.registriere(host: Self.host) { request, koerper in
            mitschnitt.merke(request, koerper)
            let json = #"{"id":"00000000-0000-4000-8000-000000000000","name":"Pocket","createdAt":"2026-01-01T00:00:00.000Z","updatedAt":"2026-01-01T00:00:00.000Z","permissions":["album.read","asset.read"]}"#
            return (200, Data(json.utf8))
        }
        defer { OrteMockURLProtocol.entferne(host: Self.host) }
        let rechte = try await OrteMockURLProtocol.client(host: Self.host).eigeneKeyRechte()
        #expect(rechte == ["album.read", "asset.read"])
        #expect(mitschnitt.alle.map { $0.request.url?.path } == ["/api/api-keys/me"])
    }

    @Test("Die Meldungen nennen den Grund, nicht den Statuscode")
    func meldungen() {
        #expect(APIError.apiKeyRejected.errorDescription?.contains("API key") == true)
        #expect(APIError.apiKeyLacksPermission("album.read").errorDescription?.contains("album.read") == true)
    }
}
