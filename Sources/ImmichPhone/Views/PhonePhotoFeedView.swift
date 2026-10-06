import SwiftUI

/// Der Reiter „Fotos": die ganze Mediathek als dreispaltiges Raster mit
/// Tagesüberschriften, seitenweise nachgeladen.
///
/// Zeigt nur an — der Zustand (geladene Seiten, Fehler, „noch mehr da?") liegt
/// in `PhonePhotoFeed`, das `PhoneRootView` als `@State` hält, damit ein
/// Reiterwechsel weder Seiten noch Scrollposition verliert.
///
/// **Ausdrücklich kein Zeitleisten-Scrubber.** Der Nutzer hat das Feature am
/// Mac zweimal abgelehnt (PRs #9–#11 verworfen); die Überschriften pro Tag sind
/// die einzige Datumsorientierung hier.
struct PhonePhotoFeedView: View {

    var feed: PhonePhotoFeed

    /// Wird von `PhoneRootView` aus demselben `connection.apiClient`
    /// hereingereicht, unter dem dort auch der `AlbumManager` gebaut wird —
    /// diese Ansicht soll nicht selbst entscheiden, ob es einen Client gibt.
    let apiClient: ImmichAPIClient

    @Environment(ConnectionManager.self) private var connection

    /// Dieser Reiter lädt **ausschließlich** über `searchAssets` vom Server und
    /// hat keinen Cache — anders als das Albumraster, das aus SwiftData
    /// zeichnen kann. Ohne Netz gibt es hier also nichts zu holen, und ein
    /// Versuch endet nach dem Zeitlimit mit einer englischen Systemmeldung
    /// („The request timed out"), die dem Nutzer nichts sagt. Besser gar nicht
    /// erst anfragen und den Grund nennen.
    private var istOffline: Bool { connection.state.isOffline }

    var body: some View {
        NavigationStack {
            ScrollView {
                PhoneFeedRaster(feed: feed, apiClient: apiClient, istOffline: istOffline)
            }
            .navigationTitle("Photos")
            .navigationBarTitleDisplayMode(.inline)
            .overlay {
                if feed.abschnitte.isEmpty {
                    leerzustand
                }
            }
            // `safeAreaInset` statt eines Kopfes *im* `ScrollView`: Der
            // Umschalter soll stehen bleiben. Im Raster scrollte er nach oben
            // weg, und tief im Feld käme man nur noch über einen langen Weg
            // zurück an ihn heran. Er sitzt zudem über den angehefteten
            // Tagesüberschriften, nicht zwischen ihnen.
            //
            // **Nach dem `.overlay`, nicht davor.** Der Leerzustand deckt das
            // Raster ab; läge der Umschalter darunter, verdeckte ihn genau der
            // Zustand, aus dem er herausführt — „Keine Videos" ohne die
            // Möglichkeit, zurück auf „Alle" zu tippen.
            .safeAreaInset(edge: .top, spacing: 0) {
                filterUmschalter
            }
            .refreshable {
                await feed.ladeVonVorne(apiClient: apiClient)
            }
        }
        // `id:` auf der Basis-URL, genau wie `PhoneRootView.task(id:)` für den
        // `AlbumManager`: Ein Serverwechsel wirft die geladenen Seiten weg und
        // holt Seite 1 vom neuen Server. `ladeFallsNoetig` ist ansonsten ein
        // No-op — ein Reiterwechsel lädt nicht neu.
        .task(id: apiClient.baseURL) {
            // Offline gar nicht erst anfragen — siehe `istOffline`. Sonst
            // stünde hier für die Dauer des Zeitlimits „Fotos werden geladen…"
            // und danach eine englische Systemmeldung.
            guard !istOffline else { return }
            await feed.ladeFallsNoetig(apiClient: apiClient)
        }
    }

    // MARK: - Umschalter Alle / Fotos / Videos

    /// Die Auswahl liegt im `feed`, nicht in einem `@State` dieser Ansicht.
    ///
    /// Das ist keine Geschmacksfrage: Diese Ansicht wird bei jedem
    /// Reiterwechsel neu gebaut, ein `@State` fiele dabei auf seinen Startwert
    /// zurück — der Umschalter spränge auf „Alle", während `feed` weiter nur
    /// Videos hielte. Zwei Wahrheiten über dieselbe Sache; deshalb nur eine.
    ///
    /// Der Setter läuft über eine `Task`, der Umschalter springt also erst im
    /// nächsten Zeichendurchgang um. Das ist ein Sprung auf dem Hauptthread,
    /// kein Netzweg — der Abruf danach ändert an der Anzeige des Umschalters
    /// nichts mehr.
    private var filterBindung: Binding<PhoneFeedFilter> {
        Binding(
            get: { feed.filter },
            set: { neu in
                Task { await feed.setzeFilter(neu, apiClient: apiClient) }
            }
        )
    }

    private var filterUmschalter: some View {
        Picker("Show", selection: filterBindung) {
            ForEach(PhoneFeedFilter.allCases) { filter in
                // Variable statt Literal — SwiftUI parst `Text`-Literale als
                // Markdown (siehe `PhoneAlbumTile`).
                Text(filter.titel).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        // `Marke.akzent` statt der Systemtönung, wie überall sonst im Client.
        .tint(Marke.akzent)
        .labelsHidden()
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // Derselbe deckende Grund wie bei den Tagesüberschriften: Der
        // Umschalter steht über scrollendem Inhalt.
        .background(.bar)
        // Offline fragt dieser Reiter grundsätzlich nicht an (siehe
        // `istOffline`). Ein Umschalten würde den vorhandenen Bestand
        // wegwerfen und könnte den neuen nicht holen — der Reiter bliebe leer
        // zurück, ohne dass irgendetwas erreicht wäre. Deshalb hier gesperrt
        // statt im Modell eine zweite, ladefreie Umschaltung zu bauen.
        .disabled(istOffline)
    }

    /// Drei Fälle, die sich nicht vermischen dürfen — dieselbe Trennung, die
    /// `PhoneAlbumGridView.emptyState` und der `.fehler`-Zweig in
    /// `PhoneAlbumDetailView` schon vornehmen: Ein Netzfehler ist keine leere
    /// Mediathek, und ein laufender Erstabruf auch nicht.
    private static let offlineErklaerung =
        String(localized: "This tab loads directly from the server and keeps nothing offline. Albums kept offline are under Albums.")

    @ViewBuilder
    private var leerzustand: some View {
        if istOffline {
            ContentUnavailableView(
                "Offline",
                systemImage: "airplane",
                description: Text(Self.offlineErklaerung)
            )
        } else if let fehler = feed.fehler {
            ContentUnavailableView(
                "Photos Unavailable",
                systemImage: "wifi.slash",
                description: Text(fehler)
            )
            .overlay(alignment: .bottom) {
                Button("Try Again") {
                    Task { await feed.ladeVonVorne(apiClient: apiClient) }
                }
                .buttonStyle(.borderedProminent)
                .padding(.bottom, 40)
            }
        } else if feed.hatJeGeladen && !feed.laedt {
            // `!laedt` gehört dazu: `ladeVonVorne` leert die Liste **vor** dem
            // ersten `await`, und `hatJeGeladen` bleibt nach dem ersten Lauf
            // dauerhaft wahr. Ohne diese Bedingung stünde für die gesamte Dauer
            // jedes Aktualisieren-Zugs „Der Server kennt bisher keine Fotos" da
            // — im schnellen Netz ein Aufblitzen, im langsamen sekundenlang.
            //
            // Titel, Symbol und Text kommen vom Filter: „Keine Videos" ist
            // eine andere Auskunft als „Der Server kennt bisher keine Fotos",
            // und wer den Unterschied nicht liest, sucht den Fehler beim
            // Server statt beim Umschalter. Die drei Texte stehen in
            // ``PhoneFeedFilter`` und sind dort geprüft.
            ContentUnavailableView(
                feed.filter.leerTitel,
                systemImage: feed.filter.leerSymbol,
                description: Text(feed.filter.leerText)
            )
        } else {
            ContentUnavailableView {
                ProgressView()
            } description: {
                Text(feed.filter.ladeText)
            }
        }
    }
}
