import Foundation
import Testing
@testable import ImmichPhone

@Suite("Onboarding-API", .serialized)
struct OnboardingAPITests {
    private static let host = "onboarding-api.test"

    private static var konfiguration: URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OrteMockURLProtocol.self]
        return config
    }

    @Test("Key anlegen schickt Name und Rechte per Bearer und liefert das Secret")
    func keyAnlegen() async throws {
        let mitschnitt = OrteMitschnitt()
        OrteMockURLProtocol.registriere(host: Self.host) { request, koerper in
            mitschnitt.merke(request, koerper)
            return (201, Data(#"{"secret":"NEU-123","apiKey":{"id":"00000000-0000-4000-8000-000000000000","name":"Pocket Album (iPhone)","createdAt":"2026-01-01T00:00:00.000Z","updatedAt":"2026-01-01T00:00:00.000Z","permissions":["album.read"]}}"#.utf8))
        }
        defer { OrteMockURLProtocol.entferne(host: Self.host) }

        let secret = try await ImmichAPIClient.erstelleApiKey(
            baseURL: URL(string: "https://\(Self.host)")!, sessionToken: "TOKEN",
            name: "Pocket Album (iPhone)", rechte: ["album.read", "asset.read"],
            sessionConfiguration: Self.konfiguration
        )

        #expect(secret == "NEU-123")
        let anfrage = try #require(mitschnitt.alle.first)
        #expect(anfrage.request.httpMethod == "POST")
        #expect(anfrage.request.url?.path == "/api/api-keys")
        #expect(anfrage.request.value(forHTTPHeaderField: "Authorization") == "Bearer TOKEN")
        #expect(anfrage.request.value(forHTTPHeaderField: "x-api-key") == nil)
        let json = OrteMockURLProtocol.json(anfrage.koerper)
        #expect(json["name"] as? String == "Pocket Album (iPhone)")
        #expect(json["permissions"] as? [String] == ["album.read", "asset.read"])
    }

    @Test("Scheitert die Anlage, kommt der Status als Fehler")
    func keyAnlegenFehler() async {
        OrteMockURLProtocol.registriere(host: Self.host) { _, _ in (403, Data()) }
        defer { OrteMockURLProtocol.entferne(host: Self.host) }
        await #expect(throws: APIError.httpError(403)) {
            _ = try await ImmichAPIClient.erstelleApiKey(
                baseURL: URL(string: "https://\(Self.host)")!, sessionToken: "T",
                name: "x", rechte: [], sessionConfiguration: Self.konfiguration)
        }
    }

    @Test("Passwort-Login laut server/features")
    func passwortLogin() async throws {
        let mitschnitt = OrteMitschnitt()
        OrteMockURLProtocol.registriere(host: Self.host) { request, koerper in
            mitschnitt.merke(request, koerper)
            return (200, Data(#"{"passwordLogin":false,"oauth":true}"#.utf8))
        }
        defer { OrteMockURLProtocol.entferne(host: Self.host) }
        #expect(try await OrteMockURLProtocol.client(host: Self.host).passwortLoginErlaubt() == false)
        #expect(mitschnitt.alle.map { $0.request.url?.path } == ["/api/server/features"])
    }
}
