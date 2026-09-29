import Foundation
import CoreGraphics

// MARK: - Fehler

/// Das Modell hat geliefert, aber die client-seitige Validierung hat alles
/// verworfen — mit Begründung, damit klar ist, welcher Filter griff.
///
/// Der einzige Fehler, den nur der Zuschnitt kennt; alles Übrige kommt als
/// ``GeminiError`` aus dem gemeinsamen ``GeminiClient``.
struct GeminiCropFilteredError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - GeminiCropService

/// KI-Zuschnitt: schickt eine mittelgroße JPEG-Fassung an die Gemini Developer API und
/// macht aus der Structured-Output-Antwort geprüfte ``CropSuggestion``-Werte.
///
/// Alles außer dem eigentlichen HTTP-Aufruf ist **pur und statisch** (Prompt-Bau,
/// Parsing, Validierung, Koordinaten-Mathematik) — die Tests laufen ohne Netz.
enum GeminiCropService {

    static let defaultModel = GeminiClient.defaultModel

    // MARK: - Prompt

    /// Englischer Prompt (Structured-Output-Anweisungen befolgen die Modelle auf
    /// Englisch am zuverlässigsten), deutsche Ausgabetexte.
    ///
    /// Aufbau: Genre-Analyse zuerst, dann genre-spezifische Kompositionsregeln,
    /// harte Negativ-Regeln, ehrliche Selbstbewertung (`score`) mit der Erlaubnis,
    /// WENIGER Vorschläge zu liefern — lieber zwei starke als fünf Füller.
    static func buildPrompt(originalPixelSize: CGSize, minMegapixels: Double) -> String {
        let w = Int(originalPixelSize.width)
        let h = Int(originalPixelSize.height)
        let mp = Double(w * h) / 1_000_000
        return """
        You are an award-winning professional photographer and photo editor with decades of \
        experience in cropping and composition.

        Step 1 — Analyze first: determine the genre of the attached photo (landscape, portrait, \
        street, architecture, wildlife, macro, still life, event, ...) and identify the main \
        subject, secondary elements, and distractions near the edges.

        Step 2 — Propose 2 to 5 alternative crops that genuinely improve the composition. Apply \
        the principles of the identified genre:
        - Landscape: never center the horizon; place it on a third; keep or create a foreground \
        anchor; consider a panoramic crop if the sky or foreground is empty.
        - Portrait/people: place the eyes near the upper third; never cut limbs at joints \
        (knees, elbows, wrists, ankles); leave room in the direction of the gaze.
        - Street/action: leave space in the direction of movement or gaze; preserve context \
        that tells the story; a tight crop must not orphan meaningful elements.
        - Architecture: respect strong lines and symmetry — either embrace full symmetry or \
        break it decisively; avoid slightly-off symmetry.
        - Wildlife/macro: isolate the subject; give the eye sharpness priority; remove empty \
        or cluttered margins.
        General principles: rule of thirds, golden ratio, leading lines, negative space, \
        subject isolation, removal of distracting edge elements.

        Hard rules — never violate:
        - Never clip the main subject's silhouette or cut through faces.
        - Never produce a crop that is almost, but not quite, symmetric or almost, but not \
        quite, a standard aspect ratio.
        - Each proposal must be clearly different from the others (e.g. tight subject crop, \
        panorama, square) — no near-duplicates.

        Step 3 — Self-critique: for every crop, assign an honest "score" from 1 to 10 for how \
        much it improves on the original framing. Discard proposals you cannot convincingly \
        justify — returning only 2 excellent crops is better than 5 mediocre ones. Do not \
        inflate scores.

        The original image is \(w)x\(h) pixels (\(String(format: "%.1f", mp)) megapixels). \
        The attached image is a downscaled preview of the exact same frame. Every crop must \
        retain at least \(String(format: "%.1f", minMegapixels)) megapixels of the ORIGINAL \
        resolution, i.e. width * height * \(w * h) >= \(Int(minMegapixels * 1_000_000)), \
        where width and height are the normalized values you return. Do not propose smaller crops.

        Return JSON only: an array of crop objects. Coordinates are normalized to the range \
        0..1 relative to the image, with the origin at the TOP-LEFT corner; x grows to the \
        right, y grows downwards. "aspect" must be one of: "frei", "1:1", "4:3", "3:2", "16:9" \
        (use "frei" for anything else) and must match the actual proportions of the crop \
        rectangle in ORIGINAL pixels. Write "title" (at most 4 words) and "rationale" \
        (1-2 sentences, mention the applied principle) in German. Order the suggestions \
        from best to worst.
        """
    }

    // MARK: - Request

    /// Fallback, wenn das konfigurierte Modell überlastet bleibt.
    static let fallbackModel = GeminiClient.fallbackModel

    /// Holt Zuschnitt-Vorschläge: Anfrage über den gemeinsamen ``GeminiClient``,
    /// danach die zuschnitt-eigene Prüfung der Rechtecke.
    static func requestSuggestions(
        imageJPEG: Data,
        previewPixelSize: CGSize,
        originalPixelSize: CGSize,
        minMegapixels: Double,
        model: String,
        apiKey: String
    ) async throws -> [CropSuggestion] {
        let jsonData = try await GeminiClient.generateJSON(
            prompt: buildPrompt(originalPixelSize: originalPixelSize,
                                minMegapixels: minMegapixels),
            imageJPEG: imageJPEG,
            responseSchema: responseSchema,
            model: model,
            apiKey: apiKey,
            logLabel: "AICrop"
        )
        let text = String(data: jsonData, encoding: .utf8) ?? ""

        let parsed = parseSuggestions(
            json: jsonData,
            previewPixelSize: previewPixelSize,
            originalPixelSize: originalPixelSize,
            minMegapixels: minMegapixels
        )
        guard !parsed.suggestions.isEmpty else {
            AppLogger.ui.warning("AICrop: 0 nutzbare Vorschläge (roh \(parsed.rawCount), unter MinMP \(parsed.droppedBelowMinMegapixels), Score \(parsed.droppedByScore)); Antwort: \(String(text.prefix(500)))")
            if parsed.rawCount == 0 {
                throw GeminiError.emptyResponse
            }
            if parsed.droppedBelowMinMegapixels == parsed.rawCount {
                throw GeminiCropFilteredError(
                    message: "Alle \(parsed.rawCount) Vorschläge lagen unter der Mindestauflösung von \(String(format: "%.0f", minMegapixels)) MP (Einstellungen → Editor → KI-Zuschnitt)."
                )
            }
            throw GeminiCropFilteredError(
                message: "Alle \(parsed.rawCount) Vorschläge wurden verworfen (\(parsed.droppedBelowMinMegapixels)× unter Mindestauflösung, \(parsed.droppedByScore)× zu schwach bewertet, Rest unbrauchbare Koordinaten)."
            )
        }
        return parsed.suggestions
    }

    /// Structured-Output-Schema (Gemini-REST-Dialekt, Typnamen groß geschrieben).
    private static let responseSchema: [String: Any] = [
        "type": "ARRAY",
        "items": [
            "type": "OBJECT",
            "properties": [
                "x": ["type": "NUMBER"],
                "y": ["type": "NUMBER"],
                "width": ["type": "NUMBER"],
                "height": ["type": "NUMBER"],
                "title": ["type": "STRING"],
                "rationale": ["type": "STRING"],
                "aspect": ["type": "STRING", "enum": ["frei", "1:1", "4:3", "3:2", "16:9"]],
                "score": ["type": "NUMBER"],
            ],
            "required": ["x", "y", "width", "height", "title", "rationale", "aspect", "score"],
            "propertyOrdering": ["x", "y", "width", "height", "title", "rationale", "aspect", "score"],
        ],
    ]

    // MARK: - Antwort-Typen

    private struct RawSuggestion: Decodable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
        let title: String
        let rationale: String
        let aspect: String?
        let score: Double?
    }

    // MARK: - Parsing & Validierung (pur)

    /// Unter diesem Score fliegt ein Vorschlag raus (Selbstkritik-Filter). Fallback:
    /// Sind ALLE zu schwach, bleiben die besten zwei — ein leeres Panel wäre die
    /// schlechtere Antwort als „zwei mittelmäßige, ehrlich bewertete".
    static let minScore: Double = 7

    struct ParseResult: Equatable {
        var suggestions: [CropSuggestion] = []
        /// Wie viele Einträge das Modell überhaupt geliefert hat.
        var rawCount = 0
        var droppedBelowMinMegapixels = 0
        var droppedByScore = 0
    }

    /// Macht aus dem Modell-JSON geprüfte Vorschläge. Tolerant: Müll ergibt eine leere
    /// Liste, einzelne kaputte Einträge werden übersprungen, nie ein Throw.
    static func parseSuggestions(
        json: Data,
        previewPixelSize: CGSize,
        originalPixelSize: CGSize,
        minMegapixels: Double
    ) -> ParseResult {
        guard originalPixelSize.width > 0, originalPixelSize.height > 0 else { return ParseResult() }
        let raws: [RawSuggestion]
        do {
            raws = try JSONDecoder().decode([RawSuggestion].self, from: json)
        } catch {
            // Zweiter Versuch Element für Element: ein einzelner kaputter Eintrag soll
            // nicht die ganze Liste kosten.
            guard let anyArray = (try? JSONSerialization.jsonObject(with: json)) as? [Any] else {
                return ParseResult()
            }
            raws = anyArray.compactMap { element in
                guard let data = try? JSONSerialization.data(withJSONObject: element) else { return nil }
                return try? JSONDecoder().decode(RawSuggestion.self, from: data)
            }
        }

        var result = ParseResult(rawCount: raws.count)
        var accepted: [CropSuggestion] = []
        var scoreRejected: [CropSuggestion] = []

        for raw in raws {
            guard var rect = normalizedRect(from: raw, previewPixelSize: previewPixelSize,
                                            originalPixelSize: originalPixelSize) else { continue }

            // Ins Einheitsquadrat klemmen
            rect.origin.x = min(max(rect.minX, 0), 1)
            rect.origin.y = min(max(rect.minY, 0), 1)
            rect.size.width = min(rect.width, 1 - rect.minX)
            rect.size.height = min(rect.height, 1 - rect.minY)
            guard rect.width > 0.02, rect.height > 0.02 else { continue }

            // Vollbild ist kein Vorschlag
            if rect.width > 0.98 && rect.height > 0.98 { continue }

            let megapixels = rect.width * rect.height
                * originalPixelSize.width * originalPixelSize.height / 1_000_000
            guard megapixels >= minMegapixels else {
                result.droppedBelowMinMegapixels += 1
                continue
            }

            // Aspect-Angabe nur übernehmen, wenn sie zum Rechteck (in Originalpixeln!)
            // tatsächlich passt — sonst würde der Editor das Rechteck beim Vorbefüllen
            // auf ein falsches Verhältnis zwingen.
            var aspect = CropAspect(rawValue: mapAspectLabel(raw.aspect)) ?? .free
            if let ratio = aspect.ratio {
                let actualRatio = (rect.width * originalPixelSize.width)
                    / (rect.height * originalPixelSize.height)
                if abs(actualRatio - ratio) / ratio > 0.03 { aspect = .free }
            }

            // Fehlender Score = neutral durchlassen (7): Toleranz gegenüber Modellen,
            // die das Feld ignorieren, darf keine Vorschläge kosten.
            let score = min(10, max(0, raw.score ?? minScore))

            let suggestion = CropSuggestion(
                id: UUID(),
                rect: rect,
                title: raw.title.trimmingCharacters(in: .whitespacesAndNewlines),
                rationale: raw.rationale.trimmingCharacters(in: .whitespacesAndNewlines),
                aspect: aspect,
                megapixels: megapixels,
                score: score
            )

            // Fast-Duplikate (IoU > 0.9) verwerfen
            if (accepted + scoreRejected).contains(where: { intersectionOverUnion($0.rect, rect) > 0.9 }) {
                continue
            }

            if score >= minScore {
                accepted.append(suggestion)
            } else {
                result.droppedByScore += 1
                scoreRejected.append(suggestion)
            }
        }

        // Fallback: alles unter der Score-Schwelle → die besten zwei behalten.
        if accepted.isEmpty && !scoreRejected.isEmpty {
            accepted = Array(scoreRejected.sorted { $0.score > $1.score }.prefix(2))
            result.droppedByScore = scoreRejected.count - accepted.count
        }

        // Beste zuerst — Score entscheidet, bei Gleichstand bleibt die Modellreihenfolge.
        result.suggestions = accepted.enumerated()
            .sorted { ($0.element.score, $1.offset) > ($1.element.score, $0.offset) }
            .map(\.element)
        return result
    }

    /// Normiert die Modell-Koordinaten. Werte deutlich über 1 sind Pixel-Koordinaten —
    /// je nach Größe relativ zur verschickten Vorschau oder zum Original.
    private static func normalizedRect(
        from raw: RawSuggestion,
        previewPixelSize: CGSize,
        originalPixelSize: CGSize
    ) -> CGRect? {
        let values = [raw.x, raw.y, raw.width, raw.height]
        guard values.allSatisfy(\.isFinite) else { return nil }

        // Leicht negative Ursprünge sind normiert gemeint und werden später geklemmt.
        if values.allSatisfy({ $0 >= -0.5 && $0 <= 1.5 }) {
            return CGRect(x: raw.x, y: raw.y, width: raw.width, height: raw.height)
        }
        guard values.allSatisfy({ $0 >= 0 }) else { return nil }

        // Pixel-Heuristik: passt das Rechteck in die Vorschau, wurde in Vorschau-Pixeln
        // geantwortet, sonst in Original-Pixeln.
        let fitsPreview = previewPixelSize.width > 0 && previewPixelSize.height > 0
            && raw.x + raw.width <= Double(previewPixelSize.width) * 1.05
            && raw.y + raw.height <= Double(previewPixelSize.height) * 1.05
        let denom = fitsPreview ? previewPixelSize : originalPixelSize
        guard denom.width > 0, denom.height > 0 else { return nil }
        return CGRect(
            x: raw.x / denom.width,
            y: raw.y / denom.height,
            width: raw.width / denom.width,
            height: raw.height / denom.height
        )
    }

    /// Modell-Label → `CropAspect.rawValue` (die rawValues sind deutsch, „Frei" groß).
    private static func mapAspectLabel(_ label: String?) -> String {
        guard let label else { return CropAspect.free.rawValue }
        if label.caseInsensitiveCompare("frei") == .orderedSame { return CropAspect.free.rawValue }
        return label
    }

    static func intersectionOverUnion(_ a: CGRect, _ b: CGRect) -> Double {
        let inter = a.intersection(b)
        guard !inter.isNull, inter.width > 0, inter.height > 0 else { return 0 }
        let interArea = inter.width * inter.height
        let unionArea = a.width * a.height + b.width * b.height - interArea
        guard unionArea > 0 else { return 0 }
        return interArea / unionArea
    }

    // MARK: - Koordinaten-Helfer

    /// Normierte Top-Left-Fraktion → ganzzahliges Pixel-Rechteck (Rasterraum, Ursprung
    /// oben links — die Konvention von `CGImage.cropping(to:)`).
    static func pixelRect(fraction: CGRect, imageSize: CGSize) -> CGRect {
        let x = (fraction.minX * imageSize.width).rounded(.down)
        let y = (fraction.minY * imageSize.height).rounded(.down)
        let w = (fraction.width * imageSize.width).rounded()
        let h = (fraction.height * imageSize.height).rounded()
        return CGRect(
            x: max(0, x),
            y: max(0, y),
            width: min(w, imageSize.width - max(0, x)),
            height: min(h, imageSize.height - max(0, y))
        )
    }
}
