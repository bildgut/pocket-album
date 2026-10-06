import Foundation
import CoreGraphics
import FoundationModels

/// Der Einspeisepunkt: Tests setzen hier einen Fake ein und laufen ohne Modell.
protocol InfoBildEinordner: Sendable {
    /// Billiger Vorfilter auf dem Thumbnail — Bildklassifikation, sonst Texterkennung.
    func vorfilterBesteht(_ thumbnail: CGImage) async -> Bool
    /// Stufe A auf der Vorschau.
    func art(_ bild: CGImage) async throws -> InfoBildArt
    /// Stufe B, nur nach `dokument`.
    func unterart(_ bild: CGImage) async throws -> InfoBildUnterart
}

/// Warum die Einordnung gerade nicht läuft.
enum InfoBildVerfuegbarkeit: Equatable, Sendable {
    case bereit
    case zuAltesSystem
    case appleIntelligenceAus
    case modellLaedt
    case ungeeignetesGeraet

    var erklaerung: String {
        switch self {
        case .bereit: "Bereit."
        case .zuAltesSystem: "Dafür braucht es macOS 27 oder neuer."
        case .appleIntelligenceAus: "Apple Intelligence ist ausgeschaltet (Systemeinstellungen → Apple Intelligence & Siri)."
        case .modellLaedt: "Das Modell wird noch geladen. Später erneut versuchen."
        case .ungeeignetesGeraet: "Dieser Mac unterstützt Apple Intelligence nicht."
        }
    }
}

enum InfoBildFehler: Error, Equatable {
    /// Der Sicherheitsfilter hat die Antwort verweigert. Kein Urteil über das Bild.
    case abgelehnt
    case modellNichtVerfuegbar(String)
    case sonstiges(String)

    /// Deutet einen SDK-Fehler: erst über die typisierten Fälle, dann als Netz
    /// über den Text.
    ///
    /// **Warum nicht `localizedDescription`:** Am SDK (macOS 27) gemessen liefert
    ///
    /// | Fehler | `localizedDescription` | `String(describing:)` |
    /// |---|---|---|
    /// | `LanguageModelError.guardrailViolation` | „The model's safety guardrails were triggered." | „May contain unsafe content" |
    /// | `LanguageModelError.refusal` | „The model refused to answer." | „May contain unsafe content" |
    /// | `GenerationError.guardrailViolation` | „Detected content likely to be unsafe" | — |
    ///
    /// Keine dieser `localizedDescription`-Zeichenketten enthält „unsafe content"
    /// als Ganzes. Die in der Spezifikation gemessene Zeichenkette stammt aus
    /// `String(describing: error)` — genau dem, was auch
    /// `scripts/infobilder/einordnen.swift` protokolliert. Eine Ablehnung wurde
    /// deshalb nie erkannt: Sie fiel in ``sonstiges``, es wurde kein Befund
    /// gespeichert, und dasselbe Bild lief in jedem Lauf erneut ins Messer.
    ///
    /// Der Text bleibt trotzdem als zweiter Weg stehen — die Fallnamen des SDK
    /// sind erst seit macOS 27 stabil, und unter macOS 26 kommen die
    /// `GenerationError`-Fälle.
    static func deuten(_ error: any Error) -> InfoBildFehler {
        let beschreibung = String(describing: error)

        if #available(macOS 27, iOS 27, *) {
            if let fehler = error as? LanguageModelError {
                switch fehler {
                case .guardrailViolation, .refusal:
                    return .abgelehnt
                case .unsupportedCapability, .unsupportedLanguageOrLocale:
                    // Das Gerät oder die Sprache kann es grundsätzlich nicht —
                    // das nächste Bild scheitert genauso.
                    return .modellNichtVerfuegbar(beschreibung)
                default:
                    break
                }
            }
            // Die Modell-Dateien sind weg oder werden gerade geladen: Apple
            // Intelligence wurde mitten im Lauf abgeschaltet.
            if error is SystemLanguageModel.Error {
                return .modellNichtVerfuegbar(beschreibung)
            }
        }

        if let alt = deuteAltenFehler(error) { return alt }

        if beschreibung.localizedCaseInsensitiveContains("unsafe content")
            || beschreibung.localizedCaseInsensitiveContains("safety guardrails")
            || beschreibung.localizedCaseInsensitiveContains("refused to answer") {
            return .abgelehnt
        }
        if beschreibung.localizedCaseInsensitiveContains("assetsUnavailable")
            || beschreibung.localizedCaseInsensitiveContains("assets are unavailable") {
            return .modellNichtVerfuegbar(beschreibung)
        }
        return .sonstiges(beschreibung)
    }

    /// Die bis macOS 26 geltenden Fälle. Eigene Funktion, und selbst als
    /// veraltet markiert: So bleibt der Aufruf der deprecateten Fälle
    /// warnungsfrei, ohne dass jemand sie versehentlich woanders benutzt.
    @available(macOS, deprecated: 27.0)
    @available(iOS, deprecated: 27.0)
    private static func deuteAltenFehler(_ error: any Error) -> InfoBildFehler? {
        guard let fehler = error as? LanguageModelSession.GenerationError else { return nil }
        switch fehler {
        case .guardrailViolation, .refusal:
            return .abgelehnt
        case .assetsUnavailable, .unsupportedLanguageOrLocale:
            return .modellNichtVerfuegbar(String(describing: error))
        default:
            return nil
        }
    }
}
