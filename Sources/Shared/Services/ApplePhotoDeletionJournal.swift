import Foundation
import SwiftData

/// Ein einzelnes Prüfergebnis auf dem Weg vom Lauf ins Journal — als Wert, damit
/// `ApplePhotoDeletionRun` nichts von SwiftData wissen muss.
struct ApplePhotoDeletionBefund: Equatable, Sendable {
    let localIdentifier: String
    let immichAssetId: String
    let verdict: ApplePhotoDeletionVerdict
    let dateiname: String?
}

/// Zugriff auf das Befundjournal: schreibt die Ergebnisse eines Laufs und
/// beantwortet die eine Frage, für die es existiert — welche Fotos stehen aus
/// welchem Grund noch offen.
@MainActor
struct ApplePhotoDeletionJournal {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Schreibt einen Schub als Upsert: ein Eintrag je Foto, der jüngere gewinnt.
    ///
    /// Bewusst ein einziges `save()` je Schub. Ein `save()` pro Foto wären bei einem
    /// vollen Lauf über 80 000 Transaktionen — die Prüfung ist ohnehin schon von
    /// iCloud-Downloads dominiert, ein zweiter Flaschenhals muss nicht dazukommen.
    func schreiben(_ befunde: [ApplePhotoDeletionBefund], geprüftAm: Date = Date()) {
        guard !befunde.isEmpty else { return }
        let ids = befunde.map(\.localIdentifier)
        let vorhanden = (try? modelContext.fetch(FetchDescriptor<ApplePhotoDeletionFinding>(
            predicate: #Predicate { ids.contains($0.localIdentifier) }
        ))) ?? []
        var byLocalId: [String: ApplePhotoDeletionFinding] = [:]
        for eintrag in vorhanden { byLocalId[eintrag.localIdentifier] = eintrag }

        for befund in befunde {
            if let eintrag = byLocalId[befund.localIdentifier] {
                eintrag.immichAssetId = befund.immichAssetId
                eintrag.verdictRaw = befund.verdict.journalSchlüssel
                eintrag.dateiname = befund.dateiname
                eintrag.checkedAt = geprüftAm
            } else {
                let neu = ApplePhotoDeletionFinding(
                    localIdentifier: befund.localIdentifier,
                    immichAssetId: befund.immichAssetId,
                    verdictRaw: befund.verdict.journalSchlüssel,
                    dateiname: befund.dateiname,
                    checkedAt: geprüftAm
                )
                modelContext.insert(neu)
                byLocalId[befund.localIdentifier] = neu
            }
        }

        do {
            try modelContext.save()
        } catch {
            // Kein Abbruch des Laufs: Das Journal ist eine Erleichterung für den
            // nächsten Lauf, nicht die Grundlage dieses einen. Stumm bleiben darf
            // es trotzdem nicht — sonst wirkt ein leeres Journal wie ein leerer Lauf.
            modelContext.rollback()
            AppLogger.upload.error("AppleDelete: Journal-Schub nicht gespeichert — \(error.localizedDescription)")
        }
    }

    /// Die Fotos, deren letzter Befund einer der genannten Gründe ist.
    ///
    /// Das Prädikat gehört in den Store und nicht in einen Swift-`filter`: Ein
    /// Volllauf hinterlässt einen Befund je Mapping — rund 81 000 Einträge, davon
    /// allein 44 557 Karteileichen. Die vor jedem Nachlauf auf dem MainActor zu
    /// materialisieren, um am Ende ein paar hundert `localIdentifier` zu behalten,
    /// war der teuerste Teil des billigen Laufs.
    func localIds(mitGründen gründe: Set<ApplePhotoDeletionVerdict>) -> Set<String> {
        guard !gründe.isEmpty else { return [] }
        // Bewusst ein `Array`: `Set.contains` übersetzt SwiftData nicht in SQL.
        let schlüssel = gründe.map(\.journalSchlüssel)
        var deskriptor = FetchDescriptor<ApplePhotoDeletionFinding>(
            predicate: #Predicate { schlüssel.contains($0.verdictRaw) }
        )
        deskriptor.propertiesToFetch = [\.localIdentifier]
        let treffer = (try? modelContext.fetch(deskriptor)) ?? []
        return Set(treffer.map(\.localIdentifier))
    }

    /// Wie viele Fotos je Grund im Journal stehen. Einträge mit einem Schlüssel, den
    /// diese Fassung nicht kennt, fallen heraus — sie zu zählen hieße, sie unter
    /// einem falschen Titel zu zeigen.
    ///
    /// Eine `fetchCount`-Abfrage je bekanntem Schlüssel, statt einer Materialisierung
    /// des ganzen Journals: Diese Zählung läuft bei jedem Öffnen der Einstellungen
    /// und nach jedem Lauf, und zwar auf dem MainActor. Zweiundzwanzig Zählabfragen
    /// sind dort billiger als zehntausende `@Model`-Objekte. Dass unbekannte
    /// Schlüssel herausfallen, ergibt sich jetzt daraus, dass nach ihnen gar nicht
    /// erst gefragt wird.
    func anzahlProGrund() -> [ApplePhotoDeletionVerdict: Int] {
        var zählung: [ApplePhotoDeletionVerdict: Int] = [:]
        for verdict in ApplePhotoDeletionVerdict.allCases {
            let schlüssel = verdict.journalSchlüssel
            let deskriptor = FetchDescriptor<ApplePhotoDeletionFinding>(
                predicate: #Predicate { $0.verdictRaw == schlüssel }
            )
            // Grund ohne Eintrag bleibt abwesend statt 0 — der Bericht unterscheidet
            // beides, und die Wiederholen-Aktion hängt daran.
            guard let anzahl = try? modelContext.fetchCount(deskriptor), anzahl > 0 else { continue }
            zählung[verdict] = anzahl
        }
        return zählung
    }
}
