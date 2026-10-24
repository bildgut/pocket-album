import Foundation
import Testing
@testable import ImmichPhone

/// `getPeople` prüfte den HTTP-Status nicht: Eine 403 ohne `person.read` endete als
/// Dekodierfehler und war von einem Netzfehler nicht zu unterscheiden.
@Suite("Personen – fehlendes Recht", .serialized)
struct PersonenRechtTests {
    private let host = "personen-recht.test"

    @Test func dreihundertDreiWirdZuFehlendemRecht() async throws {
        OrteMockURLProtocol.registriere(host: host) { _, _ in (403, Data(#"{"message":"Missing permission"}"#.utf8)) }
        defer { OrteMockURLProtocol.entferne(host: host) }

        await #expect(throws: APIError.apiKeyLacksPermission("person.read")) {
            _ = try await OrteMockURLProtocol.client(host: host).getPeople()
        }
    }
}
