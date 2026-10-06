import Foundation
import SwiftData

/// Lesen und Schreiben der Befunde. Dünn gehalten: Alles, was sich ohne
/// Datenbank entscheiden lässt, steht in ``InfoBildOffen`` bzw. ``InfoBildRubrik``.
@MainActor
final class InfoBildStore {

    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func speichere(assetId: String, ergebnis: String, unterart: String?, promptVersion: Int, filterVersion: Int) {
        let vorhanden = befund(assetId: assetId)
        if let vorhanden {
            vorhanden.result = ergebnis
            vorhanden.subtype = unterart
            vorhanden.promptVersion = promptVersion
            vorhanden.filterVersion = filterVersion
            vorhanden.checkedAt = Date()
        } else {
            modelContext.insert(InfoBildBefund(
                assetId: assetId, result: ergebnis, subtype: unterart,
                promptVersion: promptVersion, filterVersion: filterVersion
            ))
        }
        do {
            try modelContext.save()
        } catch {
            modelContext.rollback()
            AppLogger.ui.error("InfoBild: Befund für \(assetId) nicht gespeichert: \(error.localizedDescription)")
        }
    }

    func befund(assetId: String) -> InfoBildBefund? {
        var descriptor = FetchDescriptor<InfoBildBefund>(
            predicate: #Predicate { $0.assetId == assetId }
        )
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first
    }

    func alleBefunde() -> [InfoBildBefund] {
        (try? modelContext.fetch(FetchDescriptor<InfoBildBefund>())) ?? []
    }

    /// Der Stand je Asset für ``InfoBildOffen/ids(alle:befunde:promptVersion:filterVersion:)``.
    func staende() -> [InfoBildOffen.Stand] {
        alleBefunde().map {
            .init(assetId: $0.assetId, result: $0.result,
                  promptVersion: $0.promptVersion, filterVersion: $0.filterVersion)
        }
    }

    /// Die Befunde einer Rubrik, jüngstes Foto zuerst wäre Sache des Rasters —
    /// hier bleibt die Reihenfolge die der Datenbank.
    ///
    /// Mit Prädikat, nicht als Filter über die ganze Tabelle: Die wächst im
    /// Erstlauf auf 117 000 Zeilen, und jede davon als Objekt zu materialisieren
    /// kostet auf dem MainActor spürbar Zeit.
    func befunde(rubrik: InfoBildRubrik) -> [InfoBildBefund] {
        (try? modelContext.fetch(FetchDescriptor(predicate: Self.praedikat(rubrik)))) ?? []
    }

    func anzahl(rubrik: InfoBildRubrik) -> Int {
        (try? modelContext.fetchCount(FetchDescriptor(predicate: Self.praedikat(rubrik)))) ?? 0
    }

    /// Wie viele Bilder der Sicherheitsfilter abgelehnt hat. Die Zahl steht in
    /// „Alle Dokumente", damit nicht der Eindruck entsteht, alles sei geprüft.
    ///
    /// `fetchCount` mit Prädikat: Die Zahl wird beim Start eines Laufs erfragt
    /// und danach im ``InfoBildScanner/Fortschritt`` mitgeführt — die Ansicht
    /// darf sie **nicht** je `body` erfragen, die Leiste tickt bis zu zehnmal
    /// je Sekunde.
    func anzahlNichtGeprueft() -> Int {
        let abgelehnt = InfoBildBefund.ergebnisAbgelehnt
        let descriptor = FetchDescriptor<InfoBildBefund>(predicate: #Predicate { $0.result == abgelehnt })
        return (try? modelContext.fetchCount(descriptor)) ?? 0
    }

    /// Dieselbe Zuordnung wie ``InfoBildRubrik/fuer(ergebnis:unterart:)``, nur
    /// als Prädikat. Beide Wege müssen übereinstimmen — festgehalten in
    /// ``InfoBildStoreTests``.
    private static func praedikat(_ rubrik: InfoBildRubrik) -> Predicate<InfoBildBefund> {
        let (ergebnis, unterart) = rubrik.abfrage
        if let unterart {
            return #Predicate { $0.result == ergebnis && $0.subtype == unterart }
        }
        return #Predicate { $0.result == ergebnis }
    }
}

/// Welche Assets noch zu prüfen sind — rein, damit es ohne Datenbank testbar ist.
enum InfoBildOffen {

    /// Der Datenbank-Stand je Asset, auf das Nötige eingedampft.
    struct Stand: Sendable, Equatable {
        let assetId: String
        let result: String
        let promptVersion: Int
        let filterVersion: Int
    }

    /// Offen ist, was gar keinen Befund hat oder dessen Befund von einer älteren
    /// Version stammt. Eine Ablehnung des Sicherheitsfilters zählt als erledigt:
    /// Ein erneuter Lauf mit demselben Prompt würde wieder abgelehnt.
    static func ids(alle: [String], befunde: [Stand], promptVersion: Int, filterVersion: Int) -> [String] {
        let stand = Dictionary(befunde.map { ($0.assetId, $0) }, uniquingKeysWith: { _, neu in neu })
        return alle.filter { id in
            guard let s = stand[id] else { return true }
            if s.result == InfoBildBefund.ergebnisOhne { return s.filterVersion < filterVersion }
            return s.promptVersion < promptVersion || s.filterVersion < filterVersion
        }
    }
}
