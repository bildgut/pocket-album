import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import ImmichPhone

// Prüft ``PhoneKVOStrom`` an einem echten, laufenden `AVPlayer`.
//
// **Warum dieser Test an einer echten Wiedergabe hängt und nicht an einem
// Attrappen-Objekt.** Der Fehler, den er festhält, war eine Eigenheit des
// Zusammenspiels von Combines KVO-Herausgeber mit `AsyncPublisher` — an einem
// selbstgebauten `NSObject` mit `@objc dynamic var` wäre er womöglich gar nicht
// aufgetreten. Der Nutzer hat ihn am Apple TV gefunden: Auf der
// Zweitbildschirm-Bedienung wirkte der Pausenknopf einmal und danach nie
// wieder. Ursache war `spieler.publisher(for: \.timeControlStatus).values` —
// dieser Weg lieferte **nur den ersten Wert**, weil `AsyncPublisher` immer nur
// einen Wert anfordert und der KVO-Herausgeber danach nichts mehr nachmeldet.
//
// Gemessen am selben Player, mit denselben vier Wechseln (start, pause,
// weiter): `NSKeyValueObservation` sah `[0, 2, 0, 2]`, ein Combine-`sink`
// ebenfalls `[0, 2, 0, 2]`, `.values` genau `[0]`.
//
// Der Test unten vergleicht deshalb den neuen Strom gegen eine gewöhnliche
// `NSKeyValueObservation` am selben Player: Was die sieht, muss auch der Strom
// sehen. Das ist die Zusicherung, auf der die Bedienung steht — und sie hätte
// mit dem alten Weg nicht gehalten.
@Suite("PhoneKVOStrom")
struct PhoneKVOStromTests {

    private static let breite = 160
    private static let hoehe = 120

    /// Sammelt Werte von beiden Wegen. Eine Klasse auf dem `MainActor`, damit
    /// Strom-Aufgabe und Testrumpf dieselbe Sicht haben.
    @MainActor
    private final class Sammler {
        var werte: [AVPlayer.TimeControlStatus] = []
        var laeuft: Bool { werte.last.map { $0 != .paused } ?? false }
    }

    @Test("Der Strom sieht jeden Wechsel, den auch KVO sieht")
    @MainActor
    func stromSiehtAlleWechsel() async throws {
        let url = Self.temporaereURL()
        defer { try? FileManager.default.removeItem(at: url) }
        // Zehn Sekunden bei 30 Bildern — lang genug, dass das Video während des
        // Tests nicht von selbst endet und den Spielstand verfälscht.
        try await Self.schreibeTestvideo(nach: url, bilder: 300)

        let spieler = AVPlayer(playerItem: AVPlayerItem(asset: AVURLAsset(url: url)))
        // Ohne das bleibt der Player im Simulator auf
        // `.waitingToPlayAtSpecifiedRate` stehen und kommt nie auf `.playing`.
        spieler.automaticallyWaitsToMinimizeStalling = false

        let ausKVO = Sammler()
        let ausStrom = Sammler()

        // Am Objekt gelesen, nicht aus `aenderung.newValue` — der ist für
        // einen aus ObjC importierten Aufzählungstyp immer `nil` (Begründung
        // an `PhoneKVOStrom`).
        let beobachtung = spieler.observe(\.timeControlStatus, options: [.initial, .new]) { spieler, _ in
            let neu = spieler.timeControlStatus
            Task { @MainActor in ausKVO.werte.append(neu) }
        }
        defer { beobachtung.invalidate() }

        let strom = Task { @MainActor in
            for await status in PhoneKVOStrom.werte(von: spieler, \.timeControlStatus) {
                ausStrom.werte.append(status)
            }
        }
        defer { strom.cancel() }

        // Der Anfangswert kommt bei beiden Wegen ohne Zutun.
        try await Self.warteBis("Anfangswert") { !ausStrom.werte.isEmpty && !ausKVO.werte.isEmpty }
        #expect(ausStrom.werte.first == .paused)

        spieler.play()
        try await Self.warteBis("Anlauf") { ausKVO.laeuft }
        // Das ist der Punkt: Nach dem ersten Wert muss ein zweiter kommen.
        try await Self.warteBis("Anlauf im Strom") { ausStrom.laeuft }

        spieler.pause()
        try await Self.warteBis("Pause") { ausKVO.laeuft == false }
        try await Self.warteBis("Pause im Strom") { ausStrom.laeuft == false }
        #expect(PhoneAbspielknopf.fuer(spielstand: ausStrom.werte.last ?? .playing) == .fortsetzen)

        // Und der Wiederanlauf — genau der Tipp, der auf dem Gerät ins Leere
        // lief, weil der Knopf noch „Pause" zeigte.
        spieler.play()
        try await Self.warteBis("Wiederanlauf") { ausKVO.laeuft }
        try await Self.warteBis("Wiederanlauf im Strom") { ausStrom.laeuft }
        #expect(PhoneAbspielknopf.fuer(spielstand: ausStrom.werte.last ?? .paused) == .pausieren)

        spieler.pause()

        // Mindestens vier Werte: Anfang, Anlauf, Pause, Wiederanlauf. Über den
        // alten Weg war es genau einer.
        #expect(ausStrom.werte.count >= 4, "Strom sah nur \(ausStrom.werte.map(\.rawValue))")
    }

    @Test("Der Abbruch der Aufgabe beendet den Strom")
    @MainActor
    func abbruchBeendetDenStrom() async throws {
        let url = Self.temporaereURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try await Self.schreibeTestvideo(nach: url, bilder: 60)

        let spieler = AVPlayer(playerItem: AVPlayerItem(asset: AVURLAsset(url: url)))
        let sammler = Sammler()
        let fertig = Sammler()

        let strom = Task { @MainActor in
            for await status in PhoneKVOStrom.werte(von: spieler, \.timeControlStatus) {
                sammler.werte.append(status)
            }
            // Wird nur erreicht, wenn der Strom sich beendet — das ist die
            // Zusicherung, an der `beende()` in `PhoneVideoPlayer` hängt.
            fertig.werte.append(.paused)
        }

        try await Self.warteBis("Anfangswert") { !sammler.werte.isEmpty }
        strom.cancel()
        try await Self.warteBis("Strom endet") { !fertig.werte.isEmpty }
        #expect(fertig.werte.isEmpty == false)
    }

    // MARK: - Warten

    private struct Zeitueberschreitung: Error, CustomStringConvertible {
        let description: String
    }

    /// Wartet bis zu zehn Sekunden auf eine Bedingung. Fester `sleep` wäre die
    /// Alternative — und die Quelle sporadischer Fehlschläge, weil eine echte
    /// Wiedergabe nicht auf die Millisekunde anläuft.
    private static func warteBis(
        _ was: String,
        _ bedingung: @MainActor () -> Bool
    ) async throws {
        for _ in 0..<500 {
            if await bedingung() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw Zeitueberschreitung(description: "Zeitüberschreitung beim Warten auf: \(was)")
    }

    // MARK: - Testvideo

    private static func temporaereURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PhoneKVOStromTests-\(UUID().uuidString).mov")
    }

    private struct SchreibFehler: Error, CustomStringConvertible {
        let description: String
    }

    /// Schreibt ein H.264-Video (160×120, 30 Bilder je Sekunde). Dieselbe
    /// Machart wie in `PhoneVideoPosterTests` — auf dem Gerät liegt kein
    /// Videooriginal lokal, also erzeugt der Test sich eines.
    private static func schreibeTestvideo(nach url: URL, bilder: Int) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let eingang = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: breite,
            AVVideoHeightKey: hoehe
        ])
        eingang.expectsMediaDataInRealTime = false
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
            let puffer = try graustufenPuffer(helligkeit: UInt8(40 + (index % 7) * 30))
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

    /// Eine einfarbige BGRA-Fläche. Wechselnde Helligkeiten nur, damit der
    /// Encoder nicht alle Bilder zu nichts eindampft.
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
