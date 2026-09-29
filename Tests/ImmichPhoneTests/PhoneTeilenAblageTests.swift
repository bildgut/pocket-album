import Foundation
import Testing
@testable import ImmichPhone

@Suite("PhoneTeilenAblage")
struct PhoneTeilenAblageTests {

    @Test("Normale Namen bleiben, Pfade werden auf den letzten Teil gekürzt")
    func namen() {
        #expect(PhoneTeilenAblage.sichererName("IMG_0001.HEIC", assetId: "a") == "IMG_0001.HEIC")
        #expect(PhoneTeilenAblage.sichererName("../../etc/passwd", assetId: "a") == "passwd")
        #expect(PhoneTeilenAblage.sichererName("ordner/bild.jpg", assetId: "a") == "bild.jpg")
    }

    @Test("Leer, Punkt und Doppelpunkt fallen auf die Asset-ID zurück", arguments: ["", " ", ".", "..", "/", "a/..", "x/."])
    func rueckfall(_ roh: String) {
        #expect(PhoneTeilenAblage.sichererName(roh, assetId: "asset-1") == "asset-1")
    }

    @Test("Aufräumen entfernt nur alte Teilen-Ordner")
    func aufraeumen() throws {
        let fm = FileManager.default
        let basis = fm.temporaryDirectory.appending(path: "TeilenTest-\(UUID().uuidString)")
        try fm.createDirectory(at: basis, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: basis) }

        let alt = basis.appending(path: "Teilen-alt")
        let neu = basis.appending(path: "Teilen-neu")
        let fremd = basis.appending(path: "Anderes-alt")
        for url in [alt, neu, fremd] { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
        let vorZweiStunden = Date().addingTimeInterval(-7200)
        try fm.setAttributes([.modificationDate: vorZweiStunden], ofItemAtPath: alt.path)
        try fm.setAttributes([.modificationDate: vorZweiStunden], ofItemAtPath: fremd.path)

        #expect(PhoneTeilenAblage.raeumeAuf(in: basis) == 1)
        #expect(!fm.fileExists(atPath: alt.path))
        #expect(fm.fileExists(atPath: neu.path))
        #expect(fm.fileExists(atPath: fremd.path))
    }

    @Test("Offline-Dateien bekommen den Originalnamen, Vorschauen ihre echte Endung")
    func teilNamen() {
        let orig = URL(fileURLWithPath: "/c/2024-01/0f1e.heic")
        let vor = URL(fileURLWithPath: "/c/2024-01/0f1e.vorschau.jpg")
        let klein = URL(fileURLWithPath: "/c/2024-01/0f1e.klein.mp4")
        #expect(PhoneTeilenAblage.teilName(originalName: "IMG_1.HEIC", lokal: orig) == "IMG_1.HEIC")
        #expect(PhoneTeilenAblage.teilName(originalName: "IMG_1.HEIC", lokal: vor) == "IMG_1.jpg")
        #expect(PhoneTeilenAblage.teilName(originalName: "Clip.MOV", lokal: klein) == "Clip.mp4")
        #expect(PhoneTeilenAblage.teilName(originalName: "../x/IMG_2.JPG", lokal: orig) == "IMG_2.JPG")
    }

    @Test("Benannte Kopie liegt im Teilen-Ordner und hat den Inhalt der Datei")
    func benannteKopie() throws {
        let fm = FileManager.default
        let basis = fm.temporaryDirectory.appending(path: "teilen-test-\(UUID().uuidString)")
        try fm.createDirectory(at: basis, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: basis) }
        let quelle = basis.appending(path: "abc.vorschau.jpg")
        try Data("BILD".utf8).write(to: quelle)

        let ziel = try #require(PhoneTeilenAblage.benannteKopie(von: quelle, originalName: "Urlaub.HEIC", basis: basis))
        #expect(ziel.lastPathComponent == "Urlaub.jpg")
        #expect(ziel.deletingLastPathComponent().lastPathComponent.hasPrefix(PhoneTeilenAblage.praefix))
        #expect(try Data(contentsOf: ziel) == Data("BILD".utf8))
        #expect(fm.fileExists(atPath: quelle.path))
    }
}
