import Foundation

/// Schränkt einen Duplikat-Scan auf die Aufnahmen eines Albums ein.
///
/// Rein wie `DuplicateMatcher` — kein SQLite, kein Netz, keine Uhr —, damit die
/// beiden Bedeutungen von „nur die Fotos des Albums" ohne Datenbank prüfbar sind.
enum DupeScopeFilter {

    /// Der einzige Einstieg für das Modell.
    ///
    /// `scope == nil` ist wortgleich mit dem bisherigen Aufruf: Die
    /// bibliotheksweite Suche läuft unverändert durch `DuplicateMatcher`.
    static func scan(
        rows: [DupeScanRow],
        parameters: DupeParameters,
        ignoredPairs: Set<String>,
        scope: DupeAlbumScope?,
        reach: DupeReach
    ) -> DupeScanResult {
        guard let scope else {
            return DuplicateMatcher.scan(rows: rows, parameters: parameters,
                                         ignoredPairs: ignoredPairs)
        }

        switch reach {
        case .withinAlbum:
            // **Vor** dem Matcher filtern, nicht danach. Nur so rechnet er
            // Keeper, Konfidenz und `reclaimableBytes` von sich aus für die
            // kleinere Menge richtig. Eine Gruppe nachträglich zu beschneiden
            // hieße, dieselben Regeln außerhalb des Matchers ein zweites Mal
            // nachzubilden — und die Keeper-Wahl entscheidet hier über das
            // Löschen.
            return DuplicateMatcher.scan(rows: albumRows(rows, in: scope),
                                         parameters: parameters,
                                         ignoredPairs: ignoredPairs)

        case .albumAgainstLibrary:
            let voll = DuplicateMatcher.scan(rows: rows, parameters: parameters,
                                             ignoredPairs: ignoredPairs)
            return groupsTouching(voll, scope: scope)
        }
    }

    /// Die Zeilen, die im Album liegen.
    static func albumRows(_ rows: [DupeScanRow], in scope: DupeAlbumScope) -> [DupeScanRow] {
        rows.filter { scope.assetIds.contains($0.id) }
    }

    /// Behält die Gruppen, in denen mindestens eine Album-Aufnahme steckt.
    ///
    /// Die Zähler des Ergebnisses bleiben **stehen**: Sie beschreiben den Scan,
    /// nicht die Anzeige. Würde `scannedRows` mitgefiltert, meldete die
    /// Hinweiszeile eine Handvoll geprüfter Zeilen, obwohl der Scan über den
    /// ganzen Bestand lief.
    static func groupsTouching(_ result: DupeScanResult,
                               scope: DupeAlbumScope) -> DupeScanResult {
        func beruehrt(_ group: DupeGroup) -> Bool {
            group.assetIds.contains { scope.assetIds.contains($0) }
        }
        return DupeScanResult(
            exactGroups: result.exactGroups.filter(beruehrt),
            similarGroups: result.similarGroups.filter(beruehrt),
            suppressed: result.suppressed.filter { beruehrt($0.group) },
            scannedRows: result.scannedRows,
            candidatePairCount: result.candidatePairCount,
            skippedOversizedBuckets: result.skippedOversizedBuckets,
            rowsWithoutThumbhash: result.rowsWithoutThumbhash
        )
    }
}
