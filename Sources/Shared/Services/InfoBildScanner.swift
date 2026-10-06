import Foundation
import CoreGraphics

/// Arbeitet die Kandidatenliste ab: Vorfilter, Stufe A, bei Dokumenten Stufe B.
///
/// Ein Bild nach dem anderen — das Modell arbeitet ohnehin seriell, und ein
/// Erstlauf über die ganze Mediathek darf den Mac nicht blockieren. Jeder Befund
/// wird sofort gespeichert: Ein Abbruch nach acht Stunden darf nichts kosten.
@Observable
@MainActor
final class InfoBildScanner {

    /// Die Zahlen der Anzeige — **alle allzeit**, nicht lauf-lokal.
    ///
    /// Vorher mischte die Leiste lauf-lokale Zahlen (`geprueft`/`gesamt` = nur
    /// die noch offene Liste) mit einer Allzeit-Zahl (`abgelehnt`). Nach
    /// „Fortsetzen" sprang die Anzeige damit auf „0 von <Rest>" statt auf
    /// „38 412 von 117 305 geprüft". Seit ``lauf(ids:bestand:bereitsAbgelehnt:)``
    /// den Bestand und die schon abgelehnten Bilder mitbekommt, zählen alle vier
    /// Felder dieselbe Menge.
    struct Fortschritt: Equatable {
        /// Wie viele Bilder des Bestands einen Befund haben — die vor diesem
        /// Lauf erledigten eingerechnet.
        var geprueft = 0
        /// Der ganze Bestand, nicht nur die offene Liste.
        var gesamt = 0
        /// Wie viele davon in einer Rubrik gelandet sind (nur dieser Lauf).
        var gefunden = 0
        /// Wie viele der Sicherheitsfilter abgelehnt hat — allzeit.
        var abgelehnt = 0
        var laeuft = false
    }

    private(set) var fortschritt = Fortschritt()

    /// Vom Nutzer angehalten. Bleibt gesetzt, bis ``fortsetze()`` aufgerufen wird —
    /// ``lauf(ids:bestand:bereitsAbgelehnt:)`` darf die Pause nicht einfach
    /// überschreiben, sonst hebt jeder Auslöser von außen (Sync, Timer) eine
    /// Nutzerentscheidung wieder auf.
    private(set) var istPausiert = false

    /// Wie viele Bilder in Folge ohne Befund bleiben dürfen, bevor der Lauf sich
    /// selbst anhält. Netz gegen den Fall, dass etwas grundsätzlich kaputt ist —
    /// Apple Intelligence mitten im Lauf abgeschaltet, Server weg, Schlüssel
    /// ungültig. Ohne dieses Netz arbeitete der Erstlauf die ganze Mediathek ab,
    /// lud für die Vorfilter-Treffer die Vorschauen (~4 GB) und speicherte nichts.
    static let maxFehlschlaegeInFolge = 20

    /// Zählt die Läufe. Ein Lauf, der nicht mehr der aktuelle ist, darf den
    /// Fortschritt nicht mehr anfassen: Nach „Pausieren" hängt der alte Lauf
    /// noch 1–2 s in einer nicht abbrechbaren Modellantwort; „Fortsetzen" in
    /// diesem Fenster startet bereits den nächsten. Ohne den Zähler setzte der
    /// alte danach `laeuft = false` (Leiste weg, obwohl der neue läuft) und
    /// zählte weiter in dessen Zahlen hoch.
    private var laufGeneration = 0

    private var fehlschlaegeInFolge = 0

    private let einordner: any InfoBildEinordner
    private let bildQuelle: any InfoBildBildQuelle
    private let store: InfoBildStore

    init(einordner: any InfoBildEinordner, bildQuelle: any InfoBildBildQuelle, store: InfoBildStore) {
        self.einordner = einordner
        self.bildQuelle = bildQuelle
        self.store = store
    }

    func pausiere() {
        istPausiert = true
        fortschritt.laeuft = false
    }

    func fortsetze() {
        istPausiert = false
    }

    /// - Parameters:
    ///   - ids: die noch offenen Bilder.
    ///   - bestand: wie viele Bilder es insgesamt gibt. `0` heißt „nur die
    ///     offene Liste zählen" — bequem für Tests.
    ///   - bereitsAbgelehnt: wie viele der Sicherheitsfilter bisher abgelehnt hat.
    func lauf(ids: [String], bestand: Int = 0, bereitsAbgelehnt: Int = 0) async {
        guard !istPausiert else { return }

        laufGeneration += 1
        let meine = laufGeneration
        fehlschlaegeInFolge = 0

        fortschritt.laeuft = true
        fortschritt.gesamt = max(bestand, ids.count)
        fortschritt.geprueft = max(0, fortschritt.gesamt - ids.count)
        fortschritt.gefunden = 0
        fortschritt.abgelehnt = bereitsAbgelehnt

        for id in ids {
            if istPausiert || Task.isCancelled || laufGeneration != meine { break }
            await pruefe(id)
            // Nach dem `await` kann inzwischen ein neuer Lauf gestartet sein.
            guard laufGeneration == meine else { return }
            fortschritt.geprueft += 1
        }

        if laufGeneration == meine { fortschritt.laeuft = false }
    }

    private func pruefe(_ id: String) async {
        do {
            let thumbnail = try await bildQuelle.thumbnail(assetId: id)
            guard await einordner.vorfilterBesteht(thumbnail) else {
                speichere(id, InfoBildBefund.ergebnisOhne, nil)
                return
            }
            let vorschau = try await bildQuelle.vorschau(assetId: id)
            let art = try await einordner.art(vorschau)
            guard art == .dokument else {
                speichere(id, art.rawValue, nil)
                if art == .screenshot { fortschritt.gefunden += 1 }
                return
            }
            // Scheitert Stufe B, bleibt es ein Dokument ohne Unterart und landet
            // in „Alle Dokumente" — besser als gar nicht.
            let unterart = try? await einordner.unterart(vorschau)
            speichere(id, art.rawValue, unterart?.rawValue)
            fortschritt.gefunden += 1
        } catch let fehler as InfoBildFehler {
            switch fehler {
            case .abgelehnt:
                speichere(id, InfoBildBefund.ergebnisAbgelehnt, nil)
                fortschritt.abgelehnt += 1
            case .modellNichtVerfuegbar(let grund):
                AppLogger.ui.warning("InfoBild: Lauf hält an — \(grund)")
                pausiere()
            case .sonstiges(let grund):
                // Kein Befund: Der nächste Lauf fragt erneut.
                AppLogger.ui.debug("InfoBild: \(id) übersprungen — \(grund)")
                zaehleFehlschlag(grund)
            }
        } catch {
            AppLogger.ui.debug("InfoBild: Bild \(id) nicht ladbar — \(error.localizedDescription)")
            zaehleFehlschlag(error.localizedDescription)
        }
    }

    /// Ein Bild ohne Befund. Reißen es zu viele in Folge, ist nicht das Bild das
    /// Problem, sondern das Modell oder der Server — dann hält der Lauf an,
    /// statt stundenlang ins Leere zu laufen.
    private func zaehleFehlschlag(_ grund: String) {
        fehlschlaegeInFolge += 1
        guard fehlschlaegeInFolge >= Self.maxFehlschlaegeInFolge else { return }
        AppLogger.ui.warning(
            "InfoBild: \(Self.maxFehlschlaegeInFolge) Fehlschläge in Folge — Lauf hält an. Zuletzt: \(grund)")
        pausiere()
    }

    private func speichere(_ id: String, _ ergebnis: String, _ unterart: String?) {
        fehlschlaegeInFolge = 0
        store.speichere(assetId: id, ergebnis: ergebnis, unterart: unterart,
                        promptVersion: InfoBildPrompt.promptVersion,
                        filterVersion: InfoBildPrompt.filterVersion)
    }
}
