import Foundation

/// Übersetzt die Landesangabe des Servers in einen Kurznamen für den Albumtitel.
///
/// Immich geokodiert serverseitig über GeoNames und liefert die amtliche
/// Langform: `Islamic Republic of Iran`, `United Republic of Tanzania`,
/// `Republic of Korea`. In einem Albumnamen ist das unbrauchbar — gewollt ist
/// „Iran".
///
/// Bewusst **kein** Wörterbuch im Quelltext: Eine Liste mit 200 Ländern veraltet,
/// ist nicht übersetzt und wäre die längste Datei des Projekts. Stattdessen die
/// ISO-Regionen des Systems, die Namen und Übersetzungen mitbringen.
@MainActor
enum TripAlbumNaming {

    /// Vorschlag für den Albumnamen einer Etappe.
    ///
    /// Zwei Schemata, weil zwei verschiedene Fragen dahinterstehen:
    ///
    /// - **Bibliothek** — `2006 - März - Iran - Shiraz`, im Inland ohne Land:
    ///   `2024 - Juli - Hamburg`. Jahr zuerst, damit die alphabetisch sortierte
    ///   Albumliste von selbst chronologisch steht. Das Land nur im Ausland, weil
    ///   „Deutschland" in jedem zweiten Albumnamen nichts unterscheidet.
    /// - **Album aufteilen** (`albumPrefix` gesetzt) — `Japan 2024 – Tokio`. Hier
    ///   ist die Zugehörigkeit zur Reise die wichtigere Information, und Immich
    ///   kennt keine Unteralben: Sie kann nur im Namen stehen.
    ///
    /// - Parameter homeCountry: Rohwert des Servers, wie `segment.country`. Ist er
    ///   `nil` — etwa weil die Bibliothek keinen Heimatort hergibt —, gilt jedes
    ///   bekannte Land als Ausland. Das Land zu nennen, wo es nicht nötig wäre, ist
    ///   der harmlosere der beiden Fehler.
    static func defaultName(for segment: TripSegment,
                            albumPrefix: String?,
                            homeCountry: String?) -> String {
        if let albumPrefix {
            return "\(albumPrefix) – \(segment.label)"
        }

        let jahr = year.string(from: segment.start)
        let monat = month.string(from: segment.start)

        // Rohwerte vergleichen, nicht Kurznamen: Der Kurzname kann auf den Rohwert
        // zurückfallen, und dann stünde eine Langform gegen eine Kurzform.
        let istAusland = segment.country != nil && segment.country != homeCountry
        if istAusland, let land = TripCountryName.short(segment.country) {
            return "\(jahr) - \(monat) - \(land) - \(segment.label)"
        }
        return "\(jahr) - \(monat) - \(segment.label)"
    }

    /// Vorschlag für den Albumnamen einer ganzen Reise.
    ///
    /// Dasselbe Schema wie bei der Etappe, nur ohne Ortsteil: `2007 - Juni -
    /// Vereinigte Staaten`. Der Ort fiele hier ohnehin willkürlich aus — die Reise
    /// hat mehrere, und einen davon zum Titel zu machen unterschlüge die anderen.
    ///
    /// Der Monat kommt vom **Beginn** der Reise, auch wenn sie über den Monatswechsel
    /// läuft. Ein Bereich im Albumnamen („Juni–Juli") ist länger, sortiert schlechter
    /// und beantwortet keine Frage, die der Zeitraum in der Ansicht nicht schon
    /// beantwortet.
    static func defaultName(for group: TripGroup,
                            albumPrefix: String?,
                            homeCountry: String?) -> String {
        // Ohne Land bleibt nur die Etappe: Ein Titel „2007 - Juni" wäre kein Name,
        // sondern ein Datum.
        guard let land = TripCountryName.short(group.country) else {
            guard let first = group.segments.first else { return "" }
            return defaultName(for: first, albumPrefix: albumPrefix, homeCountry: homeCountry)
        }

        if let albumPrefix { return "\(albumPrefix) – \(land)" }

        let jahr = year.string(from: group.start)
        let monat = month.string(from: group.start)
        // Im Inland trüge jedes zweite Album denselben Zusatz — dann lieber den Ort
        // der ersten Etappe, wie beim Einzelvorschlag.
        guard group.country != homeCountry else {
            guard let first = group.segments.first else { return "\(jahr) - \(monat)" }
            return "\(jahr) - \(monat) - \(first.label)"
        }
        return "\(jahr) - \(monat) - \(land)"
    }

    private static let year: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateFormat = "yyyy"
        return formatter
    }()

    /// `LLLL` statt `MMMM`: die alleinstehende Form („März"), nicht die im Datum
    /// gebeugte. In manchen Sprachen ist das ein Unterschied, im Albumnamen steht
    /// der Monat immer allein.
    private static let month: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateFormat = "LLLL"
        return formatter
    }()
}

@MainActor
enum TripCountryName {

    /// Der deutsche Kurzname zu einer Landesangabe, sonst der Rohwert.
    ///
    /// Der Rohwert als Rückfall ist Absicht: Ein unbekanntes Land soll im Albumnamen
    /// stehen, wie es der Server nennt — falsch benannt ist besser als gar nicht
    /// benannt.
    static func short(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        if let cached = cache[trimmed] { return cached }
        let resolved = resolve(trimmed) ?? trimmed
        cache[trimmed] = resolved
        return resolved
    }

    // MARK: - Intern

    /// Der Durchlauf über ~250 Regionen kostet zwei `localizedString`-Aufrufe je
    /// Region. Das darf nicht bei jedem Neuzeichnen einer Karte passieren.
    private static var cache: [String: String] = [:]

    private static let german = Locale(identifier: "de_DE")
    private static let english = Locale(identifier: "en_US")

    private static func resolve(_ raw: String) -> String? {
        var bestMatch: (name: String, length: Int)?

        for region in Locale.Region.isoRegions {
            let code = region.identifier
            guard let deutsch = german.localizedString(forRegionCode: code) else { continue }
            let englisch = english.localizedString(forRegionCode: code)

            // 1. Volltreffer — der Server nennt das Land schon kurz.
            if raw.caseInsensitiveCompare(deutsch) == .orderedSame { return deutsch }
            if let englisch, raw.caseInsensitiveCompare(englisch) == .orderedSame { return deutsch }

            // 2. Die Langform enthält den Kurznamen: „Islamic Republic of **Iran**".
            //
            //    Der längste Treffer gewinnt, und das ist keine Feinheit: „Niger"
            //    steckt in „Nigeria". Ohne diese Regel hinge das Ergebnis daran, in
            //    welcher Reihenfolge das System seine Regionen aufzählt.
            for candidate in [deutsch, englisch].compactMap({ $0 }) {
                guard contains(raw, word: candidate) else { continue }
                if bestMatch == nil || candidate.count > bestMatch!.length {
                    bestMatch = (deutsch, candidate.count)
                }
            }
        }

        return bestMatch?.name
    }

    /// Enthält `haystack` das Wort `word` — an Wortgrenzen, nicht mitten drin?
    ///
    /// Ohne Wortgrenzen fände „Oman" sich in „Romania" wieder.
    private static func contains(_ haystack: String, word: String) -> Bool {
        guard !word.isEmpty else { return false }
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: word, options: [.caseInsensitive],
                                         range: searchRange) {
            let beforeOK = found.lowerBound == haystack.startIndex
                || !haystack[haystack.index(before: found.lowerBound)].isLetter
            let afterOK = found.upperBound == haystack.endIndex
                || !haystack[found.upperBound].isLetter
            if beforeOK && afterOK { return true }
            guard found.upperBound < haystack.endIndex else { return false }
            searchRange = found.upperBound..<haystack.endIndex
        }
        return false
    }
}
