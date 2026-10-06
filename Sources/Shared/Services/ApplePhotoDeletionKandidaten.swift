import Foundation

/// Welche Fotos ein Lauf überhaupt anfasst.
///
/// Eigene, reine Regel, weil hier der teuerste Unterschied des ganzen Vorhabens
/// entschieden wird: die ganze Bibliothek (über 60 Stunden) oder eine Handvoll
/// Befunde (Minuten). Ein Fehler in dieser Zeile fällt nicht durch einen falschen
/// Bericht auf, sondern durch einen Lauf, der zwei Tage dauert.
enum ApplePhotoDeletionKandidaten {

    /// - Parameters:
    ///   - mappingLocalIds: Alle `localIdentifier` mit einem Mapping (ohne die
    ///     synthetischen `/live-video`-Einträge).
    ///   - erlaubteLocalIds: `nil` heißt „keine Einschränkung". Eine **leere** Menge
    ///     heißt „nichts" — nicht „alles": Sie entsteht, wenn zu einem Grund kein
    ///     Befund im Journal steht, und dürfte niemals in einen Volllauf umschlagen.
    /// - Returns: Aufsteigend sortiert, damit zwei Läufe über denselben Bestand
    ///   dieselbe Reihenfolge haben.
    static func auswählen(
        mappingLocalIds: [String],
        erlaubteLocalIds: Set<String>?
    ) -> [String] {
        guard let erlaubteLocalIds else { return mappingLocalIds.sorted() }
        return mappingLocalIds.filter { erlaubteLocalIds.contains($0) }.sorted()
    }
}
