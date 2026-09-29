import Foundation
import Testing
@testable import ImmichPhone

// `URLSession` hält sich selbst am Leben, bis sie invalidiert wird. Ein Client,
// der seine Sessions nie schließt, lässt sie nach seiner Freigabe liegen — im
// Onboarding entsteht bei jedem Tastendruck einer. Ob `finishTasksAndInvalidate`
// lief, lässt sich von außen nicht beobachten; geprüft wird die Voraussetzung
// (der Client wird wirklich freigegeben, `deinit` läuft) und dass die Aufrufe
// mit aufgeräumten Einweg-Sessions weiter funktionieren.
@Suite("ImmichAPIClient: Sitzungen", .serialized)
struct ImmichAPIClientSitzungTests {
    private static let host = "sitzung.test"

    private static var konfiguration: URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OrteMockURLProtocol.self]
        return config
    }

    @Test("Ein Client wird nach Gebrauch freigegeben")
    func freigabe() async throws {
        OrteMockURLProtocol.registriere(host: Self.host) { _, _ in (200, Data(#"{"res":"pong"}"#.utf8)) }
        defer { OrteMockURLProtocol.entferne(host: Self.host) }
        weak var schwach: ImmichAPIClient?
        do {
            let client = OrteMockURLProtocol.client(host: Self.host)
            schwach = client
            #expect(try await client.ping())
        }
        #expect(schwach == nil)
    }

    @Test("Anmelden und Abmelden laufen mit aufgeräumten Einweg-Sessions")
    func einwegSitzungen() async throws {
        let mitschnitt = OrteMitschnitt()
        OrteMockURLProtocol.registriere(host: Self.host) { r, k in
            mitschnitt.merke(r, k)
            return r.url?.path == "/api/auth/login"
                ? (201, Data(#"{"accessToken":"T","userId":"u","userEmail":"a@b.c","name":"A"}"#.utf8))
                : (200, Data("{}".utf8))
        }
        defer { OrteMockURLProtocol.entferne(host: Self.host) }
        let url = URL(string: "https://\(Self.host)")!
        for _ in 0..<3 {
            let antwort = try await ImmichAPIClient.login(baseURL: url, email: "a@b.c", password: "p", sessionConfiguration: Self.konfiguration)
            #expect(antwort.accessToken == "T")
            await ImmichAPIClient.logout(baseURL: url, sessionToken: "T", sessionConfiguration: Self.konfiguration)
        }
        #expect(mitschnitt.alle.count == 6)
    }
}
