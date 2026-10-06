import Foundation

// MARK: - SearchSuggestion

/// Ein Vorschlag unter der Suchleiste. Trägt bewusst *mehrere* Tokens: Die
/// Satz-Erkennung macht aus „Ben in Japan" einen einzigen Vorschlag, der Person und
/// Land zusammen setzt.
struct SearchSuggestion: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String?
    let iconName: String
    /// Kurzes Kategorie-Kürzel rechts im Vorschlag („Ort", „Person", „Land").
    /// Ohne das ist bei gleichnamigen Einträgen nicht erkennbar, was man auswählt.
    let badge: String
    let tokens: [SearchToken]
    /// Was nach dem Übernehmen im Suchfeld stehen bleibt — der Teil, den kein Chip
    /// abdeckt und der als Volltext an CLIP geht.
    let remainingQuery: String

    static func == (lhs: SearchSuggestion, rhs: SearchSuggestion) -> Bool { lhs.id == rhs.id }
}

// MARK: - SearchCatalog

/// Die lokal bekannten Namen, gegen die getippter Text gematcht wird.
struct SearchCatalog {
    var people: [Person] = []
    var cities: [(city: String, count: Int)] = []
    var countries: [(country: String, count: Int)] = []
    var tags: [TagInfo] = []
    var albums: [Album] = []
    /// Aus dem Grid-Index, uneinheitlich geschrieben („LEICA CAMERA AG" neben „LEICA").
    var cameraMakes: [String] = []
    var cameraModels: [String] = []
}

// MARK: - SearchTermMatcher

/// Macht aus getipptem Text Filtervorschläge — ohne dass man `place:` oder `person:`
/// voranstellen muss.
///
/// Das war die eigentliche Hürde der alten Suche: Die Verkettung von Chips gab es
/// längst, aber `updateSuggestions` brach ohne erkanntes Präfix sofort ab. Wer „Berlin
/// Sushi" tippte, landete vollständig bei CLIP — und CLIP kennt weder Ortsnamen als
/// Ort noch Personennamen überhaupt.
///
/// Rein rechnend: keine Netzaufrufe, keine Datenbank, damit die Regeln prüfbar bleiben.
enum SearchTermMatcher {

    /// Wörter, die Begriffe verbinden statt selbst einer zu sein. Sie trennen die
    /// Eingabe in Kandidaten, tauchen aber nie in einem Chip auf.
    static let connectors: Set<String> = [
        "in", "im", "am", "an", "auf", "bei", "beim", "aus", "von", "vom",
        "mit", "und", "der", "die", "das", "den", "dem", "zu", "zum", "zur",
        "at", "on", "with", "and", "the", "of",
        // Richtungswörter eines Zeitausdrucks: Der ist vorher schon verbraucht,
        // hier bleibt das Wort sonst unnötig im Volltext-Rest hängen.
        "seit", "bis", "nach", "vor", "ab"
    ]

    /// Ab dieser Länge darf ein Wort auch als Präfix eines Katalognamens gelten.
    /// Kürzer wäre „Am" ein Treffer auf „Amsterdam".
    private static let minPrefixLength = 3

    /// Wörter, die in einem Suchsatz nichts filtern („meine Fotos aus Berlin"). Sie
    /// werden nie ein Chip und gehen nicht an CLIP.
    static let fillers: Set<String> = [
        "mein", "meine", "meinen", "meiner", "meinem",
        "foto", "fotos", "bild", "bilder", "aufnahmen", "alle"
    ]

    /// Zwei Wörter, die zusammen einen Chip ergeben — vor den Einzelwörtern geprüft,
    /// sonst würde aus „keine Videos" der Chip Videos.
    private static let keywordPairs: [String: SearchToken] = [
        "keine videos": .type(.image), "keine video": .type(.image),
        "ohne videos": .type(.image), "ohne video": .type(.image),
        "nur fotos": .type(.image), "nur bilder": .type(.image)
    ]

    private static let keywords: [String: SearchToken] = [
        "video": .type(.video), "videos": .type(.video),
        "favorit": .favorite, "favoriten": .favorite,
        "lieblingsfoto": .favorite, "lieblingsfotos": .favorite,
        "lieblingsbild": .favorite, "lieblingsbilder": .favorite
    ]

    // MARK: Öffentliche API

    static func suggestions(
        for rawText: String,
        catalog: SearchCatalog,
        activeTokens: [SearchToken] = [],
        limit: Int = 8
    ) -> [SearchSuggestion] {
        let text = rawText.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2 else { return [] }

        let activeIds = Set(activeTokens.map(\.id))
        var result = [SearchSuggestion]()

        // Einzeltreffer zuerst berechnen: Die Satzzeile braucht sie, um nicht dasselbe
        // noch einmal anzubieten.
        let entries = entrySuggestions(for: text, catalog: catalog, activeIds: activeIds)

        // Ganze Eingabe als Satz lesen — „Ben in Japan", „Berlin Sushi", „letzten Sommer".
        let offered = Set(entries.flatMap { $0.tokens.map(\.id) })
        if let combined = phraseSuggestion(for: text, catalog: catalog, activeIds: activeIds, offered: offered) {
            result.append(combined)
        }

        result.append(contentsOf: entries)

        // Nach `id` entdoppeln, Reihenfolge erhalten.
        var seen = Set<String>()
        return result.filter { seen.insert($0.id).inserted }.prefix(limit).map { $0 }
    }

    // MARK: Satz-Erkennung

    /// Zerlegt die Eingabe in Chips plus Restwörter.
    ///
    /// Reihenfolge, jede Stufe verbraucht ihre Wörter:
    /// 1. Zeitausdrücke (``Zeitausdruck``) — vor den Katalogen, damit „Sommer 2019" ein
    ///    Zeitraum wird und nicht an einem gleichnamigen Album hängenbleibt.
    /// 2. Schlüsselwörter für Typ und Favorit, Wortpaare zuerst.
    /// 3. Kataloge: Person, Ort, Land (auch deutsch), Tag, Album, Kamera. Längere
    ///    Wortgruppen zuerst, damit „New York" nicht an „New" zerfällt.
    /// 4. Rest ohne Bindewörter und Füllwörter — der geht an CLIP.
    ///
    /// Bewusst ohne Sprachmodell: Apples lokales Modell blockierte in Proben harmlose
    /// Familiensätze („Kinder in der Badewanne") und erfand Werte.
    ///
    /// - Parameters:
    ///   - now: nur für Tests; im Betrieb die aktuelle Zeit.
    ///   - calendar: nur für Tests; im Betrieb `Calendar.current` wie die Smart-Album-Regeln.
    static func parse(
        _ text: String,
        catalog: SearchCatalog,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> (tokens: [SearchToken], remainder: String) {
        let words = preparedWords(text, catalog: catalog)
        guard !words.isEmpty else { return ([], "") }

        var consumed = [Bool](repeating: false, count: words.count)
        var found = [(index: Int, token: SearchToken)]()

        // 1. Zeitausdrücke
        for treffer in Zeitausdruck.finde(in: words, now: now, calendar: calendar) {
            treffer.woerter.forEach { consumed[$0] = true }
            found.append((treffer.woerter.lowerBound, treffer.token))
        }

        // 2. Schlüsselwörter
        if words.count > 1 {
            for start in 0..<(words.count - 1) where !consumed[start] && !consumed[start + 1] {
                guard let token = keywordPairs[fold(words[start]) + " " + fold(words[start + 1])] else { continue }
                consumed[start] = true
                consumed[start + 1] = true
                found.append((start, token))
            }
        }
        for index in words.indices where !consumed[index] {
            guard let token = keywords[fold(words[index])] else { continue }
            consumed[index] = true
            found.append((index, token))
        }

        // 3. Kataloge
        let maxGram = min(3, words.count)
        for length in stride(from: maxGram, through: 1, by: -1) {
            for start in 0...(words.count - length) {
                let range = start..<(start + length)
                guard range.allSatisfy({ !consumed[$0] }) else { continue }

                let phrase = words[range].joined(separator: " ")
                // Bindewörter sind nie selbst ein Begriff, dürfen aber innerhalb einer
                // längeren Gruppe vorkommen („Rio de Janeiro"). Füllwörter ebenso — sonst
                // träfe „Fotos" per Präfix ein Album „Fotos 2019".
                if length == 1 {
                    let folded = fold(phrase)
                    if connectors.contains(folded) || fillers.contains(folded) { continue }
                }

                guard let tokens = bestMatch(for: phrase, catalog: catalog) else { continue }
                range.forEach { consumed[$0] = true }
                found.append(contentsOf: tokens.map { (start, $0) })
            }
        }

        // 4. Rest
        let remainder = words.enumerated()
            .filter { !consumed[$0.offset] }
            .map(\.element)
            .filter { !connectors.contains(fold($0)) && !fillers.contains(fold($0)) }
            .joined(separator: " ")

        // Nach Position im Satz; bei gleicher Position (mehrere Länder aus einem Wort)
        // in Fundreihenfolge — `sorted` allein ist nicht stabil.
        let ordered = found.enumerated()
            .sorted { ($0.element.index, $0.offset) < ($1.element.index, $1.offset) }
            .map(\.element.token)
        return (ordered, remainder)
    }

    // MARK: Vorbereitung

    /// Satzzeichen, die an Wörtern kleben („Sommer," „„Berlin""), aber nie dazugehören.
    private static let punctuation = CharacterSet(charactersIn: ",.;:!?\"'„“()")

    /// Wörter ohne anhängende Satzzeichen; Bindestrich-Wörter getrennt („Leica-Fotos"),
    /// außer der ganze Ausdruck ist ein Katalogwert („X-T3", „Baden-Baden") oder eine
    /// Jahresspanne („2018-2020").
    private static func preparedWords(_ text: String, catalog: SearchCatalog) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).flatMap { raw -> [String] in
            let word = String(raw).trimmingCharacters(in: punctuation)
            guard !word.isEmpty else { return [] }
            guard word.contains("-"),
                  word.range(of: #"^\d{4}-\d{4}$"#, options: .regularExpression) == nil,
                  !isCatalogValue(word, catalog: catalog)
            else { return [word] }
            return word.split(separator: "-").map(String.init)
        }
    }

    private static func isCatalogValue(_ word: String, catalog: SearchCatalog) -> Bool {
        let needle = fold(word)
        let names = catalog.cameraModels + catalog.cameraMakes
            + catalog.cities.map(\.city) + catalog.countries.map(\.country)
            + catalog.people.map(\.displayName) + catalog.tags.map(\.value) + catalog.albums.map(\.albumName)
        return names.contains { fold($0) == needle }
    }

    private static func phraseSuggestion(
        for text: String,
        catalog: SearchCatalog,
        activeIds: Set<String>,
        offered: Set<String>
    ) -> SearchSuggestion? {
        let parsed = parse(text, catalog: catalog)
        let fresh = parsed.tokens.filter { !activeIds.contains($0.id) }
        guard !fresh.isEmpty else { return nil }

        // Ein einzelner Treffer ohne Rest, den die Einzelvorschläge darunter ohnehin
        // anbieten, wäre nur eine Dublette. Zeitraum und Kamera haben aber keine
        // Einzelvorschläge — ohne diese Ausnahme zeigte „letzten Sommer" gar nichts.
        guard fresh.count > 1 || !parsed.remainder.isEmpty || !offered.contains(fresh[0].id) else { return nil }

        let chips = fresh.map(\.label).joined(separator: " · ")
        let title = parsed.remainder.isEmpty ? chips : "\(chips) + „\(parsed.remainder)\""

        return SearchSuggestion(
            id: "phrase-" + fresh.map(\.id).joined(separator: "|") + "-" + parsed.remainder,
            title: title,
            subtitle: parsed.remainder.isEmpty
                ? "\(fresh.count) Filter aus deiner Eingabe"
                : "Filter plus Volltextsuche nach „\(parsed.remainder)\"",
            iconName: "wand.and.stars",
            badge: "Kombination",
            tokens: fresh,
            remainingQuery: parsed.remainder
        )
    }

    // MARK: Einzeltreffer

    private static func entrySuggestions(
        for text: String,
        catalog: SearchCatalog,
        activeIds: Set<String>
    ) -> [SearchSuggestion] {
        let needle = fold(text)
        var out = [SearchSuggestion]()

        func collect<T>(
            _ items: [T],
            perCategory: Int = 3,
            name: (T) -> String,
            subtitle: (T) -> String?,
            weight: (T) -> Int,
            icon: String,
            badge: String,
            token: (T) -> SearchToken
        ) {
            let scored = items.compactMap { item -> (score: Int, weight: Int, name: String, item: T)? in
                guard let score = matchScore(fold(name(item)), needle) else { return nil }
                return (score, weight(item), name(item), item)
            }
            // Drei Kriterien, weil `sorted(by:)` nicht stabil ist: Ohne vollständige
            // Ordnung ist die Reihenfolge gleichrangiger Treffer undefiniert, und die
            // Liste springt beim Tippen unter dem Cursor.
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                if $0.weight != $1.weight { return $0.weight > $1.weight }
                return $0.name.localizedCompare($1.name) == .orderedAscending
            }
            .prefix(perCategory)

            for entry in scored {
                let tok = token(entry.item)
                guard !activeIds.contains(tok.id) else { continue }
                out.append(SearchSuggestion(
                    id: "s-\(tok.id)",
                    title: name(entry.item),
                    subtitle: subtitle(entry.item),
                    iconName: icon,
                    badge: badge,
                    tokens: [tok],
                    remainingQuery: ""
                ))
            }
        }

        collect(catalog.people.filter { !$0.name.isEmpty },
                name: { (p: Person) in p.displayName },
                subtitle: { (p: Person) in p.assetCount.map { count in "\(count) Fotos" } },
                weight: { (p: Person) in p.assetCount ?? 0 },
                icon: "person.fill", badge: "Person",
                token: { (p: Person) in .person(id: p.id, name: p.displayName) })

        collect(catalog.cities,
                name: { $0.city },
                subtitle: { "\($0.count) Fotos" },
                weight: { $0.count },
                icon: "building.2.fill", badge: "Ort",
                token: { .city($0.city) })

        collect(catalog.countries,
                name: { $0.country },
                subtitle: { "\($0.count) Fotos" },
                weight: { $0.count },
                icon: "globe", badge: "Land",
                token: { .country($0.country) })

        collect(catalog.tags,
                name: { (t: TagInfo) in t.value },
                subtitle: { _ in nil },
                weight: { _ in 0 },   // Tags tragen keine Anzahl — hier entscheidet der Name
                icon: "tag.fill", badge: "Tag",
                token: { (t: TagInfo) in .tag(id: t.id, value: t.value) })

        collect(catalog.albums, perCategory: 2,
                name: { (a: Album) in a.albumName },
                subtitle: { (a: Album) in "\(a.assetCount) Fotos" },
                weight: { (a: Album) in a.assetCount },
                icon: "rectangle.stack.fill", badge: "Album",
                token: { (a: Album) in .album(id: a.id, name: a.albumName) })

        // Ein Jahr erkennt man am Format, nicht am Katalog.
        if let year = Int(text), (1900...2100).contains(year) {
            let tok = SearchToken.year(year)
            if !activeIds.contains(tok.id) {
                out.insert(SearchSuggestion(
                    id: "s-\(tok.id)", title: "\(year)", subtitle: nil,
                    iconName: "calendar", badge: "Jahr",
                    tokens: [tok], remainingQuery: ""
                ), at: 0)
            }
        }

        return out
    }

    // MARK: Vergleich

    /// Ein einzelner Katalogname gegen die Eingabe. `nil` = kein Treffer.
    /// Höher ist besser: exakt > Präfix > enthalten.
    private static func matchScore(_ candidate: String, _ needle: String) -> Int? {
        guard !needle.isEmpty, !candidate.isEmpty else { return nil }
        if candidate == needle { return 300 }
        if needle.count >= minPrefixLength, candidate.hasPrefix(needle) { return 200 }
        if needle.count >= minPrefixLength, candidate.contains(needle) { return 100 }
        return nil
    }

    /// Der beste Katalogtreffer für eine Wortgruppe. Bei Gleichstand entscheidet die
    /// Kategorie-Reihenfolge: Personen vor Orten vor Ländern vor Kamera vor Tags vor
    /// Alben — ein Vorname ist die wahrscheinlichere Absicht als ein gleichnamiges Album,
    /// und eine Kamera vor einem gleichnamigen Tag (F2b: „iPhone" vs. Tag „iphone").
    ///
    /// Tags und Alben zählen hier — anders als bei `entrySuggestions` — nur bei
    /// **exaktem** Namenstreffer (F2a): Ein Präfix- oder „enthält"-Treffer kaperte sonst
    /// zu leicht ein Wort, das eigentlich zu einer Person oder einem Ort gehörte (Album
    /// „Kinderfotos" kaperte „Kinder"; „Ben und" traf per Präfix das Album „Ben und Emma
    /// in Kiel 2011", bevor „Ben" die Person treffen konnte).
    ///
    /// Mehrere Chips, wenn ein deutscher Ländername auf zwei Servernamen passt.
    private static func bestMatch(for phrase: String, catalog: SearchCatalog) -> [SearchToken]? {
        let needle = fold(phrase)
        var best: (score: Int, rank: Int, tokens: [SearchToken])?

        func considerScore(_ score: Int?, rank: Int, tokens: @autoclosure () -> [SearchToken]) {
            // Innerhalb eines Satzes zählen nur klare Treffer; ein „enthalten"-Treffer
            // würde aus „Sushi" ein Album „Sushi-Abend" machen und den Begriff dem
            // Volltext wegnehmen.
            guard let score, score >= 200 else { return }
            if let current = best, (current.score, -current.rank) >= (score, -rank) { return }
            best = (score, rank, tokens())
        }
        func consider(_ name: String, rank: Int, token: @autoclosure () -> SearchToken) {
            considerScore(matchScore(fold(name), needle), rank: rank, tokens: [token()])
        }
        // F2a: nur der exakte Name zählt — kein Präfix, kein „enthält".
        func considerExact(_ name: String, rank: Int, token: @autoclosure () -> SearchToken) {
            considerScore(fold(name) == needle ? 300 : nil, rank: rank, tokens: [token()])
        }

        for p in catalog.people where !p.name.isEmpty {
            consider(p.displayName, rank: 0, token: .person(id: p.id, name: p.displayName))
        }
        for c in catalog.cities { consider(c.city, rank: 1, token: .city(c.city)) }
        for c in catalog.countries { consider(c.country, rank: 2, token: .country(c.country)) }

        // „Italien" → „Italy": Immich führt Länder englisch. Nur ganze Namen, deshalb
        // wie ein exakter Treffer gewichtet.
        let german = Laendernamen.servernamen(fuerDeutsch: phrase, katalog: catalog.countries.map(\.country))
        if !german.isEmpty {
            considerScore(300, rank: 2, tokens: german.map { .country($0) })
        }

        if let camera = cameraToken(for: phrase, catalog: catalog) {
            considerScore(camera.score, rank: 3, tokens: [camera.token])
        }

        for t in catalog.tags { considerExact(t.value, rank: 4, token: .tag(id: t.id, value: t.value)) }
        for a in catalog.albums { considerExact(a.albumName, rank: 5, token: .album(id: a.id, name: a.albumName)) }

        return best?.tokens
    }

    /// „Leica" → Hersteller, „iPhone"/„Q3" → Modelle.
    ///
    /// Hersteller zuerst, und zwar über den **Wortanfang** eines Herstellernamens: Die
    /// Schreibweisen im Bestand sind uneinheitlich („LEICA CAMERA AG" neben „LEICA",
    /// „EASTMAN KODAK COMPANY" neben „Eastman Kodak Company"), und nicht jedes Modell
    /// trägt den Hersteller („X-T3" ist Fujifilm) — über die Modelle fände „Fuji" nichts.
    /// Modelle per „enthält", wie die Smart-Album-Regel `cameraModel` lokal prüft; kürzer
    /// als drei Zeichen nur als ganzes Wort („Q3").
    ///
    /// Der Score (F2b): **300**, wenn das Suchwort (gefaltet) einem **ganzen Wort** eines
    /// getroffenen Hersteller- oder Modellnamens gleicht („iPhone" in „iPhone X", „Q3" in
    /// „LEICA Q3"), sonst **200** (etwa „Fuji" in „FUJIFILM", nur Wortanfang). Damit
    /// gewinnt „iPhone" (Kamera, Rang 3) gegen ein gleichnamiges Tag „iphone" (Rang 4),
    /// das sonst — exakt getroffen — vorgegangen wäre. Bei mehreren Treffern genügt ein
    /// Ganzwort-Treffer in irgendeinem der Werte für 300.
    private static func cameraToken(for phrase: String, catalog: SearchCatalog) -> (token: SearchToken, score: Int)? {
        let needle = fold(phrase)
        guard !needle.isEmpty else { return nil }

        if needle.count >= minPrefixLength {
            let makes = catalog.cameraMakes.filter { make in
                fold(make).split(separator: " ").contains { $0.hasPrefix(needle) }
            }
            if !makes.isEmpty {
                let ganzesWort = makes.contains { make in
                    fold(make).split(separator: " ").contains { $0 == needle }
                }
                return (.camera(field: .make, values: makes, label: phrase), ganzesWort ? 300 : 200)
            }
        }

        let models = catalog.cameraModels.filter { model in
            let folded = fold(model)
            if needle.count >= minPrefixLength { return folded.contains(needle) }
            return folded.split(separator: " ").contains { $0 == needle }
        }
        guard !models.isEmpty else { return nil }
        let ganzesWort = models.contains { model in
            fold(model).split(separator: " ").contains { $0 == needle }
        }
        return (.camera(field: .model, values: models, label: phrase), ganzesWort ? 300 : 200)
    }

    /// Groß-/Kleinschreibung und Akzente egal — „zurich" soll „Zürich" finden.
    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE"))
    }
}
