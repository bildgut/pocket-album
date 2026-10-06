import Foundation

// MARK: - Fehler

/// Was bei einer Gemini-Anfrage schiefgehen kann — unabhängig davon, wonach
/// gefragt wurde.
///
/// Die Zuordnung von HTTP-Status und Fehlertext auf diese Fälle ist Detailwissen
/// (Schlüssel im Header, `RESOURCE_EXHAUSTED`, „high demand"), das an genau einer
/// Stelle gepflegt gehört. Eine zweite Fassung wäre eine, die den nächsten Fix
/// nicht mitbekommt.
enum GeminiError: LocalizedError {
    case missingAPIKey
    case invalidAPIKey
    case network(String)
    case overloaded
    case blocked
    case emptyResponse
    case badResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Kein Gemini-API-Schlüssel hinterlegt (Einstellungen → Editor → Gemini)."
        case .invalidAPIKey:
            return "Ungültiger Gemini-API-Schlüssel."
        case .network(let detail):
            return "Netzwerkfehler bei der Gemini-Anfrage: \(detail)"
        case .overloaded:
            return "Das Gemini-Modell ist gerade überlastet (auch nach mehreren Versuchen). Bitte in ein paar Minuten erneut versuchen — oder in den Einstellungen ein anderes Modell wählen."
        case .blocked:
            return "Die Anfrage wurde von Gemini aus Sicherheitsgründen blockiert."
        case .emptyResponse:
            return "Das Modell hat nichts geliefert — bei Überlastung passiert das gelegentlich. Einfach erneut versuchen."
        case .badResponse:
            return "Die Antwort von Gemini konnte nicht gelesen werden."
        }
    }

    /// Ob ein ganzer Stapellauf abgebrochen gehört, statt Foto für Foto in
    /// dasselbe Messer zu laufen.
    ///
    /// Jede Anfrage kostet Kontingent. Bei einem fehlenden oder falschen Schlüssel
    /// scheitert auch die vierzigste, und bei anhaltender Überlastung wartet jede
    /// erneut die volle Backoff-Kaskade ab.
    var stopsBatch: Bool {
        switch self {
        case .missingAPIKey, .invalidAPIKey, .overloaded: return true
        case .network, .blocked, .emptyResponse, .badResponse: return false
        }
    }
}

// MARK: - GeminiClient

/// Der gemeinsame Weg zur Gemini Developer API: ein Bild und ein Prompt rein,
/// die geprüfte JSON-Antwort des Modells raus.
///
/// Bewusst ohne Wissen darüber, *wonach* gefragt wird — Prompt, Schema und
/// Auswertung liegen bei den Aufrufern (``GeminiCropService``,
/// ``GeminiLandmarkService``).
enum GeminiClient {

    static let defaultModel = "gemini-3.8-flash"

    /// Fallback, wenn das konfigurierte Modell überlastet bleibt.
    ///
    /// Muss mitwandern: Google nimmt alte Modelle für neue Schlüssel vom Netz
    /// („no longer available to new users", HTTP 400). Das kommt hier nicht als
    /// Überlastung an, sondern als ``GeminiError/network(_:)`` — der Ausweichweg
    /// scheitert dann härter als der Hinweg. Zuletzt nachgezogen am 06.09.2026,
    /// als `gemini-2.5-flash` zurückgezogen wurde.
    static let fallbackModel = "gemini-3.6-flash"

    /// Schickt Prompt und Bild an das Modell und gibt den JSON-Text der Antwort
    /// zurück — mit Wiederholung bei Überlastung (Backoff 1 s/3 s) und danach
    /// einem Versuch auf dem Fallback-Modell.
    ///
    /// „High demand"-Spitzen des jeweils neuesten Modells sind kurzlebig; ohne
    /// Wiederholung landete jede davon als Fehlerdialog beim Nutzer.
    ///
    /// - Parameter logLabel: Präfix der Protokollzeilen, damit im Log erkennbar
    ///   bleibt, welcher Assistent gerade gefragt hat.
    static func generateJSON(prompt: String,
                             imageJPEG: Data,
                             responseSchema: [String: Any],
                             model: String,
                             apiKey: String,
                             logLabel: String) async throws -> Data {

        let delays: [Duration] = [.seconds(1), .seconds(3)]
        for (attempt, delay) in ([Duration.zero] + delays).enumerated() {
            if delay != .zero { try? await Task.sleep(for: delay) }
            do {
                return try await performRequest(prompt: prompt, imageJPEG: imageJPEG,
                                                responseSchema: responseSchema,
                                                model: model, apiKey: apiKey,
                                                logLabel: logLabel)
            } catch GeminiError.overloaded {
                AppLogger.ui.warning("\(logLabel): \(model) überlastet (Versuch \(attempt + 1))")
                continue
            }
        }

        guard model != fallbackModel else { throw GeminiError.overloaded }
        AppLogger.ui.warning("\(logLabel): weiche auf Fallback-Modell \(fallbackModel) aus")
        return try await performRequest(prompt: prompt, imageJPEG: imageJPEG,
                                        responseSchema: responseSchema,
                                        model: fallbackModel, apiKey: apiKey,
                                        logLabel: logLabel)
    }

    private static func performRequest(prompt: String,
                                       imageJPEG: Data,
                                       responseSchema: [String: Any],
                                       model: String,
                                       apiKey: String,
                                       logLabel: String) async throws -> Data {
        guard !apiKey.isEmpty else { throw GeminiError.missingAPIKey }
        guard let url = URL(
            string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
        ) else { throw GeminiError.badResponse }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Key im Header, nicht als URL-Query — Query-Strings landen in Logs/Proxies.
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 60

        let body: [String: Any] = [
            "contents": [[
                "parts": [
                    ["text": prompt],
                    ["inline_data": [
                        "mime_type": "image/jpeg",
                        "data": imageJPEG.base64EncodedString(),
                    ]],
                ],
            ]],
            "generationConfig": [
                "response_mime_type": "application/json",
                "response_schema": responseSchema,
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw GeminiError.network(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            // Fehler-Envelope: {"error": {"code", "message", "status"}}
            let envelope = try? JSONDecoder().decode(GeminiErrorEnvelope.self, from: data)
            let message = envelope?.error.message ?? "HTTP \(http.statusCode)"
            if http.statusCode == 400 || http.statusCode == 401 || http.statusCode == 403,
               message.localizedCaseInsensitiveContains("api key") || message.contains("API_KEY") {
                throw GeminiError.invalidAPIKey
            }
            if http.statusCode == 429 || http.statusCode == 503
                || message.localizedCaseInsensitiveContains("high demand")
                || message.localizedCaseInsensitiveContains("overloaded")
                || envelope?.error.status == "RESOURCE_EXHAUSTED"
                || envelope?.error.status == "UNAVAILABLE" {
                throw GeminiError.overloaded
            }
            throw GeminiError.network(message)
        }

        guard let decoded = try? JSONDecoder().decode(GeminiGenerateResponse.self, from: data) else {
            throw GeminiError.badResponse
        }
        if decoded.promptFeedback?.blockReason != nil {
            throw GeminiError.blocked
        }
        guard let text = decoded.candidates?.first?.content?.parts?.first?.text,
              let jsonData = text.data(using: .utf8)
        else {
            AppLogger.ui.warning("\(logLabel): Antwort ohne Text-Part — vermutlich Überlastung")
            throw GeminiError.emptyResponse
        }
        return jsonData
    }

    // MARK: - Antwort-Typen

    private struct GeminiErrorEnvelope: Decodable {
        struct ErrorBody: Decodable {
            let code: Int?
            let message: String?
            let status: String?
        }
        let error: ErrorBody
    }

    private struct GeminiGenerateResponse: Decodable {
        struct Candidate: Decodable {
            struct Content: Decodable {
                struct Part: Decodable { let text: String? }
                let parts: [Part]?
            }
            let content: Content?
        }
        struct PromptFeedback: Decodable { let blockReason: String? }
        let candidates: [Candidate]?
        let promptFeedback: PromptFeedback?
    }
}
