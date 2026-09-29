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
}
