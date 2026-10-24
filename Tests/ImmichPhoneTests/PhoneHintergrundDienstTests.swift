import Testing
import Foundation
@testable import ImmichPhone

@Suite("PhoneHintergrundDienst")
struct PhoneHintergrundDienstTests {

    private let host = "hintergrund-test.local"

    @Test("Konstanten stimmen mit Info.plist / project.yml überein")
    func identifierKonstanten() {
        #expect(PhoneHintergrundDienst.refreshIdentifier == "com.ralksta.pocketalbum.refresh")
        #expect(PhoneHintergrundDienst.processingIdentifier == "com.ralksta.pocketalbum.processing")
    }

    @Test("Erreichbarkeitsprüfung gelingt bei funktionierendem Server")
    @MainActor
    func pruefeErreichbarkeitErfolgreich() async {
        OrteMockURLProtocol.registriere(host: host) { _, _ in
            (200, Data("{\"res\":\"pong\"}".utf8))
        }
        defer { OrteMockURLProtocol.entferne(host: host) }

        let client = OrteMockURLProtocol.client(host: host)
        let erreichbar = await PhoneHintergrundDienst.shared.pruefeErreichbarkeit(client: client)
        #expect(erreichbar == true)
    }

    @Test("Erreichbarkeitsprüfung scheitert lautlos bei Serverfehler")
    @MainActor
    func pruefeErreichbarkeitFehlschlag() async {
        OrteMockURLProtocol.registriere(host: host) { _, _ in
            (500, Data("{}".utf8))
        }
        defer { OrteMockURLProtocol.entferne(host: host) }

        let client = OrteMockURLProtocol.client(host: host)
        let erreichbar = await PhoneHintergrundDienst.shared.pruefeErreichbarkeit(client: client)
        #expect(erreichbar == false)
    }
}
