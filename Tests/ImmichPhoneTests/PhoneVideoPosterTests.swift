import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing
import UIKit
@testable import ImmichPhone

// Prüft `PhoneVideoPoster.bild(fuer:)` — das Standbild, das eine Videoseite
// zeigt, bevor der Nutzer auf den Startknopf tippt.
//
// **Warum dieser Test ein Video selbst erzeugt.** Die Lücke, die er schließt,
// blieb bisher offen, weil auf dem Gerät kein einziges Videooriginal lokal
// liegt (das gepinnte Album enthält nur Fotos) — es gab also nichts, woran sich
// der Weg über `AVAssetImageGenerator` belegen ließe. Ein `AVAssetWriter`
// schreibt hier ein paar Bilder H.264 in `temporaryDirectory` und macht damit
// genau die Datei, die dem Gerät fehlt. Damit ist der Pfad tatsächlich
// dekodiert und nicht nur behauptet.
@Suite("PhoneVideoPoster")
struct PhoneVideoPosterTests {

    private static let breite = 160
    private static let hoehe = 120

    @Test("Aus einer echten Videodatei kommt ein Bild in den Maßen des Videos")
    func standbildAusVideo() async throws {
        let url = Self.temporaereURL(endung: "mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try await Self.schreibeTestvideo(nach: url)

        let bild = try #require(await PhoneVideoPoster.bild(fuer: url))
        // `UIImage(cgImage:)` hat den Maßstab 1, `size` ist damit die
        // Pixelgröße. 160×120 liegt weit unter der Obergrenze, es wird also
        // nichts heruntergerechnet.
        #expect(bild.size == CGSize(width: Self.breite, height: Self.hoehe))
    }

    @Test("Eine nicht existierende Datei ergibt nil und wirft nicht")
    func fehlendeDatei() async {
        let url = Self.temporaereURL(endung: "mov")
        #expect(FileManager.default.fileExists(atPath: url.path) == false)
        #expect(await PhoneVideoPoster.bild(fuer: url) == nil)
    }

    @Test("Eine Datei, die kein Video ist, ergibt nil statt eines Absturzes")
    func keinVideo() async throws {
        // Der reale Fall: ein abgebrochener Download aus dem Offline-Cache
        // liegt unter einem Namen, der nach Video aussieht. Die Endung ist das
        // Einzige, worauf sich hier nicht verlassen werden darf.
        let url = Self.temporaereURL(endung: "mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("Das ist kein Video.".utf8).write(to: url)

        #expect(await PhoneVideoPoster.bild(fuer: url) == nil)
    }

    @Test("Ein hochkant aufgenommenes Video liegt im Standbild nicht quer")
    func hochkantWirdGedreht() async throws {
        // Der Grund für `appliesPreferredTrackTransform`: Ein mit dem Telefon
        // hochkant aufgenommenes Video speichert seine Bilder quer und trägt
        // die Drehung als Transformation an der Spur. Ohne das Flag käme genau
        // dieses quer liegende Rohbild heraus — auf einer Videoseite, deren
        // Wiedergabe (`AVPlayer` wertet die Transformation selbst aus) danach
        // aufrecht startet. Das Standbild spränge beim Antippen um 90 Grad.
        let url = Self.temporaereURL(endung: "mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try await Self.schreibeTestvideo(nach: url, drehung: .pi / 2)

        let bild = try #require(await PhoneVideoPoster.bild(fuer: url))
        #expect(bild.size == CGSize(width: Self.hoehe, height: Self.breite))
    }

    // MARK: - Testvideo

    private static func temporaereURL(endung: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PhoneVideoPosterTests-\(UUID().uuidString).\(endung)")
    }

    private struct SchreibFehler: Error, CustomStringConvertible {
        let description: String
    }

    /// Schreibt ein sehr kurzes H.264-Video (fünf Bilder, 160×120).
    private static func schreibeTestvideo(nach url: URL, bilder: Int = 5, drehung: CGFloat = 0) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let eingang = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: breite,
            AVVideoHeightKey: hoehe
        ])
        eingang.expectsMediaDataInRealTime = false
        if drehung != 0 {
            eingang.transform = CGAffineTransform(rotationAngle: drehung)
        }
        let adapter = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: eingang,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: breite,
                kCVPixelBufferHeightKey as String: hoehe
            ]
        )
        guard writer.canAdd(eingang) else {
            throw SchreibFehler(description: "AVAssetWriter nimmt den Eingang nicht an")
        }
        writer.add(eingang)
        guard writer.startWriting() else {
            throw SchreibFehler(description: "startWriting: \(writer.error?.localizedDescription ?? "unbekannt")")
        }
        writer.startSession(atSourceTime: .zero)

        for index in 0..<bilder {
            while !eingang.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            let puffer = try graustufenPuffer(helligkeit: UInt8(40 + index * 30))
            let zeit = CMTime(value: CMTimeValue(index), timescale: 30)
            guard adapter.append(puffer, withPresentationTime: zeit) else {
                throw SchreibFehler(description: "append: \(writer.error?.localizedDescription ?? "unbekannt")")
            }
        }

        eingang.markAsFinished()
        await withCheckedContinuation { fortsetzung in
            writer.finishWriting { fortsetzung.resume() }
        }
        guard writer.status == .completed else {
            throw SchreibFehler(description: "finishWriting: \(writer.error?.localizedDescription ?? "unbekannt")")
        }
    }

    /// Eine einfarbige BGRA-Fläche. Der Inhalt ist gleichgültig — geprüft wird
    /// nur, dass überhaupt ein Bild herauskommt; unterschiedliche Helligkeiten
    /// verhindern lediglich, dass der Encoder alle Bilder zu nichts eindampft.
    private static func graustufenPuffer(helligkeit: UInt8) throws -> CVPixelBuffer {
        var puffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            breite,
            hoehe,
            kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary,
            &puffer
        )
        guard status == kCVReturnSuccess, let puffer else {
            throw SchreibFehler(description: "CVPixelBufferCreate: \(status)")
        }
        CVPixelBufferLockBaseAddress(puffer, [])
        defer { CVPixelBufferUnlockBaseAddress(puffer, []) }
        guard let basis = CVPixelBufferGetBaseAddress(puffer) else {
            throw SchreibFehler(description: "CVPixelBufferGetBaseAddress ergab nil")
        }
        let bytesProZeile = CVPixelBufferGetBytesPerRow(puffer)
        memset(basis, Int32(helligkeit), bytesProZeile * hoehe)
        return puffer
    }
}
