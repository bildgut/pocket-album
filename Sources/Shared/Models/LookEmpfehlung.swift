import Foundation

/// Ein empfohlener Look samt Begründung — was ``GeminiLookService`` aus der
/// Modellantwort macht und das Looks-Raster als Abzeichen zeigt.
struct LookEmpfehlung: Equatable, Identifiable, Sendable {
    /// Katalog-ID aus ``FilmLookCatalog``; nie ein Wert außerhalb des Katalogs.
    let lookID: String
    /// Selbstbewertung des Modells, 0…10. Taugt als Rangfolge, nicht als
    /// Qualitätsaussage: In der Probe vom 16.09.2026 lagen alle Motive bei 8–9,
    /// auch ein Foto eines Bildschirms. Dafür gibt es ``LookEmpfehlungsErgebnis/lohnt``.
    let eignung: Double
    let begruendung: String

    var id: String { lookID }
}

/// Das ganze Ergebnis einer Anfrage: entweder bis zu drei Empfehlungen, oder die
/// ausdrückliche Auskunft, dass für dieses Foto kein Look lohnt.
///
/// Die Trennung ist der Kern des Befunds aus der Probe: Das Modell empfiehlt auf
/// Zuruf immer drei Looks — auch für Belege, Screenshots und Dokumentenfotos. Erst
/// die eigene Frage „lohnt das hier überhaupt?" liefert eine ehrliche Antwort.
struct LookEmpfehlungsErgebnis: Equatable, Sendable {
    /// `false` heißt: keine Abzeichen, stattdessen ``begruendungOhneLook`` zeigen.
    /// Immer `false`, wenn nach Schwelle und Prüfung keine Empfehlung übrig ist.
    var lohnt: Bool
    /// Ein Satz des Modells, warum kein Look passt. Darf leer sein — die Oberfläche
    /// hat dann ihren eigenen Text.
    var begruendungOhneLook: String
    /// Höchstens drei, nach Eignung absteigend, ohne Duplikate.
    var empfehlungen: [LookEmpfehlung]

    static let keine = LookEmpfehlungsErgebnis(lohnt: false, begruendungOhneLook: "", empfehlungen: [])

    /// Rang 1…3 eines Looks, `nil` wenn nicht empfohlen — das Abzeichen im Raster.
    func rang(fuer lookID: String) -> Int? {
        guard let index = empfehlungen.firstIndex(where: { $0.lookID == lookID }) else { return nil }
        return index + 1
    }

    func empfehlung(fuer lookID: String) -> LookEmpfehlung? {
        empfehlungen.first { $0.lookID == lookID }
    }
}
