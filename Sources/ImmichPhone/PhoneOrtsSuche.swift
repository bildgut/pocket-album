import Foundation

enum PhoneOrtsTrefferArt: Int, Sendable, Comparable {
    case land, stadt, region

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

struct PhoneOrtsTreffer: Identifiable, Hashable, Sendable {
    let art: PhoneOrtsTrefferArt
    let name: String
    /// Das Land, zu dem der Treffer gehört — bei `.land` der Name selbst.
    let land: String

    /// Mit Land und Art: „Paris" gibt es in Frankreich und in den USA.
    var id: String { "\(art.rawValue)|\(land)|\(name)" }

    var auswahl: PhoneSuchAuswahl {
        switch art {
        case .land: .land(name)
        case .stadt: .stadt(name, in: land)
        case .region: .region(name, in: land)
        }
    }
}

/// Das Suchfeld des Orte-Reiters — ausschließlich gegen den lokalen Katalog, nie
/// gegen den Server. Reine Funktion wie `PhoneAlbumSections`.
enum PhoneOrtsSuche {
    static let maxTreffer = 30

    /// Ohne Groß-/Kleinschreibung und **ohne Akzente**: „agia" findet „Agía Galíni",
    /// „hyogo" findet „Hyōgo".
    static func normalisiert(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Wortanfang vor Teiltreffer, dann Land vor Stadt vor Region, dann Name.
    static func treffer(_ text: String, in katalog: PhoneOrtsKatalog?, sprache: Locale = .current) -> [PhoneOrtsTreffer] {
        let suche = normalisiert(text)
        guard !suche.isEmpty, let katalog else { return [] }

        var gefunden: [(treffer: PhoneOrtsTreffer, amAnfang: Bool)] = []
        /// `auch`: weitere Schreibweisen, die denselben Treffer finden — bei Ländern
        /// der deutsche Name. Der Treffer selbst trägt immer den Servernamen, denn den
        /// braucht der Filter.
        func pruefe(_ name: String, _ art: PhoneOrtsTrefferArt, _ land: String, auch weitere: [String] = []) {
            let formen = ([name] + weitere).map(normalisiert)
            guard formen.contains(where: { $0.contains(suche) }) else { return }
            gefunden.append((PhoneOrtsTreffer(art: art, name: name, land: land), formen.contains { $0.hasPrefix(suche) }))
        }
        for land in katalog.laender {
            pruefe(land.name, .land, land.name, auch: [Laendernamen.anzeigename(fuer: land.name, sprache: sprache)])
            for stadt in land.staedte { pruefe(stadt, .stadt, land.name) }
            for region in land.regionen { pruefe(region, .region, land.name) }
        }

        return gefunden
            .sorted { a, b in
                if a.amAnfang != b.amAnfang { return a.amAnfang }
                if a.treffer.art != b.treffer.art { return a.treffer.art < b.treffer.art }
                return a.treffer.name.localizedStandardCompare(b.treffer.name) == .orderedAscending
            }
            .prefix(maxTreffer)
            .map(\.treffer)
    }
}
