import Foundation

// MARK: - GeminiLookService

/// Look-Empfehlung: schickt eine kleine JPEG-Fassung des Bildes mit dem Look-Katalog an
/// die Gemini Developer API und macht aus der Structured-Output-Antwort geprüfte
/// ``LookEmpfehlung``-Werte.
///
/// Alles außer dem HTTP-Aufruf ist **pur und statisch** (Prompt, Schema, Auswertung) —
/// die Tests laufen ohne Netz, wie bei ``GeminiCropService``.
///
/// Drei Befunde aus der Wegwerf-Probe vom 16.09.2026 (drei Motive, Modell
/// `gemini-3.8-flash`) stecken in diesem Aufbau:
/// - **Das ID-Enum im Schema trägt.** Keine erfundene Look-ID; die Auswertung prüft
///   trotzdem gegen den Katalog.
/// - **Überlastung ist der Normalfall**, nicht die Ausnahme: 11 von 14 Anfragen kamen
///   als HTTP 503 zurück, das Ausweichmodell antwortete dann in 6–7 s. Deshalb läuft der
///   Aufruf über ``GeminiClient/generateJSON(prompt:imageJPEG:responseSchema:model:apiKey:logLabel:)``,
///   der Wiederholung und Ausweichmodell schon mitbringt.
/// - **Die Eignungswerte diskriminieren nicht.** Alle drei Motive bekamen 8–9, auch das
///   Foto eines Bildschirms mit einem Zeitungsartikel. Deshalb fragt der Prompt getrennt,
///   **ob** ein Look lohnt, und die Antwort entscheidet über die Abzeichen.
enum GeminiLookService {

    static let defaultModel = GeminiClient.defaultModel

    /// Unter dieser Eignung fällt eine Empfehlung weg. Bleibt nichts übrig, gilt das wie
    /// „lohnt nicht" — ein leeres Raster ohne Erklärung wäre die schlechtere Antwort.
    static let minEignung: Double = 7

    /// Wie viele Looks höchstens empfohlen werden. Drei Kacheln sind im zweispaltigen
    /// Raster überschaubar; mehr Abzeichen heben sich nicht mehr ab.
    static let maxEmpfehlungen = 3

    // MARK: - Prompt

    /// Englischer Prompt (Structured-Output-Anweisungen befolgen die Modelle auf Englisch
    /// am zuverlässigsten), deutsche Ausgabetexte — dieselbe Aufteilung wie beim
    /// KI-Zuschnitt.
    ///
    /// Der Katalog geht als `id ("Name", Familie): Kurzbeschreibung` mit. Die
    /// Kurzbeschreibung ist der Hinweis **bis zum Gedankenstrich**: Dahinter stehen im
    /// Katalog interne Messwerte der Kalibrierung („Fit 17 → 3.0 bei Wirkung 13"), die im
    /// Prompt bestenfalls Rauschen und schlimmstenfalls ein falscher Qualitätshinweis wären.
    static func buildPrompt(katalog: [FilmLook]) -> String {
        let liste = katalog.map { look in
            "- \(look.id) (\"\(look.name)\", Familie \(look.familie.rawValue)): \(kurzbeschreibung(look.hinweis))"
        }.joined(separator: "\n")

        return """
        You are a colour grading expert advising a photographer which film-look preset suits \
        a specific photograph.

        Step 1 — Analyse the attached photo: subject, genre, light (hard/soft, warm/cool, time \
        of day), dominant colours, mood, and whether it would work in black and white.

        Step 2 — Decide honestly whether a film look is worth applying at all. Set "lohnt" to \
        false for photos that are documents rather than pictures: screenshots, photos of \
        screens, receipts, notes, product shots for resale, scans of paperwork. In that case \
        return an empty "empfehlungen" array and explain in one German sentence why \
        ("begruendungOhneLook").

        Step 3 — If a look is worth it, pick exactly \(maxEmpfehlungen) presets from the \
        catalogue below that genuinely suit THIS photo, ranked best first. Base the choice on \
        what you actually see, not on general popularity — different photos must get different \
        answers. Do not pick near-identical presets; include at most one black-and-white \
        treatment, and only if the photo carries it.

        Step 4 — For every pick, give an honest "eignung" from 1 to 10 and a one-sentence \
        reason in GERMAN that names something concrete in the photo (for example "warmes \
        Abendlicht auf der Fassade"), never generic praise.

        Catalogue — use the exact id:
        \(liste)

        Return JSON only, with the fields "lohnt", "begruendungOhneLook" and "empfehlungen". \
        Write "begruendung" and "begruendungOhneLook" in German, at most 25 words each.
        """
    }

    /// Der Hinweis ohne die internen Messwerte hinter dem Gedankenstrich.
    private static func kurzbeschreibung(_ hinweis: String) -> String {
        guard let bereich = hinweis.range(of: " — ") else { return hinweis }
        return String(hinweis[hinweis.startIndex..<bereich.lowerBound])
    }

    /// Structured-Output-Schema (Gemini-REST-Dialekt, Typnamen groß geschrieben). Das
    /// `enum` über die Katalog-IDs ist die eine Stelle, die erfundene Looks verhindert.
    static func responseSchema(katalog: [FilmLook]) -> [String: Any] {
        [
            "type": "OBJECT",
            "properties": [
                "lohnt": ["type": "BOOLEAN"],
                "begruendungOhneLook": ["type": "STRING"],
                "empfehlungen": [
                    "type": "ARRAY",
                    "items": [
                        "type": "OBJECT",
                        "properties": [
                            "lookID": ["type": "STRING", "enum": katalog.map(\.id)],
                            "eignung": ["type": "NUMBER"],
                            "begruendung": ["type": "STRING"],
                        ],
                        "required": ["lookID", "eignung", "begruendung"],
                        "propertyOrdering": ["lookID", "eignung", "begruendung"],
                    ],
                ],
            ],
            "required": ["lohnt", "begruendungOhneLook", "empfehlungen"],
            "propertyOrdering": ["lohnt", "begruendungOhneLook", "empfehlungen"],
        ]
    }

    // MARK: - Anfrage

    /// Holt Empfehlungen für ein Bild. Der eigentliche HTTP-Teil liegt im gemeinsamen
    /// ``GeminiClient`` — samt Wiederholung bei Überlastung und Ausweichmodell.
    static func requestEmpfehlungen(
        imageJPEG: Data,
        katalog: [FilmLook],
        model: String,
        apiKey: String
    ) async throws -> LookEmpfehlungsErgebnis {
        let jsonData = try await GeminiClient.generateJSON(
            prompt: buildPrompt(katalog: katalog),
            imageJPEG: imageJPEG,
            responseSchema: responseSchema(katalog: katalog),
            model: model,
            apiKey: apiKey,
            logLabel: "LookTipp"
        )
        let ergebnis = parse(json: jsonData, katalog: katalog)
        if ergebnis.empfehlungen.isEmpty && !ergebnis.lohnt && ergebnis.begruendungOhneLook.isEmpty {
            // Weder Empfehlung noch Begründung: Das ist keine Auskunft, sondern eine
            // unbrauchbare Antwort — als solche melden, statt „lohnt nicht" zu behaupten.
            let text = String(data: jsonData, encoding: .utf8) ?? ""
            AppLogger.ui.warning("LookTipp: unbrauchbare Antwort: \(String(text.prefix(500)))")
            throw GeminiError.emptyResponse
        }
        return ergebnis
    }

    // MARK: - Auswertung (pur)

    private struct RohAntwort: Decodable {
        let lohnt: Bool?
        let begruendungOhneLook: String?
        let empfehlungen: [RohEmpfehlung]?
    }

    private struct RohEmpfehlung: Decodable {
        let lookID: String
        let eignung: Double
        let begruendung: String?
    }

    /// Macht aus dem Modell-JSON ein geprüftes Ergebnis. Tolerant: Müll ergibt
    /// ``LookEmpfehlungsErgebnis/keine``, einzelne kaputte Einträge werden übersprungen,
    /// nie ein Throw.
    ///
    /// Reihenfolge der Prüfungen: `lohnt` zuerst (ein ausdrückliches „nein" schlägt hohe
    /// Eignungswerte), dann Katalog, Endlichkeit, Schwelle, Duplikate, Rangfolge, Deckel.
    static func parse(json: Data, katalog: [FilmLook]) -> LookEmpfehlungsErgebnis {
        let bekannteIDs = Set(katalog.map(\.id))

        let roh: RohAntwort
        if let decoded = try? JSONDecoder().decode(RohAntwort.self, from: json) {
            roh = decoded
        } else if let objekt = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] {
            // Zweiter Versuch Element für Element: Ein einzelner kaputter Eintrag (etwa
            // eine Eignung jenseits von `Double`) soll nicht die ganze Antwort kosten.
            let liste = (objekt["empfehlungen"] as? [Any] ?? []).compactMap { element -> RohEmpfehlung? in
                guard let data = try? JSONSerialization.data(withJSONObject: element) else { return nil }
                return try? JSONDecoder().decode(RohEmpfehlung.self, from: data)
            }
            roh = RohAntwort(
                lohnt: objekt["lohnt"] as? Bool,
                begruendungOhneLook: objekt["begruendungOhneLook"] as? String,
                empfehlungen: liste
            )
        } else {
            return .keine
        }

        let ohneLook = (roh.begruendungOhneLook ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        // Ein ausdrückliches „lohnt nicht" gilt, auch gegen hohe Eignungswerte.
        guard roh.lohnt != false else {
            return LookEmpfehlungsErgebnis(lohnt: false, begruendungOhneLook: ohneLook, empfehlungen: [])
        }

        var gesehen = Set<String>()
        var brauchbare: [(index: Int, wert: LookEmpfehlung)] = []
        for (index, eintrag) in (roh.empfehlungen ?? []).enumerated() {
            guard bekannteIDs.contains(eintrag.lookID),
                  eintrag.eignung.isFinite,
                  eintrag.eignung >= minEignung,
                  gesehen.insert(eintrag.lookID).inserted
            else { continue }
            brauchbare.append((index, LookEmpfehlung(
                lookID: eintrag.lookID,
                eignung: min(10, max(0, eintrag.eignung)),
                begruendung: (eintrag.begruendung ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            )))
        }

        // Beste zuerst; bei Gleichstand bleibt die Reihenfolge des Modells (`sorted` ist
        // nicht stabil, deshalb der Index als zweites Kriterium).
        let sortiert = brauchbare
            .sorted { ($0.wert.eignung, -Double($0.index)) > ($1.wert.eignung, -Double($1.index)) }
            .prefix(maxEmpfehlungen)
            .map(\.wert)

        guard !sortiert.isEmpty else {
            return LookEmpfehlungsErgebnis(lohnt: false, begruendungOhneLook: ohneLook, empfehlungen: [])
        }
        return LookEmpfehlungsErgebnis(lohnt: true, begruendungOhneLook: ohneLook, empfehlungen: sortiert)
    }
}
