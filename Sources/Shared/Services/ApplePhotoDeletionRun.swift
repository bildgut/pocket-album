import Foundation

/// Ergebnis eines Löschlaufs — Zahlen plus die Gründe, warum der Rest stehen blieb.
struct ApplePhotoDeletionOutcome: Equatable {
    let gelöscht: Int
    let gründe: [ApplePhotoDeletionVerdict: Int]
    let abgebrochenWegenServerfehlern: Bool
    let istProbelauf: Bool

    /// Fotos, deren Serverkopie nachweislich abweicht. Kein Rauschen, sondern ein
    /// Fund — im Bericht deshalb getrennt von den übersprungenen auszuweisen.
    var funde: Int { gründe[.checksumMismatch] ?? 0 }
}

/// Steuert einen Löschlauf: sammelt freigegebene Kandidaten in einem Puffer und
/// löscht erst schubweise.
///
/// Der Puffer ist der Grund, warum ein Abbruch nichts kostet: Er wird bei Erreichen
/// der Schwelle, am Ende **und beim Abbruch** geleert, sodass höchstens das eine
/// gerade laufende Foto an Prüfarbeit verlorengeht. Ohne ihn verwürfe ein Abbruch
/// den gesamten angefangenen Batch — bei aktiver Byte-Prüfung also bis zu 500
/// heruntergeladene und gehashte Originale.
@MainActor
final class ApplePhotoDeletionRun {

    /// Wie viele Fotos ein Schub umfasst. Apples Löschdialog erscheint einmal pro
    /// Schub: kleiner heißt mehr Dialoge, größer heißt später sichtbarer Fortschritt.
    nonisolated static let standardFlushSchwelle = 500
    /// Ab wie vielen Serverfehlern **in Folge** der Lauf aufgibt.
    nonisolated static let standardMaxFehlerserie = 25
    /// Wie viele Befunde sich sammeln, bevor sie ins Journal geschrieben werden.
    /// Eigene Schwelle, weil der Journal-Puffer *jedes* Urteil enthält, der
    /// Lösch-Puffer nur die Freigaben.
    nonisolated static let standardJournalSchwelle = 500

    private(set) var gelöscht = 0
    private(set) var abgebrochenWegenServerfehlern = false
    let istProbelauf: Bool

    var vorgemerkt: Int { puffer.count }

    private var puffer: [String] = []
    private var gründe: [ApplePhotoDeletionVerdict: Int] = [:]
    private var fehlerserie = 0
    private let flushSchwelle: Int
    private let maxFehlerserie: Int
    private let flush: ([String]) async -> Int
    private var journalPuffer: [ApplePhotoDeletionBefund] = []
    private let journalSchwelle: Int
    private let journal: ([ApplePhotoDeletionBefund]) -> Void

    /// - Parameters:
    ///   - flush: Löscht die übergebenen `localIdentifier` tatsächlich und liefert
    ///     die Anzahl der entfernten Assets. Im Probelauf nie aufgerufen.
    ///   - journal: Nimmt einen Schub Befunde entgegen. Wird auch im Probelauf
    ///     aufgerufen — der Probelauf existiert gerade, um Befunde zu sammeln.
    init(
        istProbelauf: Bool,
        flushSchwelle: Int = ApplePhotoDeletionRun.standardFlushSchwelle,
        maxFehlerserie: Int = ApplePhotoDeletionRun.standardMaxFehlerserie,
        journalSchwelle: Int = ApplePhotoDeletionRun.standardJournalSchwelle,
        flush: @escaping ([String]) async -> Int,
        journal: @escaping ([ApplePhotoDeletionBefund]) -> Void = { _ in }
    ) {
        self.istProbelauf = istProbelauf
        self.flushSchwelle = flushSchwelle
        self.maxFehlerserie = maxFehlerserie
        self.journalSchwelle = journalSchwelle
        self.flush = flush
        self.journal = journal
    }

    /// Nimmt das Urteil zu einem Kandidaten entgegen.
    /// - Parameters:
    ///   - immichAssetId: Für den Journal-Eintrag. Bewusst ohne Vorgabe: Ein
    ///     Journal-Eintrag ohne Serverbezug ist für jede Folgeaktion wertlos, und
    ///     eine Vorgabe ließe die nächste Aufrufstelle einen solchen still erzeugen.
    ///   - dateiname: Nur zur Anzeige im Bericht.
    /// - Returns: `false`, wenn der Lauf wegen einer Serverfehlerserie enden soll.
    @discardableResult
    func aufnehmen(
        localIdentifier: String,
        immichAssetId: String,
        dateiname: String? = nil,
        verdict: ApplePhotoDeletionVerdict
    ) async -> Bool {
        gründe[verdict, default: 0] += 1
        journalPuffer.append(ApplePhotoDeletionBefund(
            localIdentifier: localIdentifier,
            immichAssetId: immichAssetId,
            verdict: verdict,
            dateiname: dateiname
        ))
        if journalPuffer.count >= journalSchwelle { journalLeeren() }

        if verdict == .serverAntwortetNicht {
            fehlerserie += 1
            if fehlerserie >= maxFehlerserie {
                abgebrochenWegenServerfehlern = true
                AppLogger.upload.error("AppleDelete: Lauf beendet — \(self.maxFehlerserie) Serverfehler in Folge")
                return false
            }
            return true
        }

        // Jede inhaltliche Antwort — auch eine Ablehnung — beweist, dass der Server
        // erreichbar ist.
        fehlerserie = 0

        if verdict.istFreigabe {
            puffer.append(localIdentifier)
            if puffer.count >= flushSchwelle {
                await pufferLeeren()
            }
        }
        return true
    }

    /// Beendet den Lauf und leert den Puffer ein letztes Mal. Auch der Abbruchpfad
    /// ruft das auf — mehrfaches Aufrufen ist unschädlich, weil ein leerer Puffer
    /// keinen Flush auslöst.
    func abschließen() async -> ApplePhotoDeletionOutcome {
        journalLeeren()
        await pufferLeeren()
        return ApplePhotoDeletionOutcome(
            gelöscht: gelöscht,
            gründe: gründe,
            abgebrochenWegenServerfehlern: abgebrochenWegenServerfehlern,
            istProbelauf: istProbelauf
        )
    }

    private func journalLeeren() {
        guard !journalPuffer.isEmpty else { return }
        let schub = journalPuffer
        journalPuffer.removeAll()
        journal(schub)
    }

    private func pufferLeeren() async {
        guard !puffer.isEmpty else { return }
        let schub = puffer
        puffer.removeAll()
        guard !istProbelauf else {
            AppLogger.upload.info("AppleDelete: Probelauf — \(schub.count) Foto(s) wären gelöscht worden")
            return
        }
        gelöscht += await flush(schub)
    }
}
