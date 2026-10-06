import Foundation

/// Trefferregel des Live-Schnellfilters der Albenansicht.
///
/// Bewusst ein reiner Typ ohne SwiftUI-Bezug: Die Regel entscheidet, was der
/// Nutzer beim Tippen sieht, und ist damit das einzige Stück des Filters, das
/// sich lohnt zu testen. Die Ansicht ruft sie nur auf.
///
/// Das ist **keine Suche**: kein Serveraufruf, kein Ladezustand — nur ein Sieb
/// über die bereits im Speicher liegenden Alben.
enum AlbumNameFilter {

    /// Passt `name` auf `query`?
    ///
    /// Wortweise und ohne feste Reihenfolge: Die Eingabe wird an Leerzeichen
    /// zerlegt, jedes Wort muss irgendwo im Namen vorkommen. Nötig, weil
    /// Albennamen hier mit Datumspräfixen beginnen — „iran perse" soll
    /// „2006 03 Iran 03-31 Persepolis" finden, obwohl zwischen den beiden
    /// Wörtern noch „03-31" steht.
    ///
    /// Groß-/Kleinschreibung und Akzente sind egal („weihnachtsmarkte" findet
    /// „Weihnachtsmärkte"). Eine leere oder nur aus Leerzeichen bestehende
    /// Eingabe lässt alles durch — sonst wäre die Liste leer, bevor man tippt.
    static func matches(_ name: String, query: String) -> Bool {
        let words = normalizedWords(query)
        guard !words.isEmpty else { return true }
        let haystack = normalize(name)
        return words.allSatisfy { haystack.contains($0) }
    }

    /// Siebt `albums` nach ihrem Namen. Reihenfolge bleibt erhalten.
    static func apply(_ albums: [Album], query: String) -> [Album] {
        let words = normalizedWords(query)
        guard !words.isEmpty else { return albums }
        return albums.filter { album in
            let haystack = normalize(album.albumName)
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    private static func normalizedWords(_ query: String) -> [String] {
        normalize(query)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
