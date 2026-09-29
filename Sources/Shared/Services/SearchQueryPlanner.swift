import Foundation

// MARK: - SearchPlan

/// Was aus Freitext und Filter-Chips wird: ein Serveraufruf plus die Teile, die der
/// Server nicht kann.
struct SearchPlan: Equatable {

    /// Welcher Endpunkt die Grundmenge liefert.
    enum Strategy: Equatable {
        /// `POST /api/search/smart` — CLIP-Text plus serverseitige Filter.
        case clipHybrid
        /// `POST /api/search/metadata` — nur Filter, kein Text.
        case metadataOnly
        /// Kein Serveraufruf nötig: Umkreis-Chips allein lassen sich vollständig aus
        /// dem lokalen Index beantworten.
        case localOnly
        /// Nichts zu suchen.
        case none
    }

    /// Warum diese Kombination nie etwas finden kann.
    ///
    /// Ohne diesen Fall liefert die Suche stumme null Treffer, und die Ursache — zwei
    /// Zeiträume, die sich nicht überschneiden — steht nirgends.
    ///
    /// Mehrere Orte, Länder oder Medientypen waren bis Server v3.1 ebenfalls ein
    /// Widerspruch, weil die Suche je Merkmal nur einen Wert kannte. Seit der
    /// strukturierten Suche (v3.2) sind sie ODER-verknüpft.
    enum Conflict: Equatable {
        case emptyDateRange

        var message: String {
            switch self {
            case .emptyDateRange:
                return "Die gewählten Zeiträume überschneiden sich nicht."
            }
        }
    }

    var strategy: Strategy = .none
    var query: String = ""
    var serverFilters: ServerFilters = ServerFilters()
    /// Lokal über den Grid-Index aufzulösen — der Server kennt keinen Umkreis.
    var nearby: [NearbyFilter] = []
    var conflict: Conflict?

    /// Ob nach der Serverantwort noch lokal geschnitten werden muss.
    var needsLocalIntersection: Bool { !nearby.isEmpty }
}

// MARK: - ServerFilters

/// Die serverseitig abbildbaren Chips, bevor sie zum ``SearchFilter`` werden.
///
/// Innerhalb eines Merkmals ODER (Ort, Land, Medientyp — ein Foto hat davon genau
/// einen), zwischen den Merkmalen UND. Personen, Tags und Alben sind ebenfalls UND:
/// „Ben" und „Clara" heißt beide auf dem Foto — so rechnete auch die alte Suche
/// (`hasPeople`/`hasTags` verlangten alle).
struct ServerFilters: Equatable {
    var types: [AssetType] = []
    var personIds: [String] = []
    var tagIds: [String] = []
    var albumIds: [String] = []
    var cities: [String] = []
    var countries: [String] = []
    var cameraMakes: [String] = []
    var cameraModels: [String] = []
    /// Text im Bild (OCR). Der Server kennt nur **ein** `ocr`-Feld; mehrere Chips
    /// gehen zusammen als ein Suchtext hinein.
    var imageTexts: [String] = []
    var isFavorite: Bool?
    var takenAfter: Date?
    var takenBefore: Date?

    var isEmpty: Bool {
        types.isEmpty && personIds.isEmpty && tagIds.isEmpty && albumIds.isEmpty
            && cities.isEmpty && countries.isEmpty && cameraMakes.isEmpty && cameraModels.isEmpty
            && imageTexts.isEmpty && isFavorite == nil && takenAfter == nil && takenBefore == nil
    }

    /// Der Filter für `/api/search/metadata` und `/api/search/smart`.
    ///
    /// Nur `trashedAt: null`, keine Sichtbarkeit: Die alte Suche nahm standardmäßig
    /// alles außer `locked` (Archiv eingeschlossen) und ließ den Papierkorb weg — die
    /// strukturierte Form nähme ihn ohne diese Bedingung mit.
    var searchFilter: SearchFilter {
        var filter = SearchFilter()
        filter.trashedAt = .isNull
        if types.count == 1 { filter.type = .equals(types[0]) }
        if types.count > 1 { filter.type = .oneOf(types) }
        if !cities.isEmpty { filter.city = .oneOf(cities) }
        if !countries.isEmpty { filter.country = .oneOf(countries) }
        // Ein Foto hat genau eine Kamera: mehrere Werte eines Felds sind ODER.
        if !cameraMakes.isEmpty { filter.make = .oneOf(cameraMakes) }
        if !cameraModels.isEmpty { filter.model = .oneOf(cameraModels) }
        if !personIds.isEmpty { filter.personIds = .allOf(personIds) }
        if !tagIds.isEmpty { filter.tagIds = .allOf(tagIds) }
        if !albumIds.isEmpty { filter.albumIds = .allOf(albumIds) }
        if !imageTexts.isEmpty { filter.ocr = .matches(imageTexts.joined(separator: " ")) }
        if let isFavorite { filter.isFavorite = .equals(isFavorite) }
        // Wie die alte Suche: `takenAfter` war `>=`, `takenBefore` war `<=`. Seit den
        // Zeitraum-Chips darf eine Seite offen sein („seit 2020", „bis 2018").
        switch (takenAfter, takenBefore) {
        case let (von?, bis?): filter.takenAt = .between(von, andIncluding: bis)
        case let (von?, nil):  filter.takenAt = .onOrAfter(von)
        case let (nil, bis?):  filter.takenAt = .onOrBefore(bis)
        case (nil, nil):       break
        }
        return filter
    }
}

// MARK: - NearbyFilter

struct NearbyFilter: Equatable {
    let lat: Double
    let lon: Double
    let radius: Double
}

// MARK: - SearchQueryPlanner

/// Übersetzt Freitext + Filter-Chips in einen ``SearchPlan``. Rein rechnend, ohne Netz
/// und ohne Datenbank — damit die Kombinationsregeln prüfbar sind, statt in einer View
/// zu verschwinden.
enum SearchQueryPlanner {

    static func plan(query rawQuery: String, tokens: [SearchToken]) -> SearchPlan {
        let query = rawQuery.trimmingCharacters(in: .whitespaces)
        var plan = SearchPlan(query: query)

        var filters = ServerFilters()
        var ranges = [(from: Date?, to: Date?)]()

        func appendUnique<T: Equatable>(_ value: T, to list: inout [T]) {
            if !list.contains(value) { list.append(value) }
        }

        for token in tokens {
            switch token {
            case .type(let t):              appendUnique(t, to: &filters.types)
            case .person(let id, _):        appendUnique(id, to: &filters.personIds)
            case .tag(let id, _):           appendUnique(id, to: &filters.tagIds)
            case .album(let id, _):         appendUnique(id, to: &filters.albumIds)
            case .city(let c):              appendUnique(c, to: &filters.cities)
            case .country(let c):           appendUnique(c, to: &filters.countries)
            case .favorite:                 filters.isFavorite = true
            case .imageText(let text):      appendUnique(text, to: &filters.imageTexts)
            case .year, .date, .dateRange:
                if let range = token.dateRange { ranges.append(range) }
            case .camera(let field, let values, _):
                for value in values {
                    switch field {
                    case .make:  appendUnique(value, to: &filters.cameraMakes)
                    case .model: appendUnique(value, to: &filters.cameraModels)
                    }
                }
            case .nearby(let lat, let lon, let radius, _):
                plan.nearby.append(NearbyFilter(lat: lat, lon: lon, radius: radius))
            }
        }

        // Zeiträume schneiden statt überschreiben: Der späteste Anfang und das
        // früheste Ende gewinnen — genau die Menge, die alle Chips erfüllt. Offene
        // Seiten zählen dabei nicht mit.
        if !ranges.isEmpty {
            let from = ranges.compactMap(\.from).max()
            let to = ranges.compactMap(\.to).min()
            if let from, let to, from > to {
                plan.conflict = .emptyDateRange
            }
            filters.takenAfter = from
            filters.takenBefore = to
        }

        plan.serverFilters = filters

        if !query.isEmpty {
            plan.strategy = .clipHybrid
        } else if !filters.isEmpty {
            plan.strategy = .metadataOnly
        } else if plan.needsLocalIntersection {
            plan.strategy = .localOnly
        } else {
            plan.strategy = .none
        }

        return plan
    }
}

// MARK: - Trefferdeckel

extension SearchQueryPlanner {

    /// Wie viele Treffer eine Freitextsuche höchstens liefern soll — `nil` heißt
    /// „kein Deckel".
    ///
    /// CLIP kennt keine Trefferschwelle: `/api/search/smart` ordnet *alle* Assets nach
    /// Ähnlichkeit und schneidet nichts ab, und die Antwort trägt keinen
    /// Ähnlichkeitswert, an dem sich eine echte Schwelle festmachen ließe. Möglich ist
    /// allein ein Schnitt nach Rang — und der gehört hierher, zur übrigen
    /// Kombinationslogik, statt als Zahl in den API-Client.
    static func resultCap(for plan: SearchPlan) -> Int? {
        guard plan.strategy == .clipHybrid else { return nil }
        // Der Umkreis schneidet die Antwort erst danach lokal. Mit 300 blieben von
        // „Sushi" in einer Straße womöglich drei Fotos übrig.
        return plan.needsLocalIntersection ? clipCapBeforeLocalIntersection : clipCap
    }

    /// Reine Freitextsuche. Jenseits davon fällt die Relevanz so steil ab, dass die
    /// Treffer nur noch das Raster füllen.
    static let clipCap = 300

    /// Freitext plus Umkreis. Zugleich das Maximum, das die CLIP-Suche in der
    /// strukturierten Form (v3.2) liefert — sie blättert nicht, `size` geht bis 1000.
    static let clipCapBeforeLocalIntersection = 1000
}

// MARK: - Als Smart Album sichern

extension SearchQueryPlanner {

    struct SmartAlbumDraft: Equatable {
        var rules: [SmartAlbumRuleEntry]
        var matchMode: SmartAlbumMatchMode
    }

    struct SmartAlbumDraftProblem: Error, Equatable {
        let message: String
    }

    /// Die Regeln eines Smart Albums für diese Chips.
    ///
    /// Smart Alben kennen nur „alle Regeln" oder „eine davon". Die Suche verknüpft
    /// mehrere Orte, Länder oder Medientypen dagegen mit ODER und alles andere mit UND.
    /// Stehen nur Werte **eines** solchen Merkmals da, passt Modus „einer"; kommen
    /// weitere Chips dazu, lässt sich die Suche nicht abbilden — ein Album „Berlin und
    /// Hamburg und Favorit" träfe nie etwas.
    ///
    /// Tag-, Album- und Umkreis-Chips haben keine Regel und fallen weg, wie bisher.
    /// Kamera-Chips mit Hersteller ergeben einen Hinweis statt einer Regel.
    static func smartAlbumDraft(tokens: [SearchToken]) -> Result<SmartAlbumDraft, SmartAlbumDraftProblem> {
        var rules: [SmartAlbumRuleEntry] = []
        var orFacets: [String: Int] = [:]

        for token in tokens {
            let rule: SmartAlbumRule?
            switch token {
            case .type(let t):
                rule = .assetTypeIs(t)
                orFacets["type", default: 0] += 1
            case .city(let c):
                rule = .city(c)
                orFacets["city", default: 0] += 1
            case .country(let c):
                rule = .country(c)
                orFacets["country", default: 0] += 1
            case .person(let id, let name): rule = .containsPerson(id: id, name: name)
            case .favorite:                 rule = .isFavorite
            case .year(let y):
                // Über `yearRange`, nicht selbst gerechnet: Das Ende lag früher auf dem
                // 31. Dezember um 00:00, alles danach fiel heraus.
                rule = SmartAlbumEvaluator.yearRange(for: y).map { .dateRange(from: $0.from, to: $0.to) }
            case .date(let d):
                // Der ganze Tag, nicht ein Zeitpunkt: `parseExplicitDate` liefert
                // Mitternacht, und `from == to` traf damit praktisch nie etwas.
                let tag = SmartAlbumEvaluator.dayRange(for: d)
                rule = .dateRange(from: tag.from, to: tag.to)
            case .dateRange(let from, let to, _):
                // Offene Seiten als Platzhalter: Der lokale Auswerter vergleicht weiter
                // `d >= from && d <= to`, die Serverfilter lassen sie weg
                // (`SearchCondition.dateRange(from:to:)`).
                rule = .dateRange(from: from ?? .distantPast, to: to ?? .distantFuture)
            case .camera(let field, _, let label):
                // Die Regel prüft lokal „Modell enthält" — für einen Modell-Chip ist das
                // genau seine Wertemenge. Hersteller kann keine Regel abbilden, und
                // Weglassen ergäbe ein zu weites Album.
                guard field == .model else {
                    return .failure(SmartAlbumDraftProblem(
                        message: "Kamerahersteller kann ein Smart Album nicht abbilden – nimm ein Modell."
                    ))
                }
                rule = .cameraModel(label)
                orFacets["camera", default: 0] += 1
            case .imageText:
                // Weglassen ergäbe ein viel zu weites Album — alles statt „Reisepass".
                return .failure(SmartAlbumDraftProblem(
                    message: "Text im Bild kann ein Smart Album nicht abbilden."
                ))
            case .tag, .album, .nearby:
                rule = nil
            }
            if let rule { rules.append(SmartAlbumRuleEntry(rule)) }
        }

        let multiFacets = orFacets.filter { $0.value > 1 }
        guard !multiFacets.isEmpty else { return .success(SmartAlbumDraft(rules: rules, matchMode: .all)) }
        if multiFacets.count == 1, let facet = multiFacets.first, facet.value == rules.count {
            return .success(SmartAlbumDraft(rules: rules, matchMode: .any))
        }
        return .failure(SmartAlbumDraftProblem(message: """
            Mehrere Orte, Länder oder Medientypen verknüpft die Suche mit „oder“. \
            Ein Smart Album kann das nur allein abbilden, nicht zusammen mit weiteren Filtern.
            """))
    }
}

// MARK: - GeoDistance

/// Entfernungsrechnung für den Umkreis-Chip.
enum GeoDistance {

    static let earthRadiusMeters = 6_371_000.0

    /// Grobe Vorauswahl für SQL: ein Rechteck, das den Kreis sicher enthält.
    ///
    /// Bewusst großzügig — die genaue Kreisform macht anschließend ``meters``. Ein
    /// Rechteck lässt sich indiziert abfragen, eine Haversine-Formel nicht.
    static func boundingBox(lat: Double, lon: Double, radius: Double)
        -> (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double) {
        let latDelta = radius / earthRadiusMeters * 180 / .pi
        // Längengrade rücken zu den Polen hin zusammen; bei cos ≈ 0 (Pol) würde die
        // Division explodieren, deshalb der Deckel — dort ist ohnehin die ganze Breite
        // relevant.
        let cosLat = max(cos(lat * .pi / 180), 0.000001)
        let lonDelta = min(radius / (earthRadiusMeters * cosLat) * 180 / .pi, 180)
        return (lat - latDelta, lat + latDelta, lon - lonDelta, lon + lonDelta)
    }

    /// Haversine-Entfernung in Metern.
    static func meters(fromLat: Double, fromLon: Double, toLat: Double, toLon: Double) -> Double {
        let dLat = (toLat - fromLat) * .pi / 180
        let dLon = (toLon - fromLon) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(fromLat * .pi / 180) * cos(toLat * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earthRadiusMeters * atan2(sqrt(a), sqrt(1 - a))
    }
}
