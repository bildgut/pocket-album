import SwiftUI
import SwiftData

/// Wurzel-Weiche des iOS-Clients.
///
/// Angelehnt an `ContentView` auf dem Mac
/// (`Sources/ImmichMac/Views/ContentView.swift:8-50`): verbunden mit
/// `apiClient` → Inhalt; sonst Setup. Dazwischen aber **feiner** als dort —
/// ein eigener Zweig für "verbindet gerade" (`.connecting` oder die kurze
/// async-Lücke bis zum `AlbumManager`) und ein weiterer für "Server nicht
/// erreichbar, aber Zugangsdaten vorhanden" (`.disconnected`/`.error(_)` bei
/// `isConfigured == true`). Der Grund für die zusätzliche Unterscheidung
/// steht am jeweiligen Zweig unten. Die Mac-eigenen Zweige (Offline-Banner,
/// Deep-Link, Fenstertitel) fehlen bewusst — ein Fenster gibt es hier
/// grundsätzlich nicht, und einen eigenen Offline-Banner-Zweig braucht diese
/// Weiche auch mit dem Offline-Pfad aus diesem PR nicht: Der lebt im Raster
/// selbst (`PhoneAlbumGridView`s Abschnitt "Auf dem Telefon"), nicht hier an
/// der Wurzel.
struct PhoneRootView: View {

    @Environment(ConnectionManager.self) private var connection
    @Environment(\.modelContext) private var modelContext

    /// Gehört dieser Ansicht, nicht `PhoneAlbumListView` — die zeigt nur an.
    /// Aufgebaut wie `LibraryViewModel.init` / `.configure(modelContext:)` auf
    /// dem Mac (`Sources/ImmichMac/ViewModels/LibraryViewModel.swift:36-47`):
    /// `apiClient` in den Initializer, `modelContext` erst danach per
    /// `configure(modelContext:)`, weil beides zu unterschiedlichen Zeitpunkten
    /// verfügbar wird.
    @State private var albumManager: AlbumManager?

    /// Wird erst wahr, nachdem der erste `loadAlbums()`-Durchlauf zurückgekehrt
    /// ist. `AlbumManager` selbst führt kein Lade-Flag — die Unterscheidung
    /// "noch nichts geladen" vs. "Server kennt keine Alben" muss also hier in
    /// der Ansicht entstehen, nicht im geteilten Kern.
    @State private var hasLoadedOnce = false

    /// Offline-Abzeichen aller Alben, gespiegelt aus `OfflinePinStore`. Gehört
    /// hierhin (nicht ins Raster selbst): Beide Zweige, die das Raster zeigen
    /// könnten — aktuell nur `canBrowse` — teilen sich dasselbe Modell, statt
    /// bei jedem Zweigwechsel ein neues aufzubauen und dabei den Zustand zu
    /// verlieren.
    @State private var offline = PhoneOfflineModel()

    /// Wärmt die Titelbilder aller Alben in den Nuke-Disk-Cache, sobald
    /// `loadAlbums()` zurückkehrt — siehe `PhoneCoverPrefetcher.swift`. Lebt
    /// hier (nicht im `AlbumManager`): Er braucht `connection.imagePipeline`,
    /// das der `AlbumManager` selbst nicht kennt.
    @State private var coverPrefetcher: PhoneCoverPrefetcher?

    /// Zustand des zweiten Reiters. Liegt hier und nicht in
    /// `PhonePhotoFeedView`, damit ein Reiterwechsel weder die geladenen Seiten
    /// noch die Scrollposition verliert — dieselbe Überlegung wie beim
    /// `offline`-Modell oben. Anders als der `AlbumManager` wird er bei einem
    /// Serverwechsel **nicht** hier ersetzt: `PhonePhotoFeed` merkt sich die
    /// Basis-URL selbst und verwirft seine Seiten, sobald `ladeFallsNoetig`
    /// eine andere sieht (siehe dort) — er hält, anders als `AlbumManager`,
    /// gar keinen eigenen Client.
    @State private var photoFeed = PhonePhotoFeed()

    /// Zustand des Orte-Reiters — aus demselben Grund hier wie `photoFeed`: Ein
    /// Reiterwechsel soll Katalog, Auswahl und geladene Seiten nicht verwerfen.
    /// `PhoneOrtsModell` merkt sich die Basis-URL selbst und liest bei einem
    /// Serverwechsel den passenden Katalog.
    @State private var orte = PhoneOrtsModell()

    /// Der aktive Reiter. Nur nötig, um einen **erneuten** Tipp auf „Orte" zu erkennen
    /// (`PhoneReiterWahl`): Der Setter der Bindung unten sieht den alten und den
    /// getippten Reiter, eine `TabView` ohne Auswahl meldet solche Tipps gar nicht.
    @State private var reiter: PhoneReiter = .alben

    /// Gesetzt von ``PhoneModelContainer/shared``, wenn der Store beim Start nicht
    /// aufging und ersetzt wurde. Das Schließen des Hinweises setzt ihn zurück.
    @AppStorage(PhoneModelContainer.storeZurueckgesetztKey) private var storeZurueckgesetzt = false

    var body: some View {
        Group {
            if connection.state.canBrowse, let client = connection.apiClient, let albumManager {
                // Aus „zeigt unmittelbar das Albumraster" wird „zeigt Alben und
                // Fotos als Reiter" — an der Verdrahtung des Albumreiters
                // (Verbindungsweiche oben, `hasLoadedOnce`, der
                // `onRefresh`-Durchgriff) ändert sich dabei nichts.
                TabView(selection: Binding(
                    get: { reiter },
                    set: { getippt in
                        if PhoneReiterWahl.setztEntdeckenZurueck(aktuell: reiter, getippt: getippt) {
                            Task { await orte.waehle(.leer, apiClient: client) }
                        }
                        reiter = getippt
                    }
                )) {
                    Tab("Albums", systemImage: "square.stack", value: PhoneReiter.alben) {
                        PhoneAlbumGridView(
                            albumManager: albumManager,
                            offline: offline,
                            hasLoadedOnce: hasLoadedOnce,
                            onRefresh: {
                                // Derselbe Dreischritt wie beim Erstaufbau unten
                                // (`setUpAlbumManagerIfNeeded()`), nur einmal
                                // definiert in `reloadAlbumsAndWarmCovers(manager:
                                // apiClient:)` — sonst würde der Aktualisieren-Zug
                                // den Vorwärmer umgehen, wie der Befund aus der
                                // vorigen Prüfung zeigte.
                                await reloadAlbumsAndWarmCovers(manager: albumManager, apiClient: client)
                            }
                        )
                    }
                    Tab("Photos", systemImage: "photo.on.rectangle", value: PhoneReiter.fotos) {
                        PhonePhotoFeedView(feed: photoFeed, apiClient: client)
                    }
                    // Dritter Reiter: Suche und Einstiege (Personen, Orte, Jahre). Neben
                    // „Fotos“, weil beide dasselbe Raster teilen (`PhoneFeedRaster`). Ein
                    // erneuter Tipp auf den aktiven Reiter führt zur Startseite zurück
                    // (siehe die Auswahl-Bindung oben). Smart Alben sind seit September
                    // 2026 kein eigener Reiter mehr, sondern ein Abschnitt im Alben-Reiter.
                    Tab("Explore", systemImage: "magnifyingglass", value: PhoneReiter.entdecken) {
                        PhoneEntdeckenView(modell: orte, apiClient: client)
                    }
                    // Vierter Reiter, ohne Zustand hier oben: `PhoneSettingsView`
                    // liest die Vermerke selbst per `@Query` und den Server aus
                    // `ConnectionManager` — es gibt nichts, was ein Reiterwechsel
                    // verlieren könnte (anders als bei `photoFeed` und `offline`).
                    Tab("Settings", systemImage: "gearshape", value: PhoneReiter.einstellungen) {
                        PhoneSettingsView(photoFeed: photoFeed, orte: orte)
                    }
                }
            } else if PhoneRootWeiche.zweig(state: connection.state, istKonfiguriert: connection.isConfigured, bereit: false) == .verbindet {
                // `.connecting`, oder die kurze async-Lücke NACH einem erfolgreichen
                // Connect (state ist schon `canBrowse`), bevor der `AlbumManager`
                // oben aufgebaut ist (`.task(id:)`). Beides ist ein echtes
                // "verbindet gerade" — hier ist ein Dauerspinner unmöglich, weil
                // beide Zustände zwangsläufig weiterlaufen (Connect endet, oder der
                // `AlbumManager`-Task oben greift sofort).
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Connecting…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if connection.isConfigured {
                // Übrig bleiben hier ausschließlich `.disconnected` und `.error(_)`
                // mit gespeicherten Zugangsdaten — der Fall, in dem der Server beim
                // Kaltstart nicht antwortet. Feiner als die Mac-Weiche
                // (`Sources/ImmichMac/Views/ContentView.swift:33`), die `isConfigured`
                // allein als "verbindet" liest: Dort setzt `goOfflineIfCached()`
                // (`ConnectionManager.swift:203`) bei fehlgeschlagenem Auto-Reconnect
                // zuverlässig `.offline`, sobald `ConnectionManager.hasCachedData(defaults:)`
                // wahr ist. Das galt lange nur nach einem vollständigen Erstsync
                // (`hasCompletedInitialSync`, von der `SyncEngine` gesetzt, die auf
                // iOS in diesem PR gar nicht läuft) — der Offline-Zweig wäre also
                // strukturell unerreichbar gewesen. Seit dem zweiten Kriterium
                // `hasCachedAlbums` (vom `AlbumManager` nach dem ersten erfolgreichen
                // Serverabgleich gesetzt) reicht eine gecachte Albumliste, und
                // `state` kann hier durchaus `.offline` werden — dieser Zweig sieht
                // ihn dann aber ohnehin nie: `.offline` erfüllt `canBrowse` und wird
                // vom ersten Zweig oben schon abgefangen, genau wie `.connected`.
                // Übrig bleiben hier also wirklich nur `.disconnected`/`.error`.
                // Ohne diesen eigenen Zweig zeigte die Mac-Weiche hier für immer
                // "Verbinde…", ohne Wiederholung und ohne Ausweg.
                PhoneUnreachableView(state: connection.state, photoFeed: photoFeed, orte: orte)
            } else {
                // Vorspann nur beim allerersten Start; nach Abmelden direkt die Einrichtung.
                OnboardingAblauf(mitVorspann: OnboardingStatus.zeigeVorspann())
            }
        }
        // Wie ContentView auf dem Mac: nie unter XCTest, sonst öffnet der
        // Testhost eine echte Netzwerkverbindung.
        .task {
            OnboardingStatus.merkeBestandsnutzer(istKonfiguriert: connection.isConfigured)
            // Mit Cache sofort den Inhalt zeigen, statt bis zur Frist auf „Verbinde…“.
            connection.sofortOfflineBeimKaltstart = true
            if !AppEnvironment.isRunningTests,
               connection.isConfigured, !connection.state.isConnected {
                await connection.reconnect()
                PhoneVersionsTor.pruefe(connection)
            }
        }
        .alert("Local Data Reset", isPresented: $storeZurueckgesetzt) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The local database could not be opened and was recreated. Albums and photos reload from the server; albums kept offline need to be selected again.")
        }
        // Läuft neu, sobald sich die Server-URL ändert (erster Connect,
        // späterer Reconnect gegen einen anderen Server) — `URL` ist Equatable,
        // `nil` beim Start macht daraus einen No-op.
        .task(id: connection.apiClient?.baseURL) {
            await setUpAlbumManagerIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .kontoGewechselt)) { _ in
            photoFeed.leere()
            orte.leere()
            offline.refresh(context: modelContext)
        }
        .onDisappear {
            coverPrefetcher?.stop()
        }
    }

    private func setUpAlbumManagerIfNeeded() async {
        guard let client = connection.apiClient else { return }

        // Bewusst KEIN Wiederverwenden eines vorhandenen `albumManager`: dessen
        // `apiClient` ist in `AlbumManager` ein `private let` und kann seinen
        // Client nie wechseln. Feuert dieser Task erneut (der `id:` oben ist die
        // Basis-URL — das passiert also bei jedem Connect zu einer anderen
        // Adresse), würde ein wiederverwendeter Manager weiter gegen den ALTEN
        // Client sprechen. Auf dem Mac tritt dasselbe Muster nicht auf, weil
        // `MainView` bei einem Verbindungswechsel aus dem `Group`-Zweig
        // verschwindet und mit neuer View-Identität (und damit frischem
        // `@State`) wieder entsteht. `PhoneRootView` ist dagegen die dauerhafte
        // Wurzel der Scene — ihr `@State private var albumManager` überlebt
        // jeden Zyklus, ein Wiederverwenden hier wäre also ein Manager mit
        // totem Client. Deshalb: bei jedem Feuern mit vorhandenem Client einen
        // frischen `AlbumManager` bauen, und `hasLoadedOnce` VORHER zurücksetzen
        // — sonst zeigte ein Serverwechsel kurz "Server kennt keine Alben"
        // statt "lädt", weil das Flag noch vom vorigen Server auf `true` stand.
        hasLoadedOnce = false
        let manager = AlbumManager(apiClient: client)
        manager.configure(modelContext: modelContext)
        albumManager = manager
        // Vor dem ersten `loadAlbums()`: zeigt sofort an, was von einem
        // früheren Server-/Login-Zyklus noch an Vermerken in SwiftData liegt,
        // statt bis zum Rückkehren des Ladeaufrufs unten mit leeren Abzeichen
        // dazustehen.
        offline.refresh(context: modelContext)

        // Cache-first: `loadAlbums()` zeigt sofort, was in SwiftData liegt, und
        // gleicht erst danach im Hintergrund mit dem Server ab (siehe
        // `AlbumManager.loadAlbums` in `Sources/Shared/ViewModels/AlbumManager.swift`).
        // Genau das verhindert die leere Albumliste, die die offizielle App
        // unterwegs minutenlang zeigt.
        await reloadAlbumsAndWarmCovers(manager: manager, apiClient: client)
    }

    /// Der Dreischritt nach jedem erfolgreichen Albumabgleich: laden, Offline-
    /// Abzeichen neu ableiten, Titelbilder vorwärmen. Genau **eine** Stelle, die
    /// diese Abfolge kennt — sowohl der Erstaufbau oben
    /// (`setUpAlbumManagerIfNeeded()`) als auch der Aktualisieren-Zug im Raster
    /// (`PhoneAlbumGridView.refreshable`, über den `onRefresh`-Durchgriff von
    /// oben) rufen ausschließlich diese Funktion. Vorher rief der
    /// Aktualisieren-Zug `albumManager.loadAlbums()` direkt auf und ließ dabei
    /// sowohl `offline.refresh(context:)` als auch den Vorwärmer aus — genau
    /// der Zug, mit dem neue Alben und geänderte Titelbilder auftauchen,
    /// wärmte deren Bilder also nie vor.
    ///
    /// `hasLoadedOnce = true` hier (statt nur beim Erstaufbau) ist beim
    /// Aktualisieren ein No-op, da das Flag zu dem Zeitpunkt schon `true` ist
    /// — die einzelne Stelle ist wichtiger als das Vermeiden einer
    /// überflüssigen Zuweisung.
    private func reloadAlbumsAndWarmCovers(manager: AlbumManager, apiClient: ImmichAPIClient) async {
        await manager.loadAlbums()
        hasLoadedOnce = true
        // Für die Suche in „Entdecken": Fotos geteilter Alben findet der Server nur mit
        // deren IDs (`PhoneGeteilteAlben`). Nach jedem Abgleich, denn ein neu geteiltes
        // Album kommt genau hier an.
        PhoneGeteilteAlben.setze(manager.sharedAlbums.map(\.id))
        // Erneut nach dem Serverabgleich: `loadAlbums()` kann neue Alben (und
        // damit neue `OfflinePin`-lose Kacheln) bekannt gemacht haben, die vor
        // dem Aufruf oben noch gar nicht existierten.
        offline.refresh(context: modelContext)
        warmCoverThumbnails(apiClient: apiClient, manager: manager)
    }

    /// Vorwärmen ALLER Titelbilder (nicht nur der sichtbaren Kacheln) in den
    /// Nuke-Disk-Cache — siehe `PhoneCoverPrefetcher.swift`. Ohne `imagePipeline`
    /// (z. B. `nil` in einem Zustand, den `canBrowse` eigentlich ausschließt)
    /// gibt es nichts zu wärmen; **kein** Ausweichen auf `.shared` — die
    /// gemeinsame Pipeline ist unauthentifiziert und würde nur 401er erzeugen.
    ///
    /// Baut bei jedem Aufruf einen frischen `PhoneCoverPrefetcher` (und stoppt
    /// einen etwaigen alten zuerst) statt einen vorhandenen wiederzuverwenden:
    /// dieselbe Überlegung wie beim `AlbumManager` oben — `.task(id:)` feuert
    /// diese Funktion bei jedem Connect zu einer neuen Basis-URL erneut, und
    /// `connection.imagePipeline` ist dann eine neue Instanz (`ConnectionManager.
    /// makeImagePipeline`); ein wiederverwendeter Vorwärmer hinge sonst an der
    /// Pipeline des vorigen Servers.
    private func warmCoverThumbnails(apiClient: ImmichAPIClient, manager: AlbumManager) {
        coverPrefetcher?.stop()
        guard let pipeline = connection.imagePipeline else {
            coverPrefetcher = nil
            return
        }
        let urls = (manager.albums + manager.sharedAlbums).compactMap { album in
            album.albumThumbnailAssetId.map { apiClient.thumbnailURL(assetId: $0, size: .thumbnail) }
        }
        // Eigene und geteilte Alben können dasselbe Titelbild teilen (z. B. ein
        // Album, das dem Nutzer gehört UND mit ihm geteilt ist) — ohne diese
        // Entdopplung fordert `startPrefetching(with:)` dieselbe URL mehrfach
        // an. `Set` nur zum Filtern, die Reihenfolge der ersten Vorkommen
        // bleibt erhalten.
        var seenUrls = Set<URL>()
        let dedupedUrls = urls.filter { seenUrls.insert($0).inserted }
        let prefetcher = PhoneCoverPrefetcher(pipeline: pipeline)
        coverPrefetcher = prefetcher
        prefetcher.warm(dedupedUrls)
        AppLogger.library.info("Titelbilder vorgewärmt: \(dedupedUrls.count, privacy: .public)")
    }
}

/// Zustand "Zugangsdaten vorhanden, Server aber nicht erreichbar"
/// (`.disconnected` oder `.error(_)` bei `ConnectionManager.isConfigured == true`).
///
/// Ohne diese Ansicht endete `PhoneRootView` hier dauerhaft im
/// "Verbinde…"-Spinner: Der Auto-Reconnect in `.task` scheitert einmal und
/// bleibt danach in `.disconnected`/`.error` stehen, ohne von sich aus etwas
/// zu wiederholen. Zwei Auswege: erneut versuchen (derselbe Server), oder die
/// Zugangsdaten verwerfen und neu einrichten.
private struct PhoneUnreachableView: View {

    let state: ConnectionState

    /// Fotos- und Orte-Reiter, hereingereicht wie in `PhoneSettingsView`: „Zugangsdaten
    /// ändern" ist ein Abmelden und muss dieselben Reste räumen — sonst zeigte ein
    /// anderes Konto hinter derselben Adresse Katalog und Personen des vorigen.
    let photoFeed: PhonePhotoFeed
    let orte: PhoneOrtsModell

    @Environment(ConnectionManager.self) private var connection

    private var meldung: String {
        if case .error(let text) = state {
            return text
        }
        return String(localized: "Server Unreachable")
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(meldung)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Button("Try Again") {
                Task {
                    await connection.reconnect()
                    PhoneVersionsTor.pruefe(connection)
                }
            }
            .buttonStyle(.borderedProminent)

            // `disconnect()` löscht die gespeicherten Zugangsdaten
            // (`ConnectionManager.swift:250`) und setzt `isConfigured` auf
            // `false` — die Weiche in `PhoneRootView` zeigt danach von selbst
            // wieder das Onboarding (`OnboardingAblauf`), ohne dass diese Ansicht die Navigation
            // dorthin selbst bauen muss.
            // Ein Kontowechsel danach wird beim nächsten `connect` erkannt
            // (`KontoWechsel`: Kennung, sonst Server + Key-Fingerabdruck).
            Button("Change Credentials", role: .destructive) {
                connection.disconnect()
                photoFeed.leere()
                orte.leere()
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
