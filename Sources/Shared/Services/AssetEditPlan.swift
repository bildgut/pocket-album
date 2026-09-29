import Foundation

/// Rechnet die neue Bearbeitungsliste eines Assets aus der bestehenden aus.
///
/// **Warum das nötig ist.** `PUT /api/assets/{id}/edits` **ersetzt** die Liste, es hängt
/// nichts an. Am 06.09.2026 nachgemessen — zweimal „Drehen" hintereinander:
///
/// ```
/// VOR:  {"edits":[{"id":"8d482372…","action":"rotate","parameters":{"angle":90}}]}
/// NACH: {"edits":[{"id":"816f5aed…","action":"rotate","parameters":{"angle":90}}]}
/// ```
///
/// Neue Kennung, gleicher Winkel: Der zweite Klick hat denselben Zustand noch einmal
/// gesetzt. Genau deshalb ließ sich ein Foto nur ein einziges Mal drehen und stand danach
/// fest. Der Winkel muss also fortgeschrieben werden: 90 → 180 → 270 → 0.
///
/// Die Einträge bleiben absichtlich untypisierte Wörterbücher. Immich kennt neben
/// `rotate` weitere Aktionen (Belichtung, Kontrast, Sättigung, Beschnitt), und weil der
/// PUT die **ganze** Liste ersetzt, würde jede Bearbeitung verlorengehen, die dieser
/// Client nicht modelliert. Unbekanntes unverändert durchzureichen ist hier die
/// verlässlichere Wahl gegenüber einem vollständigen Modell, das beim nächsten
/// Server-Update wieder unvollständig ist.
enum AssetEditPlan {

    static let rotateAction = "rotate"

    /// Der aktuell gesetzte Drehwinkel in Grad (0, wenn keine Drehung hinterlegt ist).
    static func currentRotation(in edits: [[String: Any]]) -> Double {
        for edit in edits where edit["action"] as? String == rotateAction {
            if let parameters = edit["parameters"] as? [String: Any],
               let angle = parameters["angle"] as? Double ?? (parameters["angle"] as? NSNumber)?.doubleValue {
                return normalized(angle)
            }
        }
        return 0
    }

    /// Die Liste, die den bestehenden Zustand um `delta` Grad weiterdreht.
    ///
    /// - Alle Nicht-Dreh-Einträge bleiben unverändert erhalten.
    /// - Ergibt die Summe 0°, entfällt der Dreh-Eintrag ganz — das Foto ist dann wieder
    ///   in der Ausgangslage, und ohne Eintrag ist es für den Server auch wieder
    ///   unbearbeitet, statt eine Drehung um null Grad mitzuschleppen.
    /// - Die vom Server vergebenen `id`-Felder werden abgeworfen; er vergibt bei jedem
    ///   PUT neue (siehe die Messung oben).
    static func rotating(by delta: Double, in edits: [[String: Any]]) -> [[String: Any]] {
        let neuerWinkel = normalized(currentRotation(in: edits) + delta)

        var ergebnis: [[String: Any]] = []
        for edit in edits where edit["action"] as? String != rotateAction {
            var kopie = edit
            kopie.removeValue(forKey: "id")
            ergebnis.append(kopie)
        }
        if neuerWinkel != 0 {
            ergebnis.append(["action": rotateAction, "parameters": ["angle": neuerWinkel]])
        }
        return ergebnis
    }

    /// Die vom Server vergebenen Kennungen der bestehenden Bearbeitungen.
    ///
    /// Gebraucht für den Fall „zurück auf 0°": Eine **leere** Liste lehnt
    /// `PUT /edits` mit HTTP 400 ab (am 06.09.2026 gemessen, als die vierte Drehung
    /// scheiterte). Die letzte Bearbeitung muss also einzeln gelöscht werden, statt sie
    /// wegzulassen.
    static func editIds(in edits: [[String: Any]]) -> [String] {
        edits.compactMap { $0["id"] as? String }
    }

    /// Auf 0…<360 gebracht; `truncatingRemainder` allein liefert für negative Winkel
    /// negative Ergebnisse, und −90 wäre als Zustand nicht dasselbe wie 270.
    static func normalized(_ angle: Double) -> Double {
        let rest = angle.truncatingRemainder(dividingBy: 360)
        return rest < 0 ? rest + 360 : rest
    }
}
