import Foundation
import Photos
import SwiftData

/// Observable progress state for a full catch-up sweep (`deleteAllPreviouslySyncedAssets`).
///
/// Der reguläre Pfad pro Sync (`considerDeletion`) prüft dieselben Stufen — inklusive
/// SHA-1 über das vollständige Original, notfalls frisch aus iCloud geladen — meldet
/// aber keinen Fortschritt: Er läuft ohne eigene Oberfläche im Anschluss an einen Sync
/// und betrifft nur die in *diesem* Lauf neu verknüpften Fotos. Billig ist er deshalb
/// nicht; Aufrufer dürfen ihn nicht als kurzen Nachlauf behandeln.
@Observable
@MainActor
final class ApplePhotoDeletionProgress {
    var isRunning = false
    var total = 0
    var checked = 0
    var deletedCount = 0
    var isCancelled = false

    /// Der Vorlauf ermittelt gerade, hinter wie vielen Mappings überhaupt noch ein
    /// Foto steht. Solange das läuft, ist `total` unbekannt — die Oberfläche zeigt
    /// deshalb einen unbestimmten Balken statt „0 / 0".
    var bereitetVor = false

    /// Geprüft und freigegeben, aber noch nicht gelöscht — der Puffer.
    var vorgemerkt = 0
    var aktuellerDateiname: String?
    /// Ohne diese beiden sieht ein Lauf, der an einem mehrere Gigabyte großen Video
    /// aus iCloud hängt, aus wie ein Absturz.
    var lädtAusICloud = false
    var iCloudFortschritt: Double = 0

    var progressFraction: Double {
        guard total > 0 else { return 0 }
        return Double(checked) / Double(total)
    }
}

/// Alles, was die Prüfung eines Kandidaten von seinem `PHAsset` braucht — auf einer
/// Hintergrund-Queue eingesammelt, **bevor** der Main Actor damit arbeitet.
///
/// Der Grund ist kein Stilpunkt: `sourceType`, `modificationDate` und
/// `mediaSubtypes` sind faule Photos-Properties. Greift der Main Thread darauf zu,
/// holt Photos die Werte per IPC nach („Missing prefetched properties …
/// Fetching on demand on the main queue") — bei einem Lauf über zehntausende Fotos
/// steht damit die gesamte Oberfläche. `PHAssetResource.assetResources` ist derselbe
/// IPC-Weg, nur teurer.
///
/// `PHAssetResource` ist ein unveränderliches Photos-Modellobjekt und laut
/// Dokumentation threadsicher — daher `@unchecked Sendable`.
private struct ApplePhotoPrüfKandidat: @unchecked Sendable {
    let localIdentifier: String
    let sourceType: PHAssetSourceType
    /// `nil` heißt „nicht feststellbar" und sperrt das Löschen — siehe
    /// `ApplePhotoLibraryScope`. Wird hier mit eingesammelt, weil auch dieser
    /// Zugriff sonst als IPC auf dem Main Thread landete.
    let gehörtZurGemeinsamenMediathek: Bool?
    /// Reine Diagnose (`ApplePhotoLibraryScope.bereich`), entscheidet nichts.
    let mediathekBereich: Int?
    let modificationDate: Date?
    let isLivePhoto: Bool
    /// Name der Ressource, die gehasht würde — bei bearbeiteten Fotos ist das
    /// nicht die erste in der Liste.
    let dateiname: String?
    let hauptResource: PHAssetResource?
    let videoResource: PHAssetResource?
}

/// Löscht Apple-Photos-Assets, die bereits erfolgreich mit Immich verknüpft wurden —
/// nur wenn der Nutzer das in den Einstellungen explizit aktiviert hat (automatischer
/// Pfad) bzw. den Nachhol-Abgleich-Button explizit auslöst (manueller Pfad).
///
/// `PHAssetChangeRequest.deleteAssets` verschiebt die Fotos in Apples eigenen
/// "Kürzlich gelöscht"-Ordner (30 Tage wiederherstellbar), kein Hard-Delete.
///
/// Die Klasse bleibt `@MainActor` (Fortschritt, SwiftData) — aber alle Zugriffe auf
/// `PHAsset`-Metadaten und -Ressourcen laufen über `prüfKandidaten(für:)` auf einer
/// Hintergrund-Queue. Siehe `ApplePhotoPrüfKandidat`.
@MainActor
final class ApplePhotoDeletionService {
    static let settingsKey = "applePhotosDeleteAfterSync"

    /// In Scheiben, damit `PHAsset.fetchAssets` nicht einmal für zehntausende
    /// Identifier auf einmal läuft. Die Löschung folgt nicht dieser Einteilung —
    /// dafür ist der Puffer in `ApplePhotoDeletionRun` zuständig.
    private static let sweepFetchScheibengröße = 500

    let progress = ApplePhotoDeletionProgress()

    private let modelContext: ModelContext
    private let apiClient: ImmichAPIClient
    /// Eine Instanz pro Service: Die Prüfung läuft bewusst seriell, und nur so
    /// erreicht `abbrechen()` genau den Lauf, der gerade hängt.
    private let hasher = ApplePhotoResourceHasher()
    private lazy var journal = ApplePhotoDeletionJournal(modelContext: modelContext)

    init(modelContext: ModelContext, apiClient: ImmichAPIClient) {
        self.modelContext = modelContext
        self.apiClient = apiClient
    }

    /// - Parameters:
    ///   - newlyMappedLocalIdentifiers: Apple-Photos-`localIdentifier`s, die in
    ///     *diesem* Sync-Lauf neu mit einem Immich-Asset verknüpft wurden (nicht der
    ///     gesamte Mapping-Bestand). Nur bei eingeschaltetem `applePhotosDeleteAfterSync`.
    ///   - verwerfen: In der Vorschau abgewählte Fotos, die der Nutzer ausdrücklich
    ///     mitlöschen will. Unabhängig von `applePhotosDeleteAfterSync`.
    /// - Returns: `nil`, wenn gar kein Löschlauf stattfand.
    @discardableResult
    func considerDeletion(
        newlyMappedLocalIdentifiers: Set<String>,
        verwerfen: [ApplePhotoVerwerfKandidat] = []
    ) async -> ApplePhotoDeletionOutcome? {
        // Jeder Ausstiegspfad wird geloggt: Ohne das ist "es wurde nichts gelöscht"
        // von "es wurde gar nicht erst versucht" nicht zu unterscheiden — genau diese
        // Unterscheidung hat eine Fehlersuche schon einmal blockiert.
        let enabled = AppEnvironment.defaults.bool(forKey: Self.settingsKey)
        AppLogger.upload.info("AppleDelete: considerDeletion aufgerufen — \(newlyMappedLocalIdentifiers.count) neu gemappt, \(verwerfen.count) verworfen, Einstellung=\(enabled)")

        let mappingPfad: Bool
        if !enabled {
            AppLogger.upload.info("AppleDelete: Mapping-Pfad übersprungen — Einstellung ist aus")
            mappingPfad = false
        } else if newlyMappedLocalIdentifiers.isEmpty {
            AppLogger.upload.info("AppleDelete: Mapping-Pfad übersprungen — keine neu gemappten Assets")
            mappingPfad = false
        } else {
            mappingPfad = true
        }
        guard mappingPfad || !verwerfen.isEmpty else {
            AppLogger.upload.info("AppleDelete: übersprungen — nichts zu prüfen")
            return nil
        }
        guard ApplePhotoLibraryScope.istVerfügbar else {
            AppLogger.upload.error("AppleDelete: abgebrochen — Zugehörigkeit zur gemeinsamen Mediathek nicht feststellbar")
            return nil
        }

        // Ein Lauf für beide Pfade: gemeinsamer Puffer, also ein performChanges und
        // höchstens eine Rückfrage von macOS.
        let run = ApplePhotoDeletionRun(
            istProbelauf: false,
            flush: { [weak self] ids in
                guard let self else { return 0 }
                return await self.deleteFromApplePhotos(localIdentifiers: ids)
            },
            journal: { [weak self] befunde in
                self?.journal.schreiben(befunde)
            }
        )

        if mappingPfad {
            await mappingPfadAufnehmen(newlyMappedLocalIdentifiers, in: run)
        }
        if !verwerfen.isEmpty {
            await verworfeneAufnehmen(verwerfen, in: run)
        }

        let outcome = await run.abschließen()
        AppLogger.upload.info("AppleDelete: automatischer Pfad — \(outcome.gelöscht) gelöscht, \(outcome.gründe.count) Grund/Gründe für den Rest")
        return outcome
    }

    /// Die bisherige Prüfung frisch gemappter Fotos — byte-genau gegen den Server.
    private func mappingPfadAufnehmen(
        _ newlyMappedLocalIdentifiers: Set<String>,
        in run: ApplePhotoDeletionRun
    ) async {
        let mappingByLocalId = alleMappings()
        let kandidaten = newlyMappedLocalIdentifiers
            .filter { !$0.hasSuffix("/live-video") }
            .compactMap { mappingByLocalId[$0] }
        AppLogger.upload.info("AppleDelete: \(kandidaten.count)/\(newlyMappedLocalIdentifiers.count) Kandidat(en) haben ein Mapping")

        // L1 zuerst — spart bei bereits entfernten Fotos jeden Netzwerkzugriff.
        let datenByLocalId = await Self.prüfKandidaten(für: kandidaten.map(\.localIdentifier))

        for mapping in kandidaten {
            guard let daten = datenByLocalId[mapping.localIdentifier] else {
                AppLogger.upload.info("AppleDelete: \(mapping.localIdentifier) übersprungen — kein Foto mehr in der Bibliothek")
                await run.aufnehmen(
                    localIdentifier: mapping.localIdentifier,
                    immichAssetId: mapping.immichAssetId,
                    verdict: .nichtMehrInApplePhotos
                )
                continue
            }
            let videoMapping = mappingByLocalId[mapping.localIdentifier + "/live-video"]
            let urteil = await verdict(
                for: daten,
                immichAssetId: mapping.immichAssetId,
                mappingModificationDate: mapping.lastKnownModificationDate,
                mappingUploadFileSize: mapping.lastUploadedFileSize,
                liveVideoAssetId: videoMapping?.immichAssetId,
                liveVideoUploadFileSize: videoMapping?.lastUploadedFileSize
            )
            if !urteil.istFreigabe {
                AppLogger.upload.info("AppleDelete: \(mapping.localIdentifier) übersprungen — \(urteil.berichtstitel)")
            }
            let weiter = await run.aufnehmen(
                localIdentifier: mapping.localIdentifier,
                immichAssetId: mapping.immichAssetId,
                dateiname: daten.dateiname,
                verdict: urteil
            )
            if !weiter { break }
        }
    }

    /// Abgewählte Fotos: keine Serverkopie, Urteil allein über `ApplePhotoVerwerfUrteil`.
    private func verworfeneAufnehmen(
        _ verwerfen: [ApplePhotoVerwerfKandidat],
        in run: ApplePhotoDeletionRun
    ) async {
        let datenByLocalId = await Self.prüfKandidaten(für: verwerfen.map(\.localIdentifier))
        for kandidat in verwerfen {
            let daten = datenByLocalId[kandidat.localIdentifier]
            let urteil = ApplePhotoVerwerfUrteil.urteil(
                existiert: daten != nil,
                gemeinsameMediathek: daten?.gehörtZurGemeinsamenMediathek,
                vorschauStand: kandidat.modificationDate,
                aktuellerStand: daten?.modificationDate
            )
            if !urteil.istFreigabe {
                AppLogger.upload.info("AppleDelete: verworfenes \(kandidat.localIdentifier) übersprungen — \(urteil.berichtstitel)")
            }
            // Leere Server-ID mit Absicht: Das Foto wurde nie hochgeladen. Kein
            // Nachreich-Ziel greift `.abgewähltVerworfen` oder die Schutz-Urteile
            // dieses Pfads als Auslöser auf — der Eintrag dient nur dem Bericht.
            await run.aufnehmen(
                localIdentifier: kandidat.localIdentifier,
                immichAssetId: "",
                dateiname: daten?.dateiname,
                verdict: urteil
            )
        }
    }

    /// Signalisiert dem laufenden Sweep, aufzuhören, und bricht einen hängenden
    /// iCloud-Download sofort ab, statt auf ihn zu warten.
    func cancelFullSweep() {
        progress.isCancelled = true
        hasher.abbrechen()
    }

    /// Einmaliger Nachhol-Abgleich über **alle** jemals gemappten Apple-Photos-Assets.
    /// Nur über einen expliziten Knopf in den Einstellungen ausgelöst — bewusst
    /// unabhängig vom `settingsKey`-Toggle, der nur das automatische Verhalten steuert.
    ///
    /// - Parameters:
    ///   - istProbelauf: Prüft alles, löscht nichts.
    ///   - nurGründe: Beschränkt den Lauf auf die Fotos, deren letzter Befund im
    ///     Journal einer dieser Gründe ist. `nil` heißt: alle Mappings, wie bisher.
    ///     Damit kostet die Wiederholung einer Gruppe Minuten statt eines Sweeps
    ///     über die ganze Bibliothek.
    func deleteAllPreviouslySyncedAssets(
        istProbelauf: Bool = false,
        nurGründe: Set<ApplePhotoDeletionVerdict>? = nil
    ) async -> ApplePhotoDeletionOutcome {
        let mappingByLocalId = alleMappings()

        // Ohne die Unterscheidung eigene/gemeinsame Mediathek startet der Lauf gar
        // nicht erst: Ein Löschvorgang in der gemeinsamen Mediathek wirkt für alle
        // Teilnehmenden, und die dafür nötige Erkennung ist privat — Apple kann sie
        // in einem macOS-Update entfernen. Dann steht hier ein leerer Bericht mit
        // Grund, statt eines Laufs, der stillschweigend fremde Fotos mitnimmt.
        guard ApplePhotoLibraryScope.istVerfügbar else {
            AppLogger.upload.error("AppleDelete: Nachhol-Abgleich abgebrochen — Zugehörigkeit zur gemeinsamen Mediathek nicht feststellbar")
            // Hier wird bewusst **nichts** ins Journal geschrieben: Es wurde kein
            // einziges Foto geprüft. Stünde „nicht prüfbar" als Befund für die ganze
            // Bibliothek im Journal, überschriebe dieser Frühausstieg jeden echten
            // Grund und machte jede spätere Gründe-Abfrage unbrauchbar.
            let offen = mappingByLocalId.values.filter { !$0.localIdentifier.hasSuffix("/live-video") }.count
            return ApplePhotoDeletionOutcome(
                gelöscht: 0,
                gründe: [.mediathekNichtPrüfbar: offen],
                abgebrochenWegenServerfehlern: false,
                istProbelauf: istProbelauf
            )
        }

        // "/live-video"-Einträge sind synthetische Mappings für den separat
        // hochgeladenen Video-Teil eines Live Photos, kein eigenständiges PHAsset.
        let echteMappings = mappingByLocalId.values
            .filter { !$0.localIdentifier.hasSuffix("/live-video") }
        let erlaubte = nurGründe.map { journal.localIds(mitGründen: $0) }
        // `auswählen` liefert bereits sortiert; diese Reihenfolge wird hier
        // übernommen statt verworfen und neu hergestellt — die zugesagte stabile
        // Reihenfolge soll die sein, die auch ankommt.
        let kandidaten = ApplePhotoDeletionKandidaten.auswählen(
            mappingLocalIds: echteMappings.map(\.localIdentifier),
            erlaubteLocalIds: erlaubte
        ).compactMap { mappingByLocalId[$0] }
        if let nurGründe {
            let titel = nurGründe.map(\.berichtstitel).sorted().joined(separator: ", ")
            AppLogger.upload.info("AppleDelete: Nachlauf beschränkt auf [\(titel)] — \(kandidaten.count) Kandidat(en)")
        }

        progress.isRunning = true
        progress.isCancelled = false
        progress.bereitetVor = true
        progress.total = 0
        progress.checked = 0
        progress.deletedCount = 0
        progress.vorgemerkt = 0
        defer {
            progress.isRunning = false
            progress.bereitetVor = false
            progress.aktuellerDateiname = nil
            progress.lädtAusICloud = false
        }

        let run = ApplePhotoDeletionRun(
            istProbelauf: istProbelauf,
            flush: { [weak self] ids in
                guard let self else { return 0 }
                let anzahl = await self.deleteFromApplePhotos(localIdentifiers: ids)
                self.progress.deletedCount += anzahl
                return anzahl
            },
            journal: { [weak self] befunde in
                self?.journal.schreiben(befunde)
            }
        )

        let zuPrüfen = await vorhandeneKandidaten(kandidaten, meldeAn: run)
        progress.bereitetVor = false
        progress.total = zuPrüfen.count

        äußere: for start in stride(from: 0, to: zuPrüfen.count, by: Self.sweepFetchScheibengröße) {
            let scheibe = Array(zuPrüfen[start..<min(start + Self.sweepFetchScheibengröße, zuPrüfen.count)])

            // L1 erneut, weil der Vorlauf nur die Identifier behalten hat: zehntausende
            // `PHAsset`-Objekte über den ganzen Lauf zu halten wäre teurer als der
            // zweite, rein lokale Fetch. Läuft samt Ressourcen-Auflistung auf der
            // Hintergrund-Queue — der Main Thread bekommt nur die fertigen Snapshots.
            let datenByLocalId = await Self.prüfKandidaten(für: scheibe.map(\.localIdentifier))

            for mapping in scheibe {
                if progress.isCancelled { break äußere }
                progress.checked += 1

                guard let daten = datenByLocalId[mapping.localIdentifier] else {
                    // Zwischen Vorlauf und Prüfung verschwunden — selten, aber möglich.
                    await run.aufnehmen(
                        localIdentifier: mapping.localIdentifier,
                        immichAssetId: mapping.immichAssetId,
                        verdict: .nichtMehrInApplePhotos
                    )
                    continue
                }
                progress.aktuellerDateiname = daten.dateiname

                let videoMapping = mappingByLocalId[mapping.localIdentifier + "/live-video"]
                let urteil = await verdict(
                    for: daten,
                    immichAssetId: mapping.immichAssetId,
                    mappingModificationDate: mapping.lastKnownModificationDate,
                    mappingUploadFileSize: mapping.lastUploadedFileSize,
                    liveVideoAssetId: videoMapping?.immichAssetId,
                    liveVideoUploadFileSize: videoMapping?.lastUploadedFileSize
                )
                if !urteil.istFreigabe {
                    AppLogger.upload.info("AppleDelete: \(mapping.localIdentifier) übersprungen — \(urteil.berichtstitel)")
                }

                let weiter = await run.aufnehmen(
                    localIdentifier: mapping.localIdentifier,
                    immichAssetId: mapping.immichAssetId,
                    dateiname: daten.dateiname,
                    verdict: urteil
                )
                progress.vorgemerkt = run.vorgemerkt
                if !weiter { break äußere }
            }
        }

        // Auch der Abbruchpfad läuft hier durch: Der Puffer wird noch geleert, damit
        // keine Prüfarbeit verlorengeht. Apples eigener Löschdialog ist dabei die
        // Bestätigung — wer nichts mehr gelöscht haben will, lehnt dort ab.
        let outcome = await run.abschließen()
        progress.vorgemerkt = 0
        AppLogger.upload.info("AppleDelete: Nachhol-Abgleich beendet — \(outcome.gelöscht) gelöscht, \(outcome.funde) Abweichung(en), Probelauf=\(istProbelauf)")
        return outcome
    }

    // MARK: - Verifikation eines einzelnen Kandidaten

    /// Prüft einen Kandidaten, dessen Snapshot (L1) bereits vorliegt, durch L0/L2/L3/L4.
    ///
    /// Läuft bewusst seriell — `hasher` hält den Abbruchzustand für genau einen Lauf.
    /// - Parameters:
    ///   - mappingUploadFileSize: Beim Anlegen des Mappings notierte Größe der
    ///     hochgeladenen Datei. Entscheidet nicht über die Freigabe, sondern nur
    ///     darüber, ob eine Byte-Abweichung ein Fund ist oder eine fremde Serverkopie.
    ///   - liveVideoAssetId: Immich-ID aus dem lokalen `/live-video`-Mapping. `nil`
    ///     heißt nicht „kein Videoteil" — dann greift der Rückfall auf die
    ///     `livePhotoVideoId`, die der Server selbst nennt.
    ///   - liveVideoUploadFileSize: Dieselbe Größe für den Videoteil; existiert nur,
    ///     wenn dieser Client ihn hochgeladen hat.
    private func verdict(
        for daten: ApplePhotoPrüfKandidat,
        immichAssetId: String,
        mappingModificationDate: Date?,
        mappingUploadFileSize: Int64?,
        liveVideoAssetId: String?,
        liveVideoUploadFileSize: Int64?
    ) async -> ApplePhotoDeletionVerdict {
        // Vor L0: Fremde Mediathek ist grundsätzlich tabu — löschen wirkte dort
        // für alle Teilnehmenden. Steht vor dem Server-Request, damit diese Fotos
        // keinerlei Netz- oder iCloud-Kosten verursachen.
        if let geteilt = ApplePhotoDeletionVerifier.mediathekUrteil(
            sourceType: daten.sourceType,
            gehörtZurGemeinsamenMediathek: daten.gehörtZurGemeinsamenMediathek
        ) {
            return geteilt
        }

        // L0 — eine Antwort, aus der sowohl der Status als auch die Checksum für L4
        // kommt. Zwei Requests auf dieselbe URL wären bei zehntausenden Fotos die
        // doppelte Server-Last für nichts.
        let (serverState, serverAsset) = await serverAntwort(for: immichAssetId)

        // Billig ablehnen, bevor irgendein Byte bewegt wird.
        var input = ApplePhotoVerificationInput(
            serverState: serverState,
            serverChecksumHex: serverAsset?.checksum.flatMap { ChecksumHex.fromBase64($0) },
            localChecksumHex: nil,
            mappingModificationDate: mappingModificationDate,
            currentModificationDate: daten.modificationDate,
            isLivePhoto: daten.isLivePhoto,
            livePhotoVideo: nil,
            mappingUploadFileSize: mappingUploadFileSize,
            serverFileSizeInByte: serverAsset?.exifInfo?.fileSizeInByte
        )
        // Liegt das Standbild in Immich im Papierkorb, gilt sein Videoteil dort
        // ebenfalls als weggeworfen — sonst wäre jedes bewusst gelöschte Live Photo
        // „unvollständig hochgeladen".
        let imPapierkorb = serverState == .trashed
        // Ein Voraburteil, das auch mit allen Prüfsummen in der Hand dasselbe bliebe,
        // steht schon fest — dann darf kein Original mehr aus iCloud geladen werden.
        let vorabUrteil = ApplePhotoDeletionVerifier.verdict(for: input)
        switch vorabUrteil {
        case .serverAntwortetNicht, .nichtAufServer,
             .lokalGeändert, .änderungsstandUnbekannt, .checksumFehltAufServer,
             // `.imPapierkorb` vergibt der Verifier nicht mehr — der Papierkorb ist
             // seit dem Probelauf ein Löschgrund, kein Haltegrund. Stünde der Fall
             // aus einem anderen Aufrufer doch hier, bliebe es bei der Ablehnung.
             .imPapierkorb,
             // `.nichtMehrInApplePhotos` entsteht ausschließlich im Aufrufer (L1).
             // `.abgebrochen` kann der Verifier inzwischen sehr wohl vergeben — aber
             // nur über `lokalerLesefehler == .abgebrochen`, und der ist im
             // Vorab-Input immer nil. Aus diesem Aufruf kommt der Fall also nicht;
             // stünde er hier doch, bliebe es bei der Ablehnung.
             .nichtMehrInApplePhotos, .abgebrochen,
             // Steht der Lesefehler schon fest, ändert kein weiterer Download etwas
             // daran. Aus dem Vorab-Input kann der Verifier sie noch nicht liefern
             // (`lokalerLesefehler` ist hier immer nil) — als Ablehnung stehen sie
             // trotzdem hier und nicht bei den offenen Fällen.
             .nichtLesbarICloud, .nichtLesbarUnvollständig, .keineResource,
             // Bereits oben vor L0 entschieden — hier nur der Vollständigkeit halber.
             .inGeteilterMediathek, .mediathekNichtPrüfbar,
             // Dieser Verifier vergibt die drei Nachreich-Befunde nie selbst — sie
             // entstehen ausschließlich im späteren Nachreich-Dienst, der Upload und
             // Mapping-Umschrift übernimmt. Stünden sie doch aus einem anderen Aufruf
             // hier, bliebe es bei der Ablehnung: Der Löschlauf vergibt keine Freigabe
             // für Fotos, die er selbst nicht bis zur Bytegleichheit geprüft hat.
             .nachgereicht, .nachreichenFehlgeschlagen, .nachreichenNichtMöglich:
            return vorabUrteil
        // Diese stehen hier nur mangels Prüfsummen fest — die kommen erst unten dazu.
        // `.freigegebenPapierkorb` gehört dazu: Ein Foto im Immich-Papierkorb wird
        // gelöscht, aber erst nachdem die Bytes verglichen wurden.
        // `.serverkopieAusAndererQuelle` kann hier noch gar nicht entstehen (ohne
        // lokale Prüfsumme endet L4 vorher bei `.nichtLesbar`) — der Vollständigkeit
        // halber trotzdem als „noch offen" behandelt.
        // `.livePhotoVideoAusAndererQuelle` steht aus demselben Grund hier wie
        // `.serverkopieAusAndererQuelle`: Es entsteht erst, wenn beide Prüfsummen des
        // Videoteils vorliegen — und die holt erst L3 weiter unten.
        case .freigegeben, .freigegebenPapierkorb, .nichtLesbar,
             .checksumMismatch, .serverkopieAusAndererQuelle, .livePhotoUnvollständig,
             .livePhotoVideoFehlt, .livePhotoVideoGelöscht, .livePhotoVideoImPapierkorb,
             .livePhotoVideoAusAndererQuelle,
             // Vergibt nur `ApplePhotoVerwerfUrteil` für Fotos ohne Mapping; der
             // Verifier erzeugt den Fall nie. Stünde er doch hier, entscheidet wie
             // bei jeder anderen Freigabe erst der Bytevergleich unten.
             .abgewähltVerworfen:
            break
        }

        // Ohne Prüfsumme vom Server kann L4 nie zu einer Freigabe führen. Bei einem
        // Live Photo verdeckt das Voraburteil oben diesen Fall (`livePhotoVideo` ist
        // noch nil, also lautet es `.livePhotoVideoFehlt`) — ohne diese Zeile lüde
        // ein Server ohne `checksum`-Feld für jedes Live Photo erst Video und Standbild
        // aus iCloud und lehnte danach doch ab.
        if (input.serverChecksumHex ?? "").isEmpty {
            AppLogger.upload.info("AppleDelete: Asset \(immichAssetId) — Server liefert keine Prüfsumme, kein Download nötig")
            return .checksumFehltAufServer
        }

        // L3 — der Video-Teil eines Live Photos ist ein eigenes Asset. Entscheidet er
        // die Sache bereits, wird das Standbild gar nicht erst geladen: Das spart bei
        // einem unvollständigen Live Photo einen kompletten iCloud-Download — und nach
        // einem Abbruch mitten im Video-Hash startet hier sonst ein **neuer**, nie
        // abgebrochener Hash-Lauf, während die Oberfläche „Bricht ab…" anzeigt.
        if input.isLivePhoto {
            // Das lokale `/live-video`-Mapping gibt es nur für Videoteile, die dieser
            // Client selbst hochgeladen hat. Fehlt es, nennt der Server den gepaarten
            // Videoteil in derselben Antwort, die L0 ohnehin schon geholt hat.
            guard let videoAssetId = ApplePhotoDeletionVerifier.videoTeilAssetId(
                lokalesMapping: liveVideoAssetId,
                serverLivePhotoVideoId: serverAsset?.livePhotoVideoId
            ) else {
                AppLogger.upload.info("AppleDelete: Asset \(immichAssetId) — weder Mapping noch livePhotoVideoId für den Live-Photo-Videoteil")
                return .livePhotoVideoFehlt
            }
            let (videoState, videoServerAsset) = await serverAntwort(for: videoAssetId)
            // Gehasht wird nur, wenn der Videoteil überhaupt noch freigabefähig ist:
            // ein weggeworfener Videoteil zählt allein dann, wenn auch das Standbild
            // im Papierkorb liegt. Sonst spart dieser Zweig einen vollen
            // iCloud-Download für ein Urteil, das schon feststeht.
            let videoZählt = videoState == .alive || (videoState == .trashed && imPapierkorb)
            var videoHash: String?
            var videoLesefehler: ApplePhotoLesefehler?
            if videoZählt {
                if let videoResource = daten.videoResource {
                    // Zwischen zwei hashen()-Aufrufen hält `hasher` keinen Abbruchzustand mehr —
                    // ohne diese Prüfung würde ein Abbruch, der genau hier landet, einen neuen,
                    // nie abgebrochenen iCloud-Download starten, während die Oberfläche schon
                    // „Bricht ab…" zeigt.
                    if progress.isCancelled {
                        AppLogger.upload.info("AppleDelete: Asset \(immichAssetId) — Abbruch vor Videoteil-Hash, keine Freigabe")
                        return .abgebrochen
                    }
                    let ergebnis = await hashen(videoResource)
                    videoHash = ergebnis.hex
                    videoLesefehler = Self.lesefehler(aus: ergebnis)
                } else {
                    videoLesefehler = .keineResource
                }
            }
            input.livePhotoVideo = LivePhotoVideoInput(
                serverState: videoState,
                serverChecksumHex: videoServerAsset?.checksum.flatMap { ChecksumHex.fromBase64($0) },
                localChecksumHex: videoHash,
                mappingUploadFileSize: liveVideoUploadFileSize,
                serverFileSizeInByte: videoServerAsset?.exifInfo?.fileSizeInByte,
                lokalerLesefehler: videoLesefehler
            )
            let videoUrteil = ApplePhotoDeletionVerifier.livePhotoVideoUrteil(
                input.livePhotoVideo,
                hauptAssetImPapierkorb: imPapierkorb
            )
            guard videoUrteil.istFreigabe else {
                AppLogger.upload.info("AppleDelete: Asset \(immichAssetId) — Videoteil entscheidet: \(videoUrteil.berichtstitel)")
                return videoUrteil
            }
        }

        // L4 — dieselbe Resource, die auch hochgeladen wurde. Bei bearbeiteten Fotos
        // ist das die bearbeitete Fassung; gegen das Original verglichen schlüge der
        // Vergleich fälschlich fehl.
        if let resource = daten.hauptResource {
            // Dieselbe Lücke wie beim Videoteil oben: ein Abbruch zwischen den beiden
            // hashen()-Aufrufen darf nicht unbemerkt einen neuen Download anstoßen.
            if progress.isCancelled {
                AppLogger.upload.info("AppleDelete: Asset \(immichAssetId) — Abbruch vor Haupt-Hash, keine Freigabe")
                return .abgebrochen
            }
            let ergebnis = await hashen(resource)
            input.localChecksumHex = ergebnis.hex
            input.lokalerLesefehler = Self.lesefehler(aus: ergebnis)
        } else {
            input.lokalerLesefehler = .keineResource
        }

        return ApplePhotoDeletionVerifier.verdict(for: input)
    }

    /// `nil` als Status heißt „Server hat nicht geantwortet", nicht „alles in Ordnung".
    private func serverAntwort(for id: String) async -> (ImmichAPIClient.AssetServerState?, Asset?) {
        guard let antwort = try? await apiClient.fetchAssetForVerification(id: id) else {
            AppLogger.upload.info("AppleDelete: Server antwortet nicht für Asset \(id)")
            return (nil, nil)
        }
        return (antwort.state, antwort.asset)
    }

    /// Liefert das Ergebnis samt Grund — `nil` als Rückgabe gibt es hier nicht mehr,
    /// weil genau diese Einebnung die 236 „nicht lesbar" unauswertbar gemacht hat.
    /// Alles außer `.hash` führt oben nie zu einer Freigabe.
    private func hashen(_ resource: PHAssetResource) async -> ApplePhotoHashErgebnis {
        progress.lädtAusICloud = false
        progress.iCloudFortschritt = 0
        let ergebnis = await hasher.sha1Hex(for: resource) { [progress] anteil in
            Task { @MainActor in
                progress.lädtAusICloud = anteil < 1.0
                progress.iCloudFortschritt = anteil
            }
        }
        progress.lädtAusICloud = false
        return ergebnis
    }

    /// `nil`, wenn ein Hash zustande kam.
    private static func lesefehler(aus ergebnis: ApplePhotoHashErgebnis) -> ApplePhotoLesefehler? {
        switch ergebnis {
        case .hash:          return nil
        case .icloudFehler:  return .icloud
        case .unvollständig: return .unvollständig
        case .abgebrochen:   return .abgebrochen
        }
    }

    // MARK: - Nachschlagen

    private func alleMappings() -> [String: ApplePhotosAssetMapping] {
        let mappings = (try? modelContext.fetch(FetchDescriptor<ApplePhotosAssetMapping>())) ?? []
        var byLocalId: [String: ApplePhotosAssetMapping] = [:]
        for mapping in mappings { byLocalId[mapping.localIdentifier] = mapping }
        return byLocalId
    }

    /// L1 — welche der Identifier überhaupt noch ein Foto in der Bibliothek haben.
    /// Trennt vor dem eigentlichen Lauf die Mappings, hinter denen noch ein Foto
    /// steht, von den Karteileichen — und meldet letztere direkt als
    /// `nichtMehrInApplePhotos` an den Lauf, damit der Bericht vollständig bleibt.
    ///
    /// Das ist kein Mikro-Optimieren des Balkens: Ein normaler `PHAsset`-Fetch
    /// liefert Apples "Zuletzt gelöscht" nicht mit, und Mappings werden nie
    /// aufgeräumt. Auf einer aufgeräumten Mediathek liegt deshalb ein erheblicher
    /// Teil des Bestands als bereits gelöscht in der Tabelle (hier gemessen rund
    /// ein Viertel). Ohne diesen Vorlauf zählte der Nenner sie mit, und der
    /// Fortschritt sähe dauerhaft schlechter aus, als er ist.
    private func vorhandeneKandidaten(
        _ kandidaten: [ApplePhotosAssetMapping],
        meldeAn run: ApplePhotoDeletionRun
    ) async -> [ApplePhotosAssetMapping] {
        var vorhanden: [ApplePhotosAssetMapping] = []
        vorhanden.reserveCapacity(kandidaten.count)

        for start in stride(from: 0, to: kandidaten.count, by: Self.sweepFetchScheibengröße) {
            if progress.isCancelled { break }
            let scheibe = Array(kandidaten[start..<min(start + Self.sweepFetchScheibengröße, kandidaten.count)])
            // Nur die Existenzfrage — die volle Snapshot-Extraktion samt Ressourcen
            // wäre hier für Zehntausende bereits gelöschter Mappings verschenkt.
            let gefunden = await Self.vorhandeneLocalIds(unter: scheibe.map(\.localIdentifier))

            for mapping in scheibe {
                if gefunden.contains(mapping.localIdentifier) {
                    vorhanden.append(mapping)
                } else {
                    // Bewusst ohne Logzeile pro Foto — das wären hier Zehntausende.
                    await run.aufnehmen(
                        localIdentifier: mapping.localIdentifier,
                        immichAssetId: mapping.immichAssetId,
                        verdict: .nichtMehrInApplePhotos
                    )
                }
            }
        }

        AppLogger.upload.info("AppleDelete: Vorlauf — \(vorhanden.count)/\(kandidaten.count) Mapping(s) haben noch ein Foto")
        return vorhanden
    }

    /// Sammelt zu jedem noch vorhandenen Foto den vollständigen Prüf-Snapshot ein —
    /// auf einer Hintergrund-Queue, denn genau diese Zugriffe (faule
    /// `PHAsset`-Properties, `assetResources`) haben auf dem Main Thread die
    /// Oberfläche zum Stehen gebracht.
    private nonisolated static func prüfKandidaten(
        für localIdentifiers: [String]
    ) async -> [String: ApplePhotoPrüfKandidat] {
        guard !localIdentifiers.isEmpty else { return [:] }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let gefunden = PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers, options: nil)
                var byLocalId: [String: ApplePhotoPrüfKandidat] = [:]
                byLocalId.reserveCapacity(gefunden.count)
                gefunden.enumerateObjects { asset, _, _ in
                    let ressourcen = PHAssetResource.assetResources(for: asset)
                    let haupt = AppleResourcePicker.preferred(ressourcen, mediaType: asset.mediaType)
                    byLocalId[asset.localIdentifier] = ApplePhotoPrüfKandidat(
                        localIdentifier: asset.localIdentifier,
                        sourceType: asset.sourceType,
                        gehörtZurGemeinsamenMediathek: ApplePhotoLibraryScope.gehörtZurGemeinsamenMediathek(asset),
                        mediathekBereich: ApplePhotoLibraryScope.bereich(asset),
                        modificationDate: asset.modificationDate,
                        isLivePhoto: asset.mediaSubtypes.contains(.photoLive),
                        dateiname: (haupt ?? ressourcen.first)?.originalFilename,
                        hauptResource: haupt,
                        videoResource: AppleResourcePicker.pairedVideo(ressourcen)
                    )
                }
                // Eine Zeile pro Scheibe, nicht pro Foto: Sie ist der einzige Weg, die
                // Bedeutung der privaten Property am echten Bestand zu prüfen. Gälten
                // plötzlich *alle* Fotos als gemeinsam, hätte sich die Semantik
                // geändert — sichtbar an dieser Verteilung, nicht erst am Ergebnis.
                let gemeinsam = byLocalId.values.filter { $0.gehörtZurGemeinsamenMediathek == true }.count
                let bereiche = Set(byLocalId.values.compactMap(\.mediathekBereich)).sorted()
                AppLogger.upload.info("AppleDelete: Mediathek-Prüfung — \(gemeinsam)/\(byLocalId.count) in gemeinsamer Mediathek, bundleScope=\(bereiche)")
                continuation.resume(returning: byLocalId)
            }
        }
    }

    /// Existenzprüfung ohne Metadaten- oder Ressourcen-Zugriff — für den Vorlauf,
    /// der nur wissen will, hinter welchen Mappings überhaupt noch ein Foto steht.
    private nonisolated static func vorhandeneLocalIds(
        unter localIdentifiers: [String]
    ) async -> Set<String> {
        guard !localIdentifiers.isEmpty else { return [] }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let gefunden = PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers, options: nil)
                var ids = Set<String>(minimumCapacity: gefunden.count)
                gefunden.enumerateObjects { asset, _, _ in ids.insert(asset.localIdentifier) }
                continuation.resume(returning: ids)
            }
        }
    }

    /// Entfernt die übergebenen, bereits serverseitig verifizierten Assets per
    /// `PHPhotoLibrary` aus Apple Photos. Landet in Apples "Kürzlich gelöscht"
    /// (30 Tage wiederherstellbar), kein Hard-Delete.
    private func deleteFromApplePhotos(localIdentifiers: [String]) async -> Int {
        guard !localIdentifiers.isEmpty else {
            AppLogger.upload.info("AppleDelete: nichts zu löschen — keine verifizierten Assets")
            return 0
        }

        let authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let result = PHAsset.fetchAssets(withLocalIdentifiers: localIdentifiers, options: nil)
        AppLogger.upload.info("AppleDelete: \(result.count)/\(localIdentifiers.count) PHAsset(s) in Apple Photos gefunden (Berechtigung=\(authorization.rawValue))")
        guard result.count > 0 else { return 0 }
        var assetsToDelete: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in assetsToDelete.append(asset) }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assetsToDelete as NSArray)
            }
            AppLogger.upload.info("AppleDelete: removed \(assetsToDelete.count) asset(s) from Apple Photos after sync")
            NotificationCenter.default.post(
                name: .applePhotosDeletedAfterSync,
                object: nil,
                userInfo: ["count": assetsToDelete.count]
            )
            return assetsToDelete.count
        } catch {
            AppLogger.upload.warning("AppleDelete: PHPhotoLibrary deletion failed: \(error.localizedDescription)")
            return 0
        }
    }
}
