import Foundation
import Testing
@testable import ImmichPhone

@Suite("ServerAdresse und ImmichVersion")
struct ServerAdresseTests {
    @Test("Ohne Schema erst https, dann http")
    func ohneSchema() {
        #expect(ServerAdresse.kandidaten(fuer: "photos.example.com").map(\.absoluteString)
                == ["https://photos.example.com", "http://photos.example.com"])
    }

    @Test("Mit Schema nur dieses; Schrägstrich und Leerraum fallen weg")
    func mitSchema() {
        #expect(ServerAdresse.kandidaten(fuer: "  http://192.168.1.10:2283/ \n").map(\.absoluteString)
                == ["http://192.168.1.10:2283"])
        #expect(ServerAdresse.kandidaten(fuer: "HTTPS://x.test//").map(\.absoluteString) == ["https://x.test"])
    }

    @Test("Leer oder ohne Host ergibt nichts")
    func leer() {
        #expect(ServerAdresse.kandidaten(fuer: "").isEmpty)
        #expect(ServerAdresse.kandidaten(fuer: "   ").isEmpty)
        #expect(ServerAdresse.kandidaten(fuer: "https://").isEmpty)
    }

    @Test("Versionen lesen und vergleichen")
    func versionen() {
        #expect(ImmichVersion("3.2.2")?.description == "3.2.2")
        #expect(ImmichVersion("v3.10.0")! > ImmichVersion("3.9.9")!)
        #expect(ImmichVersion("3.1.9")! < .mindestens)
        #expect(ImmichVersion("3.2.0")! >= .mindestens)
        #expect(ImmichVersion("drei") == nil)
        #expect(ImmichVersion("3.2") == nil)
    }
}

@Suite("ServerAdresse: Einfügen aus der Zwischenablage")
struct ServerAdresseEinfuegenTests {
    @Test("Aus einer kopierten Browser-Adresse bleibt nur der Server")
    func browserAdresse() {
        #expect(ServerAdresse.ausZwischenablage("https://fotos.example.de/photos/abc?id=1#x") == "https://fotos.example.de")
        #expect(ServerAdresse.ausZwischenablage("http://192.168.1.10:2283/albums") == "http://192.168.1.10:2283")
    }

    @Test("Leerraum und Zeilenumbrüche fallen weg")
    func leerraum() {
        #expect(ServerAdresse.ausZwischenablage("  https://fotos.example.de/ \n") == "https://fotos.example.de")
    }

    @Test("Ohne Schema bleibt die Eingabe, wie sie ist — nur getrimmt")
    func ohneSchema() {
        #expect(ServerAdresse.ausZwischenablage(" fotos.example.de\n") == "fotos.example.de")
        #expect(ServerAdresse.ausZwischenablage("192.168.1.10:2283") == "192.168.1.10:2283")
    }

    @Test("Nur der erste Teil zählt, wenn mehr in der Zwischenablage steht")
    func mehrzeilig() {
        #expect(ServerAdresse.ausZwischenablage("https://fotos.example.de/a\nnoch was") == "https://fotos.example.de")
    }
}
