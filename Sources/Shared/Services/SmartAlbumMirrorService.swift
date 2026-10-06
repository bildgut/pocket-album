import Foundation
import SwiftData

/// Ergebnis der Frage „welche Assets erfüllen die Regeln dieses Smart Albums?".
///
/// `.skipped` ist bewusst kein `.resolved([])`: Ein leeres Ergebnis wäre eine Aussage
/// („nichts passt"), ein übersprungener Lauf ist keine. Wer die beiden verwechselt,
/// leert beim Spiegel das Album auf dem Server und wirft beim Offline-Vorhalten alle
/// bereits geladenen Dateien weg.
enum SmartAlbumResolution: Equatable {
    case resolved(Set<String>)
    case skipped(reason: String)

    var ids: Set<String>? {
        if case .resolved(let ids) = self { return ids }
        return nil
    }

    var skipReason: String? {
        if case .skipped(let reason) = self { return reason }
        return nil
    }
}

/// Keeps a Smart Album's server-side mirror album in sync with the local filter result.
///
/// Lifecycle:
///   - Call `syncAll(context:apiClient:allAssets:personAssetIdsByPerson:)` on app start
///     and after any full sync cycle.
///   - Call `sync(album:...)` directly after a rule change or manual user request.
///
/// Algorithm per album:
///   0. Passt das ganze Regelwerk exakt auf den Server (``SmartAlbumServerQuery``),
///      ist `soll` das Ergebnis **einer** Suche — Schritte 1–2 entfallen.
///   1. Deep-resolve rules that need server queries (cameraModel, dateRange, yearIs, etc.)
///      → builds `serverConfirmedIds` + enriched asset pool
///   2. Evaluate rules locally → `soll: Set<String>`
///   3. GET /api/albums/{mirrorId} → `ist: Set<String>`
///      (skipped if cached `mirrorLastSyncedIds` matches `soll` exactly)
///   4. Diff → toAdd / toRemove
///   5. Batch PUT / DELETE
///   6. Persist new `mirrorLastSyncedIds` + timestamp
@MainActor
final class SmartAlbumMirrorService {

    private let apiClient: ImmichAPIClient
    private let gridIndexStore: GridIndexStore
    private let membershipStore: AlbumMembershipStore
    private let defaults: UserDefaults
    private let batchSize = 500

    /// Kataloge und Konto-ID gelten für einen ganzen `syncAll`-Lauf; ohne den
    /// Zwischenspeicher fragte jedes Spiegel-Album sie einzeln ab.
    private var catalogCache: [SmartAlbumServerQuery.CatalogKind: [String]] = [:]
    private var cachedUserId: String?

    /// - Parameter gridIndexStore: injizierbar für Tests, die das EXIF-Gate (Schritt 1.5
    ///   in `sync`) gegen einen absichtlich nicht lesbaren Index prüfen wollen, ohne den
    ///   Prozess-weiten `GridIndexStore.shared`-Singleton anzufassen — der wird von
    ///   anderen, parallel laufenden Tests mitbenutzt.
    /// - Parameter defaults: Quelle des v8-Backfill-Markers (Vorbedingung des EXIF-Gates,
    ///   siehe `GridIndexStore.exifV8BackfillComplete`). Aus demselben Grund injizierbar:
    ///   Der App-Start des Test-Hosts stößt den Backfill in `AppEnvironment.defaults`
    ///   selbst an, Tests müssen den Marker aber beidseitig kontrollieren können.
    /// - Parameter membershipStore: injizierbar für Tests des Mitgliedschafts-Tors der
    ///   Regel „In keinem Album" (siehe `resolveTargetIds`) — aus demselben Grund wie
    ///   `gridIndexStore`.
    init(
        apiClient: ImmichAPIClient,
        gridIndexStore: GridIndexStore = .shared,
        membershipStore: AlbumMembershipStore = .shared,
        defaults: UserDefaults = AppEnvironment.defaults
    ) {
        self.apiClient = apiClient
        self.gridIndexStore = gridIndexStore
        self.membershipStore = membershipStore
        self.defaults = defaults
    }

    // MARK: - Public API

    /// Sync all mirrored Smart Albums. Called after app-start sync or foreground resume.
    /// - Parameter poolIsComplete: Ob `allAssets` die ganze Bibliothek abdeckt.
    ///   `false` heißt: Es ist ein Ausschnitt, und für Regeln ohne Server-Entsprechung
    ///   ist die Differenz gegen das Server-Album dann keine Aussage über „gehört nicht
    ///   mehr rein", sondern nur über „war nicht im Ausschnitt".
    func syncAll(
        context: ModelContext,
        allAssets: [Asset],
        personAssetIdsByPerson: [String: Set<String>],
        poolIsComplete: Bool = true
    ) async {
        let descriptor = FetchDescriptor<SmartAlbum>()
        guard let albums = try? context.fetch(descriptor) else { return }

        let mirrored = albums.filter { $0.isMirrored }
        guard !mirrored.isEmpty else { return }

        AppLogger.app.debug("SmartAlbumMirrorService: syncing \(mirrored.count) mirrored album(s)")

        // Einmal für alle: Die Spiegel-Alben zählen bei „In keinem Album" nicht als
        // Ablage (siehe `SmartAlbum.mirroredServerAlbumIds`). `albums` steht hier
        // schon — ein zweiter Fetch wäre umsonst.
        let mirroredAlbumIds = Set(albums.compactMap(\.mirrorAlbumId))

        // Sequential — server searches are already paginated and bursty enough
        for album in mirrored {
            await sync(album: album, allAssets: allAssets,
                       personAssetIdsByPerson: personAssetIdsByPerson,
                       poolIsComplete: poolIsComplete,
                       mirroredAlbumIds: mirroredAlbumIds)
        }

        try? context.save()
    }

    /// Sync a single Smart Album mirror. Creates the server album if it doesn't exist yet.
    /// - Parameter poolIsComplete: siehe ``syncAll(context:allAssets:personAssetIdsByPerson:poolIsComplete:)``.
    func sync(
        album: SmartAlbum,
        allAssets: [Asset],
        personAssetIdsByPerson: [String: Set<String>],
        poolIsComplete: Bool = true,
        mirroredAlbumIds: Set<String> = []
    ) async {
        guard let mirrorAlbumId = album.mirrorAlbumId else { return }

        album.mirrorSyncStatus = .syncing

        // Was *soll* drin sein? Die Frage samt aller Schutztore beantwortet
        // `resolveTargetIds` — dieselbe Funktion, die auch das Offline-Vorhalten
        // benutzt. So kann die Antwort für Spiegel und Offline-Kopie nicht
        // auseinanderlaufen.
        let soll: Set<String>
        switch await resolveTargetIds(for: album, basePool: allAssets,
                                      poolIsComplete: poolIsComplete,
                                      mirroredAlbumIds: mirroredAlbumIds) {
        case .skipped(let reason):
            album.mirrorSyncStatus = .error
            album.mirrorLastError = reason
            AppLogger.app.error("SmartAlbumMirror '\(album.name)': Abgleich übersprungen — \(reason)")
            return
        case .resolved(let ids):
            soll = ids
        }

        do {
            // 3. Get current server state
            let detail = try await apiClient.getAlbumDetail(id: mirrorAlbumId)
            let ist = Set(detail.assets.map(\.id))

            if ist == soll {
                album.mirrorLastSyncedIds  = soll
                album.mirrorLastSyncedAt   = Date()
                album.mirrorSyncStatus     = .upToDate
                album.mirrorLastError      = nil
                AppLogger.app.debug("SmartAlbumMirror '\(album.name)': up to date (\(soll.count) assets)")
                return
            }

            // 4. Diff
            let toAdd    = Array(soll.subtracting(ist))
            let toRemove = Array(ist.subtracting(soll))

            AppLogger.app.info("SmartAlbumMirror '\(album.name)': +\(toAdd.count) -\(toRemove.count) (total \(soll.count))")

            // 5. Apply in batches
            for chunk in toAdd.chunked(into: batchSize) {
                try await apiClient.addAssetsToAlbum(albumId: mirrorAlbumId, assetIds: chunk)
            }
            for chunk in toRemove.chunked(into: batchSize) {
                try await apiClient.removeAssetsFromAlbum(albumId: mirrorAlbumId, assetIds: chunk)
            }

            // 6. Persist state
            album.mirrorLastSyncedIds  = soll
            album.mirrorLastSyncedAt   = Date()
            album.mirrorSyncStatus     = .upToDate
            album.mirrorLastError      = nil

        } catch {
            album.mirrorSyncStatus = .error
            album.mirrorLastError  = error.localizedDescription
            AppLogger.app.error("SmartAlbumMirror '\(album.name)' failed: \(error)")
        }
    }

    // MARK: - Auflösung der Soll-Mitgliedschaft

    /// Welche Assets erfüllen die Regeln dieses Smart Albums?
    ///
    /// Herausgelöst aus ``sync(album:allAssets:personAssetIdsByPerson:poolIsComplete:)``,
    /// weil das Offline-Vorhalten dieselbe Frage stellt — und zwar mit denselben
    /// Schutztoren. Jedes Tor liefert `.skipped` mit einem Grund in Klartext, den der
    /// Aufrufer anzeigen kann. `.skipped` heißt ausdrücklich **nicht** „leere Menge":
    /// Wer daraus eine leere Soll-Menge machte, räumte beim Spiegel das Server-Album
    /// leer und würfe beim Offline-Vorhalten alle Dateien weg.
    /// - Parameter mirroredAlbumIds: IDs **aller** Spiegel-Alben (siehe
    ///   ``SmartAlbum/mirroredServerAlbumIds(in:)``). Nur für die Regel
    ///   ``SmartAlbumRule/isInNoAlbum`` von Belang; das eigene Spiegel-Album nimmt der
    ///   Dienst ohnehin heraus, ein leerer Wert ist also nie gefährlich — er macht die
    ///   Regel nur strenger, als der Nutzer sie meint.
    func resolveTargetIds(
        for album: SmartAlbum,
        basePool: [Asset],
        poolIsComplete: Bool = true,
        mirroredAlbumIds: Set<String> = []
    ) async -> SmartAlbumResolution {

        // Album ohne Regeln — der zerstörerischste Fall von „`soll` zu klein".
        //
        // `SmartAlbumEvaluator.evaluate` liefert bei leerer Regelliste bewusst `[]`:
        // Für die Anzeige ist das richtig, ein Album ohne Regeln zeigt nichts. Hier
        // hieße es `toRemove = ist.subtracting([])` — also **jedes** Asset aus dem
        // echten Immich-Album entfernen.
        //
        // Erreichbar ist das über den Editor: Sein Sichern-Knopf hängt allein am
        // Namen, nicht an den Regeln. Wer die letzte Regel eines gespiegelten Albums
        // löscht und sichert, meint einen Zwischenstand — nicht „räum das Album auf
        // dem Server leer".
        //
        // Dieselbe Haltung wie bei den EXIF-Toren, beim Pool-Tor und bei
        // ausgefallenen Server-Auskünften: lieber kein Abgleich als ein falscher.
        guard !album.rules.isEmpty else {
            return .skipped(reason: """
                Das Album hat keine Regeln. Ein Abgleich würde jedes Foto aus dem \
                Album auf dem Server entfernen.
                """)
        }

        // Der kurze Weg: Passt das ganze Regelwerk exakt auf den Server, beantwortet
        // eine Suche die Frage für die ganze Bibliothek. Die Tore unten entfallen dann
        // nicht aus Nachlässigkeit, sondern weil sie hier nichts zu bewachen haben:
        // Keine dieser Regeln liest EXIF aus dem Index, keine hängt am Album-Index,
        // und ein Ausschnitt des Pools spielt keine Rolle, weil der Pool nicht benutzt
        // wird.
        if let serverResult = await resolveOnServer(album) {
            return serverResult
        }

        // Betrifft das EXIF-Gate dieses Album überhaupt? Alben ohne EXIF-abhängige Regel
        // (z. B. nur `isFavorite`) werden vom Gate nie gebremst — weder von einem
        // klemmenden Grid-Index noch vom laufenden v8-Backfill. Vor den fünf neuen Regeln
        // lief ihr Abgleich, und das muss so bleiben.
        let usesExifRules = SmartAlbumEvaluator.usesExifDependentRule(album.rules)
        let backfillComplete = GridIndexStore.exifV8BackfillComplete(defaults: defaults)

        // Vorbedingung des Gates, bewusst *vor* jedem Server-Aufruf geprüft: Solange der
        // einmalige v8-Backfill nicht durch ist, gilt „exifCheckedAt IS NOT NULL ⟹
        // EXIF-Spalten autoritativ" nicht. Zehntausende Zeilen tragen dann einen
        // Prüfzeitpunkt bei leeren Spalten — `hasNoLocation` träfe fast die ganze
        // Bibliothek, und dieser Dienst lüde sie per PUT in ein echtes Immich-Album.
        // Die Prüfung braucht den Pool nicht, sie kann deshalb ganz nach vorn.
        if usesExifRules && !backfillComplete {
            return .skipped(reason: "EXIF-Daten werden gerade einmalig aufbereitet — wird beim nächsten Durchlauf nachgeholt.")
        }

        // Deckt der Grundpool die Bibliothek ab?
        //
        // `resolveAllServerRules` füllt fehlende Assets nach — aber nur für Regeln mit
        // einer Server-Entsprechung (Person, Kameramodell, Datum, Jahr). Rein lokal
        // auswertbare Regeln (`isFavorite`, `isStacked`, `isScreenshot`, `hasNoLocation`,
        // `isRAW`, `isPanorama` sowie alles Negierte) haben keine solche Quelle: Für sie
        // ist `soll` genau so groß wie das Fenster, das der Aufrufer mitgebracht hat.
        //
        // Der Aufrufer beim App-Start reicht `viewModel.cachedAssets` durch, und das ist
        // im schnellen Pfad die **erste Seite** des Grid-Index — 4 000 Assets, unabhängig
        // davon, wie groß die Bibliothek ist (`AssetRepository.loadAssetsFromCache`).
        // `toRemove = ist.subtracting(soll)` umfasste damit alles außerhalb dieses
        // Fensters, und der Abgleich löschte es aus dem echten Immich-Album.
        //
        // Der Aufrufer sagt es ausdrücklich, statt dass der Dienst es aus
        // `GridIndexStore.shared` errät: Dessen Inhalt muss mit dem übergebenen Pool
        // nichts zu tun haben — die Detailansicht mischt Server-Treffer eines
        // Tiefen-Scans hinzu, die gar nicht im Index stehen.
        //
        // Dieselbe Haltung wie bei den EXIF-Toren und bei `resolveAllServerRules`, wo
        // dieselbe Überlegung schon für ausgefallene Server-Auskünfte steht: Ein
        // Teilergebnis ist hier nicht brauchbar — lieber kein Abgleich als ein falscher.
        //
        // Bei einer Bibliothek, die in ein Fenster passt, greift das Tor nicht; dort war
        // der Abgleich auch bisher schon richtig.
        var basePool = basePool
        var poolIsComplete = poolIsComplete
        if !poolIsComplete, hasLocallyResolvedRule(album) {
            // Statt aufzugeben: den vollständigen sichtbaren Bestand aus dem Grid-Index
            // holen. `loadAll()` filtert `isTrashed = 0 AND isArchived = 0 AND
            // isHidden = 0` — genau der Bestand, den der Nutzer als seine Bibliothek
            // sieht, und damit die richtige Grundlage für `soll`.
            //
            // Das ist kein Widerspruch zum Grundsatz, dass der Dienst die
            // Vollständigkeit nicht *errät*: Der Aufrufer sagt weiterhin, was er
            // mitbringt. Der Dienst beschafft sich nur gezielt das, was fehlt.
            //
            // Nur wenn selbst das nicht trägt, bleibt es beim Abbruch. Ein Teilergebnis
            // ist hier unbrauchbar: `toRemove = ist.subtracting(soll)` würde alles
            // außerhalb des Fensters aus dem echten Immich-Album löschen.
            if let ungetragen = album.rules.first(where: { !Self.gridIndexCanCarry($0.rule) }) {
                return .skipped(reason: """
                    Es lag nur ein Teil der Bibliothek vor (\(basePool.count) Fotos), und \
                    die Regel „\(ungetragen.rule.displayLabel)“ lässt sich aus dem \
                    Schnellindex nicht beantworten — dort fehlt das nötige Feld. Mit einem \
                    Teilbestand wäre das Ergebnis zu klein.
                    """)
            }
            let vollstaendig = gridIndexStore.loadAll()
            guard !vollstaendig.isEmpty else {
                return .skipped(reason: """
                    Es lag nur ein Teil der Bibliothek vor (\(basePool.count) Fotos), und \
                    der Schnellindex war nicht lesbar. Mit einem Teilbestand wäre das \
                    Ergebnis zu klein.
                    """)
            }
            AppLogger.app.info("SmartAlbumMirror '\(album.name)': Pool von \(basePool.count) auf \(vollstaendig.count) aus dem Schnellindex erweitert")
            basePool = vollstaendig
            poolIsComplete = true
        }

        do {
            // 1. Resolve all server-side rules:
            //    - containsPerson → fetches per-person asset IDs from server
            //    - cameraModel / dateRange / yearIs / … → metadata search API
            //    The incoming personAssetIdsByPerson is ignored — the service always
            //    fetches fresh data so it works correctly from syncAll (called with [:]).
            // Wirft, wenn eine serverseitige Auskunft ausfällt: `soll` wäre dann
            // unvollständig und die Differenz gegen `ist` würde Assets auf dem
            // Server löschen, die dort hingehören.
            let (enrichedPool, resolvedPersonIds, serverConfirmedIds) = try await resolveAllServerRules(
                for: album,
                basePool: basePool
            )

            // 1.5 Welche Assets im Pool haben ungeprüftes EXIF?
            //
            // Ohne dieses Gate würde `soll` bei einer hasNoLocation-Regel jedes Asset
            // enthalten, dessen EXIF nie vom Server geholt wurde — und der Mirror
            // lüde sie in ein echtes Album auf dem Server hoch. Ein Anzeigefehler
            // wäre ärgerlich; dieser wäre nach außen wirksam.
            //
            // `nil` heißt: der Grid-Index war nicht lesbar. Genau wie bei einer
            // ausgefallenen Server-Auskunft oben ist ein Teilergebnis hier nicht
            // brauchbar — ohne verlässliche Kenntnis des EXIF-Gates gälte im
            // Zweifel jedes Asset als geprüft, und der Mirror lüde sie hoch. Lieber
            // kein Abgleich als ein falscher.
            //
            // Nur für Alben mit EXIF-abhängiger Regel: sonst kostet das Gate nur Zeit
            // und könnte einen Abgleich verhindern, den es gar nichts angeht.
            var exifUncheckedIds: Set<String> = []
            if usesExifRules {
                let poolIds = enrichedPool.map(\.id)
                let store = gridIndexStore
                let missingIds = await Task.detached(priority: .userInitiated) {
                    store.idsMissingExifCheck(among: poolIds)
                }.value
                let gate = SmartAlbumEvaluator.resolveExifGate(
                    from: missingIds,
                    poolIds: poolIds,
                    backfillComplete: backfillComplete
                )
                switch gate.status {
                case .ready:
                    exifUncheckedIds = gate.uncheckedIds
                case .indexUnreadable:
                    return .skipped(reason: "Grid-Index nicht lesbar — EXIF-Status konnte nicht geprüft werden.")
                case .backfillPending:
                    // Vom Vorab-Guard oben eigentlich schon abgefangen; hier nur, damit
                    // der Fall nicht still als „geprüft" durchrutscht, falls der Marker
                    // je woanders herkommt.
                    return .skipped(reason: "EXIF-Daten werden gerade einmalig aufbereitet — wird beim nächsten Durchlauf nachgeholt.")
                }
            }

            // 1.6 Kann der Bestand die Regeln dieses Albums überhaupt beantworten?
            //
            // `fNumberMax` und `isoMin` lesen `exifInfo?.fNumber` bzw. `?.iso`. Diese
            // Werte stehen in SwiftData, aber **nicht** im Grid-Index: `assetFromRow`
            // baut `ExifInfo` ohne sie, die Spalten gibt es dort nicht. Und der
            // Grundbestand kommt aus genau diesem Index — auch das Nachladen fehlender
            // Assets in `resolveAllServerRules` greift darauf zu.
            //
            // Für diese Assets liefert der Auswerter deshalb `false`, und zwar
            // ausnahmslos. Bei `matchMode == .all` wäre `soll` damit leer und der
            // Abgleich räumte das echte Album auf dem Server leer — derselbe Schaden
            // wie beim Album ohne Regeln, nur eine Ebene tiefer versteckt.
            //
            // Das EXIF-Tor oben fängt das **nicht**: Es fragt, ob der Server nach EXIF
            // gefragt wurde, nicht, ob dieses `Asset` das Feld trägt. Ein geprüftes
            // Asset aus dem Index hat `exifCheckedAt` gesetzt und `fNumber == nil`.
            //
            // Geprüft wird die Datenlage, nicht die Regelart: Trägt irgendein Asset
            // des Bestands den Wert, kann der Bestand die Frage beantworten.
            let benoetigtBlende = album.rules.contains { if case .fNumberMax = $0.rule { return true }; return false }
            let benoetigtISO    = album.rules.contains { if case .isoMin = $0.rule { return true }; return false }
            if (benoetigtBlende && !enrichedPool.contains { $0.exifInfo?.fNumber != nil })
                || (benoetigtISO && !enrichedPool.contains { $0.exifInfo?.iso != nil }) {
                return .skipped(reason: """
                    Zu Blende und ISO liegen im lokalen Bestand keine Werte vor. Eine \
                    Regel dieses Albums stützt sich darauf und träfe deshalb auf nichts.
                    """)
            }

            // 1.7 Mitgliedschafts-Tor für „In keinem Album".
            //
            // Die Regel liest den lokalen Album-Index. Deckt der nicht **alle** Alben
            // ab, wertet der Evaluator sie zu „unbekannt" aus — kein Treffer, `soll`
            // schrumpft, und `toRemove = ist − soll` entfernte echte Fotos aus dem
            // Immich-Album. Deshalb hier `.skipped` statt Weiterrechnen mit `nil` —
            // dieselbe Haltung wie bei den EXIF-Toren: lieber kein Abgleich als ein
            // falscher.
            //
            // Die Albumzahl kommt frisch vom Server (dieselben Endpunkte, die den
            // Indexer füttern) — der View-Model-Stand des Aufrufers könnte veraltet
            // oder beim App-Start noch leer sein. Das eigene Spiegel-Album wird vom
            // Zählen ausgenommen: Ohne den Ausschluss schlösse der nächste Lauf die
            // gerade eingespiegelten Assets wieder aus (Add/Remove-Oszillieren).
            var assetIdsInAnyAlbum: Set<String>? = nil
            if SmartAlbumEvaluator.usesAlbumMembershipRule(album.rules) {
                let owned = try await apiClient.getAlbums()
                let shared = try await apiClient.getSharedAlbums()
                var seen = Set<String>()
                let knownAlbumCount = (owned + shared).filter { seen.insert($0.id).inserted }.count
                // Das eigene Spiegel-Album unabhängig vom Parameter — daran hängt der
                // Selbstbezug, und ein Aufrufer, der die Liste nicht mitgibt, darf das
                // Oszillieren nicht zurückholen.
                var excluded = mirroredAlbumIds
                if let ownMirrorId = album.mirrorAlbumId { excluded.insert(ownMirrorId) }
                let store = membershipStore
                let set: Set<String>? = await Task.detached(priority: .userInitiated) {
                    guard store.isCoveringAllAlbums(knownAlbumCount: knownAlbumCount) else { return nil }
                    return store.assetIdsInAnyAlbum(excludingAlbumIds: excluded)
                }.value
                guard let set else {
                    return .skipped(reason: """
                        Der Album-Index deckt noch nicht alle Alben ab — die Regel \
                        „In keinem Album" wäre nicht beantwortbar und die Soll-Menge \
                        zu klein.
                        """)
                }
                assetIdsInAnyAlbum = set
            }

            // 2. Evaluate rules → desired set
            let soll = Set(
                SmartAlbumEvaluator.evaluate(
                    album,
                    against: enrichedPool,
                    personAssetIdsByPerson: resolvedPersonIds,
                    serverConfirmedIds: serverConfirmedIds,
                    exifUncheckedIds: exifUncheckedIds,
                    assetIdsInAnyAlbum: assetIdsInAnyAlbum
                ).map(\.id)
            )

            return .resolved(soll)

        } catch {
            // Eine ausgefallene Server-Auskunft macht das Ergebnis unvollständig — und
            // unvollständig ist hier nicht brauchbar, weder als Soll-Menge für den
            // Spiegel noch als Liste der offline zu haltenden Dateien.
            return .skipped(reason: error.localizedDescription)
        }
    }

    /// `soll` aus einer einzigen strukturierten Suche — oder `nil`, wenn das Regelwerk
    /// nicht exakt auf den Server passt und der lokale Weg rechnen muss.
    ///
    /// Fällt eine Serverauskunft aus, ist das Ergebnis `.skipped`, **nicht** `nil`:
    /// Der lokale Weg bräuchte für dieselben Regeln ohnehin den Server und sähe nur
    /// weniger — ein stilles Ausweichen machte aus einem Ausfall einen kleineren
    /// Abgleich.
    ///
    /// Partner-Assets fallen heraus: Die Suche umfasst sie, der lokale Bestand (und
    /// damit alles, was der Spiegel bisher hineinlegte) nicht.
    private func resolveOnServer(_ album: SmartAlbum) async -> SmartAlbumResolution? {
        guard let kinds = SmartAlbumServerQuery.requiredCatalogs(for: album.rules) else { return nil }
        do {
            var values: [SmartAlbumServerQuery.CatalogKind: [String]] = [:]
            for kind in kinds {
                if let cached = catalogCache[kind] {
                    values[kind] = cached
                } else {
                    let fetched = try await apiClient.searchSuggestions(type: kind.suggestionType)
                    catalogCache[kind] = fetched
                    values[kind] = fetched
                }
            }
            guard let filter = SmartAlbumServerQuery.filter(
                for: album.rules,
                matchMode: album.matchMode,
                catalog: SmartAlbumServerQuery.Catalog(values: values)
            ) else {
                AppLogger.app.info("SmartAlbumMirror '\(album.name)': Regeltext ohne Treffer im Serverkatalog — lokaler Weg")
                return nil
            }

            let userId: String
            if let cachedUserId {
                userId = cachedUserId
            } else {
                userId = try await apiClient.getMyUserId()
                cachedUserId = userId
            }

            let refs = try await apiClient.searchAllAssetRefs(filter: filter)
            let own = Set(refs.lazy.filter { $0.ownerId == userId }.map(\.id))
            AppLogger.app.info("SmartAlbumMirror '\(album.name)': Serverfilter → \(own.count) Treffer (\(refs.count - own.count) fremde verworfen)")
            return .resolved(own)
        } catch {
            return .skipped(reason: error.localizedDescription)
        }
    }

    /// Hat das Album mindestens eine Regel, die `resolveAllServerRules` **nicht**
    /// nachfüllen kann?
    ///
    /// Personenregeln zählen nicht dazu: Für sie holt der Dienst die Asset-IDs vom
    /// Server und lädt fehlende aus dem Grid-Index nach. Negierte Regeln zählen immer
    /// dazu — „gib mir alles, was *kein* Favorit ist" lässt sich nicht als
    /// Server-Filter stellen, das steht auch in `resolveAllServerRules` so.
    ///
    /// Alles andere hängt daran, ob `metadataServerFilters` einen Filter liefert.
    /// Genau diese Funktion entscheidet dort über das Nachfüllen — die Antwort hier
    /// wird also aus derselben Quelle abgeleitet und kann nicht auseinanderlaufen.
    func hasLocallyResolvedRule(_ album: SmartAlbum) -> Bool {
        album.rules.contains { entry in
            if case .containsPerson = entry.rule, !entry.isNegated { return false }
            if entry.isNegated { return true }
            return metadataServerFilters(for: entry.rule) == nil
        }
    }

    /// Kann der Schnellindex (`grid_assets`) diese Regel beantworten?
    ///
    /// **Positive Liste, absichtlich ohne `default`.** Eine neue Regel bricht hier den
    /// Bau, und wer sie hinzufügt, muss entscheiden — die Alternative (alles erlauben,
    /// was nicht ausdrücklich verboten ist) wäre nach außen wirksam: Aus dem Index
    /// geladene Assets tragen nur die 25 Spalten der Tabelle, alles andere ist `nil`.
    /// `fNumber`, `iso` und `stackId` fehlen dort etwa vollständig, und eine Regel
    /// darauf ergäbe für jedes Foto „trifft nicht zu".
    ///
    /// Zu beachten: **Jede negierte Regel gilt als lokal auswertbar** (siehe
    /// ``hasLocallyResolvedRule(_:)``) — auch eine wie „nicht Blende ≤ 2.0“, deren
    /// Feld der Index nicht führt. Deshalb wird hier die Regel selbst geprüft, nicht
    /// ihre Server-Entsprechung.
    nonisolated static func gridIndexCanCarry(_ rule: SmartAlbumRule) -> Bool {
        switch rule {
        // fileCreatedAt
        case .dateRange, .lastXDays, .monthOfYear, .yearIs:
            return true
        // city / country / latitude / longitude
        case .city, .country, .hasLocation, .hasNoLocation:
            return true
        // cameraMake / cameraModel
        case .cameraModel, .hasNoCameraInfo:
            return true
        // fileSizeInByte, type, isFavorite, width/height
        case .fileSizeMaxKB, .assetTypeIs, .isFavorite, .isPanorama:
            return true
        // originalFileName
        case .isRAW, .isScreenshot, .fileExtensionIs, .isWebOrMessenger:
            return true

        // Spalte fehlt im Index — `assetFromRow` lässt das Feld leer.
        case .fNumberMax, .isoMin:     return false   // kein fNumber / iso
        case .isStacked:               return false   // kein stackId
        // Braucht die Albumzugehörigkeit, nicht den Assetbestand (eigenes Tor in
        // `resolveTargetIds`).
        case .isInNoAlbum:             return false
        // Kommt vom Server, nicht aus dem Index.
        case .containsPerson:          return false
        }
    }

    // MARK: - Server Rule Resolution

    /// Resolves all rules that require server-side data:
    ///  - `containsPerson` → fetches asset IDs per person from the server
    ///  - EXIF rules (cameraModel, dateRange, yearIs, …) → metadata search
    ///
    /// Returns:
    ///  - enriched pool (basePool + any missing assets loaded from GridIndexStore)
    ///  - personAssetIdsByPerson map (for evaluator's AND/OR person logic)
    ///  - serverConfirmedIds (IDs confirmed by EXIF/metadata server queries)
    ///
    /// Wirft, wenn eine dieser Abfragen fehlschlägt. Ein Teilergebnis ist hier
    /// nicht brauchbar: der Aufrufer bildet daraus die Differenz zum Server-Album
    /// und würde fehlende IDs als "gehört nicht mehr rein" auffassen.
    private func resolveAllServerRules(
        for album: SmartAlbum,
        basePool: [Asset]
    ) async throws -> (pool: [Asset], personAssetIdsByPerson: [String: Set<String>], serverConfirmedIds: Set<String>) {

        var pool = basePool
        var knownIds = Set(basePool.map(\.id))
        var personAssetIdsByPerson: [String: Set<String>] = [:]
        var serverConfirmedIds: Set<String> = []

        // ── 1. Person rules ──────────────────────────────────────────────────
        // GridIndexStore doesn't store people — we must fetch per-person asset IDs
        // from the server, then gap-fill missing assets from the index.
        let personIds: [String] = album.rules.compactMap {
            if case .containsPerson(let id, _) = $0.rule { return id }
            return nil
        }

        if !personIds.isEmpty {
            try await withThrowingTaskGroup(of: (String, [String]).self) { group in
                for personId in personIds {
                    group.addTask { [apiClient] in
                        let assets = try await apiClient.getPersonAssets(id: personId)
                        return (personId, assets.map(\.id))
                    }
                }
                for try await (personId, ids) in group {
                    personAssetIdsByPerson[personId] = Set(ids)
                }
            }

            // Gap-fill: load person assets that aren't in the base pool
            let allPersonIds = personAssetIdsByPerson.values.reduce(into: Set<String>()) { $0.formUnion($1) }
            let missingPersonIds = Array(allPersonIds.subtracting(knownIds))

            if !missingPersonIds.isEmpty {
                AppLogger.app.info("SmartAlbumMirror '\(album.name)': loading \(missingPersonIds.count) person asset(s) from GridIndexStore")
                let fromIndex = await Task.detached(priority: .utility) {
                    GridIndexStore.shared.loadVisible(ids: missingPersonIds)
                }.value
                let newAssets = fromIndex.filter { !knownIds.contains($0.id) }
                pool.append(contentsOf: newAssets)
                newAssets.forEach { knownIds.insert($0.id) }
                AppLogger.app.info("SmartAlbumMirror '\(album.name)': resolved \(newAssets.count)/\(missingPersonIds.count) person assets")
            }
        }

        // ── 2. EXIF / metadata rules ─────────────────────────────────────────
        // SyncAssets carry no EXIF → cameraModel etc. can only be resolved via
        // the server's metadata search API.
        // Nur cameraModel-Abfragen dürfen den lokalen EXIF-Check bypassen
        // (SyncAsset trägt kein EXIF). Andere Regeln (isFavorite, dateRange, …)
        // werden lokal korrekt aufgelöst — ihre IDs dürfen nicht in
        // serverConfirmedIds landen, sonst entstehen falsch-positive Matches.
        for entry in album.rules {
            // Negated rules cannot be resolved via server metadata filter (we cannot
            // ask the server "give me assets that are NOT favorites"). They are handled
            // locally by SmartAlbumEvaluator which applies the negation flag.
            guard !entry.isNegated else { continue }
            guard let filters = metadataServerFilters(for: entry.rule) else { continue }
            let assets = try await apiClient.searchAllAssets(filter: filters)
            AppLogger.app.info("SmartAlbumMirror '\(album.name)': metadata filter \(entry.rule.displayLabel) → \(assets.count) asset(s)")
            let ids = Set(assets.map(\.id))
            // Gap-fill: alle geholten IDs in den Pool aufnehmen
            // Bypass: nur cameraModel-IDs → serverConfirmedIds
            if case .cameraModel = entry.rule {
                serverConfirmedIds.formUnion(ids)
            }
            // Wir müssen die IDs trotzdem für Gap-fill verarbeiten → temporär als knownIds-Kandidaten
            let missingIds = Array(ids.subtracting(knownIds))
            if !missingIds.isEmpty {
                let fromIndex = await Task.detached(priority: .utility) {
                    GridIndexStore.shared.loadVisible(ids: missingIds)
                }.value
                let newAssets = fromIndex.filter { !knownIds.contains($0.id) }
                pool.append(contentsOf: newAssets)
                newAssets.forEach { knownIds.insert($0.id) }
            }
        }



        return (pool, personAssetIdsByPerson, serverConfirmedIds)
    }

    /// Übersetzt eine Einzelregel in den Filter, mit dem der lokale Weg fehlende Assets
    /// nachfüllt — `nil` für Regeln, die anders aufgelöst werden (Person, Ort, EXIF-Details,
    /// Monat, RAW/Screenshot/Panorama).
    ///
    /// Dieselben Standards wie die alte flache Suche, die hier bis Sept. 2026 lief: nur
    /// `trashedAt: null`, keine Sichtbarkeitsbedingung (die alte nahm alles außer
    /// `locked`), Zeiträume inklusive (`takenAfter` war `>=`, `takenBefore` `<=`), das
    /// Kameramodell exakt.
    func metadataServerFilters(for rule: SmartAlbumRule) -> SearchFilter? {
        var filter = SearchFilter()
        filter.trashedAt = .isNull
        switch rule {
        case .cameraModel(let model):
            filter.model = .equals(model)

        case .dateRange(let from, let to):
            filter.takenAt = .dateRange(from: from, to: to)

        case .lastXDays(let x):
            // Dieselbe Grenze wie die lokale Auswertung — sonst holt der Server ein
            // engeres Fenster, als die Regel meint, und die Differenz gegen das
            // Server-Album entfernt Fotos, die dort hingehören.
            filter.takenAt = .onOrAfter(SmartAlbumEvaluator.lastXDaysCutoff(x))

        case .yearIs(let year):
            var comps = DateComponents()
            comps.year = year; comps.month = 1; comps.day = 1
            let cal = Calendar.current
            guard let start = cal.date(from: comps),
                  let end   = cal.date(byAdding: .year, value: 1, to: start) else { return nil }
            filter.takenAt = .between(start, andIncluding: end)

        case .assetTypeIs(let t):
            filter.type = .equals(t)

        case .isFavorite:
            filter.isFavorite = .equals(true)

        // Person, Ort, EXIF-Details, month, RAW/Screenshot/Panorama → kein Server-Filter hier
        default:
            return nil
        }
        return filter
    }

    /// Creates a new server album and links it as mirror. Returns false on failure.
    func enableMirror(
        for album: SmartAlbum,
        allAssets: [Asset],
        personAssetIdsByPerson: [String: Set<String>],
        poolIsComplete: Bool = true,
        mirroredAlbumIds: Set<String> = []
    ) async -> Bool {
        do {
            let serverAlbum = try await apiClient.createAlbum(name: "✦ \(album.name)")
            album.mirrorAlbumId    = serverAlbum.id
            album.mirrorSyncStatus = .idle
            album.mirrorLastError  = nil
            // First sync immediately
            await sync(album: album, allAssets: allAssets,
                       personAssetIdsByPerson: personAssetIdsByPerson,
                       poolIsComplete: poolIsComplete,
                       mirroredAlbumIds: mirroredAlbumIds)
            return true
        } catch {
            AppLogger.app.error("SmartAlbumMirror enableMirror '\(album.name)' failed: \(error)")
            return false
        }
    }

    /// Detaches the mirror link without touching the server album.
    func disableMirror(for album: SmartAlbum, deleteServerAlbum: Bool) async {
        guard let mirrorId = album.mirrorAlbumId else { return }
        if deleteServerAlbum {
            try? await apiClient.deleteAlbum(id: mirrorId)
        }
        album.mirrorAlbumId           = nil
        album.mirrorLastSyncedAt      = nil
        album.mirrorLastSyncedIds     = []
        album.mirrorSyncStatus        = .idle
        album.mirrorLastError         = nil
    }
}

// MARK: - Array chunking helper

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
