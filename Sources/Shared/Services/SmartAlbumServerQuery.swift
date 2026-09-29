import Foundation

/// Übersetzt das Regelwerk eines Smart Albums in **einen** Filter der strukturierten
/// Suche (Immich v3.2.0) — aber nur, wenn jede Regel dort exakt dieselbe Bedeutung hat
/// wie im lokalen ``SmartAlbumEvaluator``. Sonst `nil`, und der Aufrufer rechnet wie
/// bisher lokal.
///
/// Warum so streng: Der Spiegel-Abgleich legt das Ergebnis in ein echtes Immich-Album.
/// Ein zu weiter Filter lüde fremde Fotos hinein, ein zu enger räumte es aus. Am
/// 11.09.2026 lieferte der Filter für alle sieben Spiegel-Alben des Nutzers exakt die
/// Menge, die die lokale Auswertung vorher hineingelegt hatte.
///
/// Was den lokalen Weg behält, und warum:
/// - Heuristiken ohne Serverfeld (`isRAW`, `isScreenshot`, `isPanorama`,
///   `isWebOrMessenger`), Felder ohne Filter (`fNumberMax`, `isoMin`, `isStacked`,
///   GPS, `monthOfYear`) und `hasNoCameraInfo` (lokal zählen auch leere Zeichenfolgen).
/// - `isInNoAlbum`: Der Serverfilter `hasAlbums` zählte das eigene Spiegel-Album mit —
///   die gerade eingespiegelten Fotos fielen beim nächsten Lauf wieder heraus.
/// - Negierte Orts-, Kamera-, Datums-, Endungs- und Größenregeln: `NOT IN`/`gt`
///   schließen NULL-Zeilen aus, die lokale Negation nimmt sie auf („kein Ort" ist
///   lokal „nicht in Japan").
enum SmartAlbumServerQuery {

    /// Wertelisten, gegen die Regeltexte aufgelöst werden. Lokal vergleichen Land und
    /// Stadt ohne Groß-/Kleinschreibung und die Kamera per „enthält"; der Server kennt
    /// nur exakte Gleichheit. Die Regel wird deshalb auf die passenden Serverwerte
    /// abgebildet (`in: [...]`).
    enum CatalogKind: String, Hashable, Sendable {
        case country
        case city
        case cameraModel = "camera-model"

        /// Der `type` von `GET /api/search/suggestions`.
        var suggestionType: String { rawValue }
    }

    struct Catalog: Sendable {
        var values: [CatalogKind: [String]]
    }

    /// Welche Kataloge das Regelwerk braucht — oder `nil`, wenn es nicht vollständig
    /// auf den Server passt.
    static func requiredCatalogs(for entries: [SmartAlbumRuleEntry]) -> Set<CatalogKind>? {
        guard !entries.isEmpty else { return nil }
        var kinds = Set<CatalogKind>()
        for entry in entries {
            switch support(for: entry) {
            case .none: return nil
            case .some(.plain): break
            case .some(.needs(let kind)): kinds.insert(kind)
            }
        }
        return kinds
    }

    /// Der Filter für das ganze Regelwerk, oder `nil`: Regel ohne Entsprechung, ein
    /// Feld zweimal im Modus „alle", oder ein Regeltext ohne Treffer im Katalog.
    ///
    /// Letzteres ist bewusst `nil` und nicht ein Filter, der nichts findet: Ein leerer
    /// Katalog (etwa nach einem stillen Ausfall) räumte sonst das Server-Album leer.
    ///
    /// - Parameter calendar: nur für Tests. Der lokale Auswerter rechnet mit
    ///   `Calendar.current`; wer etwas anderes übergibt, bekommt andere Jahresgrenzen.
    static func filter(
        for entries: [SmartAlbumRuleEntry],
        matchMode: SmartAlbumMatchMode,
        catalog: Catalog,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> SearchFilter? {
        guard requiredCatalogs(for: entries) != nil else { return nil }

        if matchMode == .any, entries.count > 1 {
            var result = SearchFilter.visibleLibrary(type: nil)
            var branches: [SearchFilter] = []
            for entry in entries {
                var branch = SearchFilter()
                if case .containsPerson(let id, _) = entry.rule {
                    branch.personIds = entry.isNegated ? .noneOf([id]) : .anyOf([id])
                } else {
                    guard let condition = condition(for: entry, catalog: catalog, now: now, calendar: calendar)
                    else { return nil }
                    condition.apply(&branch)
                }
                branches.append(branch)
            }
            result.or = branches
            return result
        }

        // Modus „alle" — und „einer" mit einer einzigen Regel, das ist dasselbe.
        var result = SearchFilter.visibleLibrary(type: nil)
        var usedFields = Set<String>()
        var withPersons: [String] = []
        var withoutPersons: [String] = []
        for entry in entries {
            if case .containsPerson(let id, _) = entry.rule {
                if entry.isNegated {
                    if !withoutPersons.contains(id) { withoutPersons.append(id) }
                } else {
                    if !withPersons.contains(id) { withPersons.append(id) }
                }
                continue
            }
            guard let condition = condition(for: entry, catalog: catalog, now: now, calendar: calendar),
                  usedFields.insert(condition.field).inserted
            else { return nil }
            condition.apply(&result)
        }
        if !withPersons.isEmpty || !withoutPersons.isEmpty {
            result.personIds = SearchIds(
                all: withPersons.isEmpty ? nil : withPersons,
                none: withoutPersons.isEmpty ? nil : withoutPersons
            )
        }
        return result
    }

    // MARK: - Einzelregeln

    private enum Support {
        case plain
        case needs(CatalogKind)
    }

    /// Erschöpfend und ohne `default`, wie `SmartAlbumEvaluator.usesExifDependentRule`:
    /// Eine neue Regel soll den Bau brechen und eine Entscheidung erzwingen, statt still
    /// als „geht auf den Server" durchzurutschen.
    private static func support(for entry: SmartAlbumRuleEntry) -> Support? {
        switch entry.rule {
        case .containsPerson, .isFavorite, .assetTypeIs:
            return .plain
        case .dateRange, .lastXDays, .yearIs, .fileExtensionIs, .fileSizeMaxKB:
            return entry.isNegated ? nil : .plain
        case .country:
            return entry.isNegated ? nil : .needs(.country)
        case .city:
            return entry.isNegated ? nil : .needs(.city)
        case .cameraModel:
            return entry.isNegated ? nil : .needs(.cameraModel)
        case .monthOfYear, .hasLocation, .hasNoLocation, .fNumberMax, .isoMin,
             .hasNoCameraInfo, .isRAW, .isScreenshot, .isPanorama, .isStacked,
             .isWebOrMessenger, .isInNoAlbum:
            return nil
        }
    }

    private struct Condition {
        /// Der Filter-Schlüssel — zweimal derselbe passt nicht in *einen* Filter.
        let field: String
        let apply: (inout SearchFilter) -> Void
    }

    private static func condition(
        for entry: SmartAlbumRuleEntry,
        catalog: Catalog,
        now: Date,
        calendar: Calendar
    ) -> Condition? {
        let negated = entry.isNegated
        switch entry.rule {
        case .isFavorite:
            return Condition(field: "isFavorite") { $0.isFavorite = .equals(!negated) }

        case .assetTypeIs(let type):
            return Condition(field: "type") { $0.type = negated ? .notEquals(type) : .equals(type) }

        // Lokal: `d >= from && d <= to` auf `fileCreatedAt` — `takenAt` vergleicht dasselbe.
        // Offene Seiten (`distantPast`/`distantFuture`) gehen nicht an den Server.
        case .dateRange(let from, let to):
            return Condition(field: "takenAt") { $0.takenAt = .dateRange(from: from, to: to) }

        case .lastXDays(let days):
            let cutoff = SmartAlbumEvaluator.lastXDaysCutoff(days, now: now)
            return Condition(field: "takenAt") { $0.takenAt = .onOrAfter(cutoff) }

        // Lokal: `calendar.component(.year, from: d) == year`.
        case .yearIs(let year):
            guard let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
                  let end = calendar.date(byAdding: .year, value: 1, to: start)
            else { return nil }
            return Condition(field: "takenAt") { $0.takenAt = .between(start, and: end) }

        // Lokal: `pathExtension.lowercased() == ext.lowercased()`; `endsWith` ist
        // ebenfalls ohne Groß-/Kleinschreibung. Eine leere Endung träfe lokal Dateien
        // ohne Endung, auf dem Server Dateien auf „." — nicht dasselbe.
        case .fileExtensionIs(let ext):
            let clean = ext.lowercased()
            guard !clean.isEmpty, !clean.contains(".") else { return nil }
            return Condition(field: "originalFileName") { $0.originalFileName = .hasSuffix(".\(clean)") }

        case .fileSizeMaxKB(let kb):
            return Condition(field: "fileSizeInBytes") { $0.fileSizeInBytes = .atMost(kb * 1024) }

        case .country(let text):
            let values = (catalog.values[.country] ?? [])
                .filter { $0.localizedCaseInsensitiveCompare(text) == .orderedSame }
            guard !values.isEmpty else { return nil }
            return Condition(field: "country") { $0.country = .oneOf(values) }

        case .city(let text):
            let values = (catalog.values[.city] ?? [])
                .filter { $0.localizedCaseInsensitiveCompare(text) == .orderedSame }
            guard !values.isEmpty else { return nil }
            return Condition(field: "city") { $0.city = .oneOf(values) }

        case .cameraModel(let text):
            guard !text.isEmpty else { return nil }
            let values = (catalog.values[.cameraModel] ?? [])
                .filter { $0.localizedCaseInsensitiveContains(text) }
            guard !values.isEmpty else { return nil }
            return Condition(field: "model") { $0.model = .oneOf(values) }

        case .containsPerson, .monthOfYear, .hasLocation, .hasNoLocation, .fNumberMax,
             .isoMin, .hasNoCameraInfo, .isRAW, .isScreenshot, .isPanorama, .isStacked,
             .isWebOrMessenger, .isInNoAlbum:
            return nil
        }
    }
}
