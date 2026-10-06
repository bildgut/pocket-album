import Foundation

/// Wahrzeichen-Erkennung: schickt eine kleine JPEG-Fassung an Gemini und macht aus
/// der Structured-Output-Antwort eine geprüfte ``LandmarkGuess``.
///
/// Alles außer dem HTTP-Aufruf (der im gemeinsamen ``GeminiClient`` liegt) ist
/// **pur und statisch** — die Tests laufen ohne Netz.
///
/// Der Dienst liefert absichtlich **keine Koordinaten**: Was das Modell sieht, ist
/// ein Name; wo dieser Name liegt, weiß eine Karte besser.
enum GeminiLandmarkService {

    /// Für Wahrzeichen reicht deutlich weniger Auflösung als für den Zuschnitt —
    /// erkannt wird an Silhouette, Fassade und Beschilderung, nicht an Details.
    /// Halbiert Upload und Bildtoken gegenüber den 2048 px des Zuschnitts.
    static let analysisMaxPixel = 1024

    // MARK: - Prompt

    /// Englische Instruktionen (Structured-Output befolgen die Modelle auf Englisch
    /// am zuverlässigsten), deutsche Ausgabetexte.
    ///
    /// Der ganze Aufbau zielt auf **eine** Eigenschaft: dass „nichts erkennbar" eine
    /// attraktive Antwort ist. Ein geratener Ort kostet hier mehr als eine Lücke,
    /// weil das Schreiben nicht rückgängig zu machen ist.
    ///
    /// Das Aufnahmedatum wandert bewusst nicht in den Prompt — es wäre eine
    /// Einladung, aus der Jahreszeit auf eine Gegend zu schließen, statt aus dem,
    /// was im Bild steht.
    static func buildPrompt() -> String {
        """
        You are a geolocation analyst. You are shown ONE photograph. Your only task is \
        to name a specific, real-world place that is visibly depicted in it.

        STEP 1 — Look for identifying evidence: named buildings, monuments, bridges, \
        towers, churches, mountains, distinctive skylines, signage, street names, \
        license plates, writing systems, characteristic vegetation or architecture.

        STEP 2 — Decide honestly whether that evidence identifies ONE specific place \
        that can be found on a map by name.

        CRITICAL — answer "not recognizable" (recognized = false) when:
        - The photo shows a generic scene: a forest, a beach, a meadow, an anonymous \
        street, an interior, a close-up, food, a document, a person against a plain \
        background.
        - You can only guess a region or a country, but not a specific, nameable place.
        - You would have to rely on the plausibility of a place rather than on visible \
        evidence.
        - Several different real places would fit equally well.

        Answering "not recognizable" is a CORRECT and valuable answer. It is much \
        better than a plausible-sounding guess. A wrong coordinate written to a photo \
        archive cannot be undone. Do not guess. Do not infer a location from the mood, \
        the style, or the likely origin of the picture.

        STEP 3 — If and only if a specific place is identified, provide:
        - "landmark": its proper name as it appears on maps, in the local language \
        (e.g. "Tour Eiffel", "Kölner Dom", "Ponte di Rialto"). A category alone \
        ("church", "town hall", "beach", "old town") is NOT a valid answer — return \
        recognized = false instead.
        - "city", "region", "country", "country_code" (ISO 3166-1 alpha-2) as far as \
        you are certain; use null for anything you are unsure about.
        - "search_query": one single line a map search engine can resolve, in the form \
        "<landmark>, <city>, <country>". This is the only string that will be looked up.
        - "confidence": 0-100, your honest probability that this exact place is \
        depicted. Use below 50 for "it looks like it, but I would not bet on it". Do \
        not inflate it.
        - "reasoning": 1-2 sentences IN GERMAN naming the concrete visual evidence you \
        used. If recognized = false, explain IN GERMAN why the picture is not \
        identifiable.

        Return JSON only, matching the given schema. Never invent coordinates; you are \
        not asked for any.
        """
    }

    /// Structured-Output-Schema (Gemini-REST-Dialekt, Typnamen groß geschrieben).
    ///
    /// `recognized` steht in `propertyOrdering` **zuerst**: Ein autoregressives Modell
    /// schreibt Feld für Feld. Ein zuerst gesetztes `false` macht die folgenden Felder
    /// konsistent leer; ein zuletzt gesetztes müsste einer bereits ausformulierten
    /// Vermutung widersprechen — und tut es dann oft nicht.
    static let responseSchema: [String: Any] = [
        "type": "OBJECT",
        "properties": [
            "recognized": ["type": "BOOLEAN"],
            "landmark": ["type": "STRING"],
            "city": ["type": "STRING", "nullable": true],
            "region": ["type": "STRING", "nullable": true],
            "country": ["type": "STRING", "nullable": true],
            "country_code": ["type": "STRING", "nullable": true],
            "search_query": ["type": "STRING"],
            "confidence": ["type": "NUMBER"],
            "reasoning": ["type": "STRING"],
        ],
        "required": ["recognized", "landmark", "search_query", "confidence", "reasoning"],
        "propertyOrdering": ["recognized", "landmark", "city", "region", "country",
                             "country_code", "search_query", "confidence", "reasoning"],
    ]

    // MARK: - Anfrage

    /// Fragt das Modell nach dem Ort. Wirft ``GeminiError``.
    static func requestGuess(imageJPEG: Data,
                             model: String,
                             apiKey: String) async throws -> LandmarkGuess {
        let json = try await GeminiClient.generateJSON(
            prompt: buildPrompt(),
            imageJPEG: imageJPEG,
            responseSchema: responseSchema,
            model: model,
            apiKey: apiKey,
            logLabel: "Wahrzeichen"
        )
        guard let guess = parse(json: json) else {
            AppLogger.ui.warning("Wahrzeichen: Antwort nicht lesbar: \(String(data: json, encoding: .utf8)?.prefix(300) ?? "")")
            throw GeminiError.badResponse
        }
        return guess
    }

    // MARK: - Auswertung

    /// Liest die Antwort. Wirft nie — unlesbares JSON ergibt `nil`.
    ///
    /// Jede Unsicherheit wird nach unten aufgelöst: Ein fehlendes Feld, ein leerer
    /// Name oder eine Gattungsbezeichnung führen zu „nichts erkennbar", nicht zu
    /// einem halben Vorschlag.
    static func parse(json: Data) -> LandmarkGuess? {
        guard let raw = try? JSONDecoder().decode(RawGuess.self, from: json) else {
            return nil
        }

        let reasoning = raw.reasoning?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = raw.landmark?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let query = raw.search_query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard raw.recognized == true, !name.isEmpty, !query.isEmpty else {
            return .notRecognized(reasoning: reasoning)
        }
        // Der Prompt verlangt das bereits — die Sperre ist die Zusicherung, nicht die
        // Wiederholung. „Rathaus" fände die Karte 200-mal, jedes Mal woanders.
        guard !LandmarkNameGuard.isGeneric(name) else {
            AppLogger.ui.debug("Wahrzeichen: Gattungsname '\(name)' verworfen")
            return .notRecognized(
                reasoning: reasoning.isEmpty
                    ? "Das Modell nannte nur eine Gattung ('\(name)'), keinen bestimmten Ort."
                    : reasoning
            )
        }
        if reasoning.range(of: #"\d+[.,]\d+\s*°?\s*[NSEWnsew]\b"#, options: .regularExpression) != nil {
            // Nicht verwerfen, aber merken: Das Modell hat die Aufgabe missverstanden.
            AppLogger.ui.warning("Wahrzeichen: Begründung enthält Koordinaten — Prompt prüfen")
        }

        return LandmarkGuess(
            recognized: true,
            name: name,
            city: clean(raw.city),
            region: clean(raw.region),
            country: clean(raw.country),
            countryCode: clean(raw.country_code)?.uppercased(),
            searchQuery: query,
            // Fehlende Angabe zählt als 0, nicht als neutraler Mittelwert: Hier ist
            // das Schweigen ein Grund zur Zurückhaltung, nicht zur Toleranz.
            confidence: min(100, max(0, Int(raw.confidence?.rounded() ?? 0))),
            reasoning: reasoning
        )
    }

    private static func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private struct RawGuess: Decodable {
        let recognized: Bool?
        let landmark: String?
        let city: String?
        let region: String?
        let country: String?
        let country_code: String?
        let search_query: String?
        let confidence: Double?
        let reasoning: String?
    }
}

// MARK: - Gattungsnamen

/// Erkennt Ortsangaben, die gar keine sind.
///
/// Eine Gattung ohne Eigennamen („Kirche", „Old Town") ist für eine Kartensuche
/// wertlos: Sie trifft überall und nirgends, und der erste Treffer wäre reiner
/// Zufall. Bewusst **exakter** Vergleich auf den ganzen Namen — „Kölner Dom" und
/// „Ponte di Rialto" enthalten Gattungswörter und müssen bleiben.
enum LandmarkNameGuard {

    static func isGeneric(_ name: String) -> Bool {
        let normalized = normalize(name)
        guard !normalized.isEmpty else { return true }
        return generics.contains(normalized)
    }

    /// Kleinschreibung, ohne Satzzeichen, ohne führenden Artikel.
    static func normalize(_ name: String) -> String {
        let lowered = name.lowercased()
            .replacingOccurrences(of: #"[^\p{L}\p{N}\s]"#, with: " ",
                                  options: .regularExpression)
        let words = lowered.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = words.first else { return "" }
        let rest = articles.contains(first) ? Array(words.dropFirst()) : words
        return rest.joined(separator: " ")
    }

    private static let articles: Set<String> = [
        "der", "die", "das", "den", "dem", "the", "la", "le", "les", "il", "el", "lo", "l",
    ]

    private static let generics: Set<String> = [
        // Deutsch
        "kirche", "dom", "kathedrale", "kapelle", "kloster", "rathaus", "bahnhof",
        "hauptbahnhof", "brücke", "strand", "altstadt", "innenstadt", "marktplatz",
        "markt", "schloss", "burg", "museum", "park", "hafen", "leuchtturm", "denkmal",
        "brunnen", "friedhof", "stadion", "flughafen", "universität", "hotel",
        "restaurant", "straße", "platz", "dorf", "stadt", "see", "berg", "wasserfall",
        "gletscher", "wald", "promenade", "aussichtspunkt", "kirchturm", "turm",
        // Englisch
        "church", "cathedral", "chapel", "monastery", "town hall", "city hall",
        "train station", "railway station", "station", "bridge", "beach", "old town",
        "city center", "city centre", "downtown", "market square", "market", "castle",
        "harbor", "harbour", "port", "lighthouse", "monument", "fountain", "cemetery",
        "stadium", "airport", "university", "street", "square", "village", "city",
        "lake", "mountain", "waterfall", "glacier", "forest", "viewpoint", "tower",
    ]
}
