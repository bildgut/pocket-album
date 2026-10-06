import Foundation

/// Evaluates SmartAlbumRules against an in-memory Asset array.
/// Pure, dependency-free, easy to unit-test.
enum SmartAlbumEvaluator {

    /// Untergrenze der Regel `lastXDays` — **die** Stelle, an der sie berechnet wird.
    ///
    /// Maßgeblich ist der **Tagesbeginn**, nicht der Zeitpunkt vor X Tagen: „die
    /// letzten 30 Tage" soll über den Tag hinweg dieselbe Menge bezeichnen und nicht
    /// mit jeder Stunde vorne abschmelzen.
    ///
    /// Zuvor rechnete `SmartAlbumMirrorService.metadataServerFilters` dieselbe Grenze
    /// ein zweites Mal — **ohne** `startOfDay`. Die beiden Fenster liefen dadurch über
    /// den Tag um bis zu 24 Stunden auseinander und sprangen um Mitternacht wieder
    /// zusammen. Für ein gespiegeltes Album hieß das: Ein Foto vom Stichtag lag
    /// morgens im vom Server geholten Pool und abends nicht — es wurde also
    /// abwechselnd ins echte Immich-Album gelegt und wieder daraus entfernt.
    ///
    /// - Parameter now: nur für Tests; im Betrieb immer die aktuelle Zeit.
    static func lastXDaysCutoff(_ days: Int, now: Date = Date()) -> Date {
        let cal = Calendar.current
        return cal.startOfDay(for: cal.date(byAdding: .day, value: -days, to: now) ?? now)
    }


    /// Der ganze lokale Tag als Bereich für `.dateRange` — **die** Stelle, an der aus
    /// einem Datum eine Spanne wird.
    ///
    /// `SearchView` baute hier `.dateRange(from: d, to: d)` mit `d` = lokale
    /// Mitternacht. Die Regel prüft `d >= from && d <= to`, traf also nur ein Asset auf
    /// genau dieser Millisekunde: Wer nach einem Datum suchte und das Ergebnis als Smart
    /// Album speicherte, bekam ein **leeres** Album — bei einem gespiegelten Album heißt
    /// das, es wird auf dem Server leergeräumt.
    ///
    /// Die Live-Suche derselben Ansicht machte es richtig
    /// (`Calendar.current.isDate(_:inSameDayAs:)`); diese Fassung bildet sie nach.
    static func dayRange(for date: Date, calendar: Calendar = .current) -> (from: Date, to: Date) {
        let start = calendar.startOfDay(for: date)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        // Eine Millisekunde vor dem nächsten Tag: `createdDate` löst nicht feiner auf.
        return (start, nextDay.addingTimeInterval(-0.001))
    }

    /// Das ganze lokale Jahr als Bereich für `.dateRange`.
    ///
    /// `SearchView` setzte das Ende auf den 31. Dezember um **00:00** — alles, was an
    /// Silvester nach Mitternacht aufgenommen wurde, fiel heraus. Die Live-Suche
    /// derselben Ansicht vergleicht dagegen `component(.year)` und nimmt den ganzen Tag.
    static func yearRange(for year: Int, calendar: Calendar = .current) -> (from: Date, to: Date)? {
        guard let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
              let lastDay = calendar.date(from: DateComponents(year: year, month: 12, day: 31))
        else { return nil }
        return (calendar.startOfDay(for: start), dayRange(for: lastDay, calendar: calendar).to)
    }

    /// Returns the subset of `assets` that match the smart album's rules.
    /// `personAssetIdsByPerson` — maps personId → Set of assetIds fetched from the server.
    /// `serverConfirmedIds` — asset IDs the server confirmed for a rule (e.g. cameraModel).
    ///   For assets in this set, any rule whose server-side filter produced the ID is
    ///   treated as satisfied, bypassing the local EXIF check (which would fail because
    ///   SyncAsset carries no EXIF data).
    /// - Parameter exifUncheckedIds: Asset-IDs, für die der Server noch nie nach EXIF
    ///   gefragt wurde. Deren EXIF-Felder sagen nichts aus: `latitude == nil` heißt dort
    ///   „unbekannt", nicht „kein GPS". Die Regeln `hasLocation`, `hasNoLocation`,
    ///   `hasNoCameraInfo`, das PNG-Kriterium von `isScreenshot` und das EXIF-Kriterium
    ///   von `isWebOrMessenger` liefern für sie „unbekannt" (`nil` aus `matches`) — und
    ///   „unbekannt" ist nie ein Treffer, auch nicht negiert (siehe `satisfies`).
    /// - Parameter assetIdsInAnyAlbum: Asset-IDs, die in mindestens einem Album stehen
    ///   (aus ``AlbumMembershipStore/assetIdsInAnyAlbum(excludingAlbumIds:)``, die
    ///   Spiegel-Alben ausgenommen). `nil` heißt „Album-Index deckt nicht alle Alben ab"
    ///   — `isInNoAlbum` liefert dann „unbekannt", nie ein leeres Set unterstellen.
    static func evaluate(
        _ album: SmartAlbum,
        against assets: [Asset],
        personAssetIdsByPerson: [String: Set<String>] = [:],
        serverConfirmedIds: Set<String> = [],
        exifUncheckedIds: Set<String> = [],
        assetIdsInAnyAlbum: Set<String>? = nil
    ) -> [Asset] {
        let entries = album.rules
        guard !entries.isEmpty else { return [] }

        let matched = assets.filter { asset in
            switch album.matchMode {
            case .all: return entries.allSatisfy { satisfies(entry: $0, asset: asset, personAssetIdsByPerson: personAssetIdsByPerson, serverConfirmedIds: serverConfirmedIds, exifUncheckedIds: exifUncheckedIds, assetIdsInAnyAlbum: assetIdsInAnyAlbum) }
            case .any: return entries.contains   { satisfies(entry: $0, asset: asset, personAssetIdsByPerson: personAssetIdsByPerson, serverConfirmedIds: serverConfirmedIds, exifUncheckedIds: exifUncheckedIds, assetIdsInAnyAlbum: assetIdsInAnyAlbum) }
            }
        }

        return sorted(matched, by: album.sortOrder)
    }

    // MARK: - Preview count (for live counter in editor)
    // Person rules are skipped here — they need a server round-trip that the
    // editor does not do. The real count appears once the Detail View loads.

    static func previewCount(_ entries: [SmartAlbumRuleEntry],
                             matchMode: SmartAlbumMatchMode,
                             against assets: [Asset],
                             exifUncheckedIds: Set<String> = [],
                             assetIdsInAnyAlbum: Set<String>? = nil) -> Int {
        guard !entries.isEmpty else { return 0 }
        let localEntries = entries.filter {
            if case .containsPerson = $0.rule { return false }
            return true
        }
        guard !localEntries.isEmpty else { return 0 }
        return assets.filter { asset in
            switch matchMode {
            case .all: return localEntries.allSatisfy { satisfies(entry: $0, asset: asset, personAssetIdsByPerson: [:], exifUncheckedIds: exifUncheckedIds, assetIdsInAnyAlbum: assetIdsInAnyAlbum) }
            case .any: return localEntries.contains   { satisfies(entry: $0, asset: asset, personAssetIdsByPerson: [:], exifUncheckedIds: exifUncheckedIds, assetIdsInAnyAlbum: assetIdsInAnyAlbum) }
            }
        }.count
    }

    // MARK: - Entry evaluator (applies negation)

    /// `matches` ist dreiwertig: `nil` heißt „unbekannt", nicht „nein". Ein
    /// „unbekannt" wird hier zu „kein Treffer" — **unabhängig von `isNegated`**.
    /// Was wir nicht wissen, trifft nie, weder direkt noch negiert.
    ///
    /// Der Grund: Die gegateten Regeln (`hasLocation`, `hasNoLocation`,
    /// `hasNoCameraInfo`, `isScreenshot`, das EXIF-Kriterium von `isWebOrMessenger`)
    /// lieferten für ungeprüftes EXIF früher
    /// `false`. Die Negation drehte dieses `false` zu `true` um — ein Album
    /// „Nicht: Kein GPS" sammelte damit die gesamte ungeprüfte Menge ein (in der
    /// echten Bibliothek über 13.000 Assets, bei nicht lesbarem Grid-Index sogar
    /// alle 155.000, weil `SmartAlbumDetailView.refreshExifGate` dann konservativ
    /// den ganzen Pool als ungeprüft führt). Mit `nil` gibt es kein `false` mehr,
    /// das sich umdrehen ließe.
    private static func satisfies(entry: SmartAlbumRuleEntry, asset: Asset,
                                  personAssetIdsByPerson: [String: Set<String>],
                                  serverConfirmedIds: Set<String> = [],
                                  exifUncheckedIds: Set<String>,
                                  assetIdsInAnyAlbum: Set<String>? = nil) -> Bool {
        guard let result = matches(rule: entry.rule, asset: asset,
                                   personAssetIdsByPerson: personAssetIdsByPerson,
                                   serverConfirmedIds: serverConfirmedIds,
                                   exifUncheckedIds: exifUncheckedIds,
                                   assetIdsInAnyAlbum: assetIdsInAnyAlbum)
        else { return false }
        return entry.isNegated ? !result : result
    }

    // MARK: - Single-rule matcher

    /// Dreiwertig: `true` = Treffer, `false` = sicher kein Treffer, `nil` = unbekannt.
    /// `nil` liefern nur die Regeln, die auf EXIF angewiesen sind (siehe
    /// `usesExifDependentRule`), und auch nur
    /// für Assets, deren EXIF nie beim Server erfragt wurde. Alle übrigen Regeln
    /// bleiben zweiwertig — Swift hebt ihr `Bool` automatisch nach `Bool?`, sie
    /// mussten dafür nicht angefasst werden.
    private static func matches(rule: SmartAlbumRule, asset: Asset,
                                personAssetIdsByPerson: [String: Set<String>],
                                serverConfirmedIds: Set<String>,
                                exifUncheckedIds: Set<String>,
                                assetIdsInAnyAlbum: Set<String>?) -> Bool? {
        // Ob die EXIF-Felder dieses Assets überhaupt etwas aussagen.
        let exifIsAuthoritative = !exifUncheckedIds.contains(asset.id)

        switch rule {

        // Zeit
        case .dateRange(let from, let to):
            guard let d = asset.createdDate else { return false }
            return d >= from && d <= to

        case .lastXDays(let x):
            guard let d = asset.createdDate else { return false }
            return d >= Self.lastXDaysCutoff(x)

        case .monthOfYear(let month):
            guard let d = asset.createdDate else { return false }
            return Calendar.current.component(.month, from: d) == month

        case .yearIs(let year):
            guard let d = asset.createdDate else { return false }
            return Calendar.current.component(.year, from: d) == year

        // Person
        // GridIndexStore does not store people data — resolved via server-fetched IDs.
        // Lookup is per-personId so that matchMode=.all correctly requires
        // each person to appear in the asset independently (true AND).
        case .containsPerson(let personId, _):
            return personAssetIdsByPerson[personId]?.contains(asset.id) ?? false

        // Ort
        // Bewusst **nicht** gegatet — hier und bei country/cameraModel/fNumberMax/isoMin.
        // Diese Wertregeln haben dieselbe Struktur wie hasLocation in schwächerer
        // Ausprägung: Bei ungeprüftem EXIF liefern sie „trifft nicht", was negiert zu
        // einem Treffer wird. Der Unterschied ist die Blastradius-Frage — „Nicht:
        // Stadt = Berlin" ist eine seltene, gezielte Formulierung, während „Nicht: Hat
        // GPS" die naheliegende Art ist, „ohne Ort" auszudrücken. Ein Gate zöge zudem
        // das Hinweisband auf deutlich mehr Alben. Entscheidung des Controllers für
        // diese Nachbesserung; als offener Punkt für den Abschluss-Review notiert. Die
        // Asymmetrie zu hasLocation direkt darunter ist also Absicht, kein Versehen.
        case .city(let city):
            return asset.exifInfo?.city?.localizedCaseInsensitiveCompare(city) == .orderedSame

        case .country(let country):
            return asset.exifInfo?.country?.localizedCaseInsensitiveCompare(country) == .orderedSame

        case .hasLocation:
            // Spiegelbild von hasNoLocation: Ungeprüft heißt unbekannt. Ohne dieses Gate
            // lieferte die Regel für die ungeprüfte Menge `false`, das die Negation zu
            // `true` drehte — „Nicht: Hat GPS" sammelte damit alles ein, wonach nie
            // gefragt wurde, und der Mirror-Dienst lud es per PUT ins echte Album.
            // Unnegiert ändert das Gate nichts: `false` und `nil` sind beide kein Treffer.
            guard exifIsAuthoritative else { return nil }
            return asset.exifInfo?.latitude != nil

        case .hasNoLocation:
            // Ungeprüft heißt unbekannt, nicht „kein GPS" — und unbekannt trifft nie,
            // auch nicht negiert (siehe `satisfies`).
            guard exifIsAuthoritative else { return nil }
            return asset.exifInfo?.latitude == nil && asset.exifInfo?.longitude == nil

        // Kamera / EXIF
        // SyncAsset enthält kein EXIF → exifInfo.model ist nil für die meisten Assets.
        // Wenn der Server das Asset via „model"-Filter bestätigt hat, gilt es als Match.
        case .cameraModel(let model):
            if serverConfirmedIds.contains(asset.id) { return true }
            guard let m = asset.exifInfo?.model else { return false }
            return m.localizedCaseInsensitiveContains(model)

        case .fNumberMax(let maxF):
            guard let f = asset.exifInfo?.fNumber else { return false }
            return f <= maxF

        case .isoMin(let minISO):
            guard let iso = asset.exifInfo?.iso else { return false }
            return iso >= Double(minISO)

        // Typ & Status
        case .assetTypeIs(let t):
            return asset.type == t

        case .isFavorite:
            return asset.isFavorite

        case .isRAW:
            // Die Liste stand hier wörtlich und war die dritte im Code — `MIMEType`
            // wurde gerade angelegt, weil zwei solche Listen auseinandergelaufen
            // waren, und diese hier war es auch: `raw` konnte hochgeladen werden und
            // galt der Regel trotzdem nicht als RAW.
            // Über `MediaType.isRawFile`, nicht über eine eigene Prüfung: Die sieht auch
            // den Originalpfad an — Immich behält den ursprünglichen Dateinamen nicht
            // immer. Ohne das antwortete die Medienart „RAW" anders als diese Regel.
            return MediaType.isRawFile(fileName: asset.originalFileName, path: asset.originalPath)

        case .isScreenshot:
            // Der Detektor erkennt PNGs unter anderem an fehlenden Kamerafeldern, wertet
            // also EXIF aus. Ungegatet landete „familie.png" (echtes Foto, EXIF nie
            // erfragt) im Album „Bildschirmfotos"; negiert wäre derselbe Fall
            // spiegelverkehrt gelandet. Namensmuster bleiben auch ungeprüft ein
            // sicheres Ja — nur der PNG-Fall liefert „unbekannt".
            return ScreenshotDetector.isScreenshot(asset, exifIsAuthoritative: exifIsAuthoritative)

        case .isPanorama:
            // Dieselbe Fassung wie die Medienart „Panoramen". Hier stand sie ein
            // zweites Mal, ohne den Pfad — für dasselbe Foto kamen zwei Antworten.
            return MediaType.isPanorama(
                fileName: asset.originalFileName,
                path: asset.originalPath,
                width: asset.effectiveWidth,
                height: asset.effectiveHeight
            )

        case .isStacked:
            return asset.isStacked

        case .hasNoCameraInfo:
            // Wie hasNoLocation: „keine Kamera-Daten vorhanden" ist ohne EXIF-Prüfung
            // nicht von „nie gefragt" zu unterscheiden.
            guard exifIsAuthoritative else { return nil }
            let make  = (asset.exifInfo?.make ?? "").trimmingCharacters(in: .whitespaces)
            let model = (asset.exifInfo?.model ?? "").trimmingCharacters(in: .whitespaces)
            return make.isEmpty && model.isEmpty

        case .fileSizeMaxKB(let maxKB):
            // Kein eigenes Gate nötig — aber nicht, weil ungeprüfte Assets hier
            // zuverlässig nil hätten (das stimmt nicht: exifCheckedAt wird von
            // GridIndexStore.markExifChecked gesetzt (aufgerufen von ExifRepairModel
            // und upsertFromExifFetch) oder direkt von GridIndexStore.updateExifFromSync
            // (AssetExifsV1 im Sync-Stream); AssetRepository und MainView schreiben
            // fileSizeInByte über GridIndexStore.upsert(_ assets:), ohne zu markieren
            // — ein Asset kann also
            // gesetztes fileSizeInByte tragen und trotzdem in exifUncheckedIds stehen).
            // Der eigentliche Grund: fileSizeInByte wird nie geschätzt, sondern kommt
            // immer aus einer echten Server-EXIF-Antwort (upsert, upsertFromCache,
            // writeExifV8). Nicht-nil ist deshalb immer autoritativ, unabhängig vom
            // Gate-Status. Achtung: schreibt künftiger Code eine geschätzte Größe in
            // diese Spalte, wird diese Regel still falsch.
            guard let bytes = asset.exifInfo?.fileSizeInByte else { return false }
            return bytes <= maxKB * 1024

        case .fileExtensionIs(let ext):
            let actual = (asset.originalFileName as NSString).pathExtension.lowercased()
            return actual == ext.lowercased()

        case .isWebOrMessenger:
            return WebOriginDetector.isWebOrMessenger(asset, exifIsAuthoritative: exifIsAuthoritative)

        case .isInNoAlbum:
            // `nil` = Album-Index deckt nicht alle Alben ab → unbekannt, nie ein
            // Treffer (auch nicht negiert). Ein leeres Set ist dagegen eine echte
            // Antwort: kein Asset steht in irgendeinem Album.
            guard let assetIdsInAnyAlbum else { return nil }
            return !assetIdsInAnyAlbum.contains(asset.id)
        }
    }

    // MARK: - EXIF-Gate

    /// Ob mindestens eine Regel des Albums von EXIF-Daten abhängt und deshalb das
    /// Gate (`exifUncheckedIds`) braucht.
    ///
    /// `fileSizeMaxKB` steht bewusst mit in der Liste, obwohl die Regel selbst nicht
    /// gegatet ist: Ihre Werte stammen aus denselben Server-EXIF-Antworten, die auch
    /// das Gate füllt, und bei ungeprüften Assets fehlt die Größe schlicht. Ein Album
    /// mit dieser Regel ist also ebenfalls unvollständig und soll das Hinweisband
    /// bekommen.
    ///
    /// Liegt hier statt in der View, weil es reine Logik ohne SwiftUI-Bezug ist und
    /// damit direkt testbar bleibt.
    ///
    /// Der `switch` ist bewusst erschöpfend statt mit `default: return false`: Eine neue
    /// Regel soll den Compiler auf den Plan rufen und eine Einordnung erzwingen. Mit dem
    /// `default` wäre sie stillschweigend als „braucht kein EXIF" durchgerutscht — genau
    /// so fehlten `hasLocation` und `isScreenshot` in dieser Liste, obwohl beide gegatet
    /// auswerten, und ihre Alben blieben ohne Hinweisband unvollständig.
    static func usesExifDependentRule(_ entries: [SmartAlbumRuleEntry]) -> Bool {
        entries.contains { entry in
            switch entry.rule {
            case .hasLocation, .hasNoLocation, .hasNoCameraInfo,
                 .isScreenshot, .isWebOrMessenger, .fileSizeMaxKB:
                return true

            // Nicht gegatet und deshalb ohne Hinweisband. Darunter auch city/country/
            // cameraModel/fNumberMax/isoMin, die zwar EXIF lesen, aber bewusst
            // ungegatet bleiben (siehe Begründung an `.city` in `matches`) — käme das
            // Gate dazu, gehörten sie hier nach oben.
            case .dateRange, .lastXDays, .monthOfYear, .yearIs,
                 .containsPerson,
                 .city, .country,
                 .cameraModel, .fNumberMax, .isoMin,
                 .assetTypeIs, .isFavorite, .isRAW, .isPanorama, .isStacked,
                 .fileExtensionIs, .isInNoAlbum:
                return false
            }
        }
    }

    // MARK: - Album-Mitgliedschafts-Gate

    /// Ob mindestens eine Regel des Albums den lokalen Album-Index braucht
    /// (`assetIdsInAnyAlbum`). Trifft auch negierte Einträge — „Nicht: In keinem
    /// Album" braucht das Set genauso wie die unnegierte Form.
    static func usesAlbumMembershipRule(_ entries: [SmartAlbumRuleEntry]) -> Bool {
        entries.contains { entry in
            if case .isInNoAlbum = entry.rule { return true }
            return false
        }
    }

    /// Warum das EXIF-Gate greift — bzw. warum es das nicht verlässlich kann.
    ///
    /// Dreiwertig statt eines `Bool`, weil die beiden Störfälle für den Nutzer
    /// Verschiedenes bedeuten: Ein nicht lesbarer Index ist ein Defekt; ein noch
    /// laufender Backfill gibt sich von selbst. Die Oberfläche formuliert deshalb
    /// unterschiedlich und bietet nur im ersten Fall die Reparatur an.
    enum ExifGateStatus: Equatable {
        /// Der Index konnte den EXIF-Status beantworten, `uncheckedIds` ist exakt.
        case ready
        /// `idsMissingExifCheck` lieferte `nil` — der Grid-Index ist nicht lesbar.
        case indexUnreadable
        /// Der einmalige v8-Backfill ist noch nicht durch; der Index antwortet zwar,
        /// aber nicht belastbar (siehe `GridIndexStore.exifV8BackfillComplete`).
        case backfillPending
    }

    /// Übersetzt die Antwort von `GridIndexStore.idsMissingExifCheck` in den Zustand,
    /// den `evaluate` und das Hinweisband brauchen.
    ///
    /// Zwei Fälle führen auf dieselbe konservative Antwort — der gesamte Pool gilt als
    /// ungeprüft, also lieber zu wenige als falsche Treffer:
    ///
    /// 1. `backfillComplete == false`: Solange der einmalige v8-Backfill nicht durch ist,
    ///    gilt die Invariante „`exifCheckedAt IS NOT NULL` ⟹ EXIF-Spalten autoritativ"
    ///    nicht. Der Index *antwortet* dann, aber seine Antwort taugt nichts: Zeilen mit
    ///    Prüfzeitpunkt und leeren Spalten gelten als geprüft, und „hat kein GPS" träfe
    ///    fast die ganze Bibliothek. Dieser Fall hat Vorrang vor Fall 2 — er ist der,
    ///    der sich von selbst gibt, und soll auch so gemeldet werden.
    /// 2. `missingIds == nil`: Grid-Index nicht lesbar, nicht „nichts offen". Als leere
    ///    Menge gelesen wäre das Gate wirkungslos: die „hat kein X"-Regeln träfen wieder
    ///    jedes Asset ohne GPS/Kamera-Info, obwohl niemand geprüft hat, ob der Server je
    ///    danach gefragt wurde.
    ///
    /// Liegt hier statt in der View, damit diese konservative Abbildung dauerhaft von
    /// Tests abgedeckt ist.
    static func resolveExifGate(from missingIds: [String]?, poolIds: [String], backfillComplete: Bool)
    -> (uncheckedIds: Set<String>, status: ExifGateStatus) {
        guard backfillComplete else { return (Set(poolIds), .backfillPending) }
        guard let missingIds else { return (Set(poolIds), .indexUnreadable) }
        return (Set(missingIds), .ready)
    }

    // MARK: - Sorting

    /// Die Reihenfolge eines Smart Albums — auch für Treffer, die direkt vom Server
    /// kommen (`SmartAlbumDetailModel`), damit beide Wege gleich sortieren.
    static func sorted(_ assets: [Asset], by order: SmartAlbumSortOrder) -> [Asset] {
        switch order {
        case .dateDesc: return assets.sorted { $0.fileCreatedAt > $1.fileCreatedAt }
        case .dateAsc:  return assets.sorted { $0.fileCreatedAt < $1.fileCreatedAt }
        case .nameAsc:  return assets.sorted { $0.originalFileName < $1.originalFileName }
        }
    }
}
