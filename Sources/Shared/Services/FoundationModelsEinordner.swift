import Foundation
import CoreGraphics
import FoundationModels
import Vision

/// Die echte Einordnung: Vision als Vorfilter, danach zwei Anfragen an das
/// Modell auf dem Gerät.
///
/// Je Anfrage eine frische `LanguageModelSession` — ein Gespräch über tausende
/// Bilder liefe sonst in die Kontextgrenze. Die Stichprobenziehung steht auf
/// `.greedy`, damit zwei Läufe dasselbe ergeben.
@available(macOS 27, iOS 27, *)
struct FoundationModelsEinordner: InfoBildEinordner {

    @Generable
    fileprivate enum ArtAntwort: String { case foto, screenshot, dokument }

    @Generable
    fileprivate struct UrteilA {
        @Guide(description: "Short English reason, max 12 words") var grund: String
        var kategorie: ArtAntwort
    }

    @Generable
    fileprivate enum UnterartAntwort: String { case beleg, notiz, information, rezept, ausweis, sonstiges }

    @Generable
    fileprivate struct UrteilB {
        @Guide(description: "Short English reason, max 12 words") var grund: String
        var kategorie: UnterartAntwort
    }

    private static let optionen = GenerationOptions(samplingMode: .greedy)

    static var verfuegbarkeit: InfoBildVerfuegbarkeit {
        switch SystemLanguageModel.default.availability {
        case .available: .bereit
        case .unavailable(.appleIntelligenceNotEnabled): .appleIntelligenceAus
        case .unavailable(.modelNotReady): .modellLaedt
        default: .ungeeignetesGeraet
        }
    }

    init() {}

    func vorfilterBesteht(_ thumbnail: CGImage) async -> Bool {
        let klassen = (try? await ClassifyImageRequest().perform(on: thumbnail)) ?? []
        if klassen.contains(where: {
            InfoBildPrompt.vorfilterEtiketten.contains($0.identifier)
                && $0.confidence >= InfoBildPrompt.mindestKonfidenz
        }) { return true }

        // `.fast` liefert unter macOS 27 auch auf Kassenzetteln null Zeichen
        // (gemessen 21.09.2026) — nur `.accurate` ist brauchbar.
        var anfrage = RecognizeTextRequest()
        anfrage.recognitionLevel = .accurate
        let zeilen = (try? await anfrage.perform(on: thumbnail)) ?? []
        let zeichen = zeilen.compactMap { $0.topCandidates(1).first?.string }.joined().count
        return zeichen >= InfoBildPrompt.mindestZeichen
    }

    func art(_ bild: CGImage) async throws -> InfoBildArt {
        let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: InfoBildPrompt.stufeA)
        do {
            let antwort = try await session.respond(generating: UrteilA.self, options: Self.optionen) {
                "Classify this photo."
                Attachment(bild).label("photo")
            }
            AppLogger.ui.debug("InfoBild A: \(antwort.content.kategorie.rawValue) — \(antwort.content.grund)")
            return InfoBildArt(rawValue: antwort.content.kategorie.rawValue) ?? .foto
        } catch {
            throw InfoBildFehler.deuten(error)
        }
    }

    func unterart(_ bild: CGImage) async throws -> InfoBildUnterart {
        let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: InfoBildPrompt.stufeB)
        do {
            let antwort = try await session.respond(generating: UrteilB.self, options: Self.optionen) {
                "Classify this document."
                Attachment(bild).label("document")
            }
            AppLogger.ui.debug("InfoBild B: \(antwort.content.kategorie.rawValue) — \(antwort.content.grund)")
            return InfoBildUnterart(rawValue: antwort.content.kategorie.rawValue) ?? .sonstiges
        } catch {
            throw InfoBildFehler.deuten(error)
        }
    }
}
