import SwiftUI
import SwiftData
import NukeUI
import ImageIO
import UIKit

/// Einzelbildansicht: Wischnavigation über ein seitenweises `TabView`, Zoom
/// per Kneifgeste — und seit dieser Änderung die drei Aktionen Teilen,
/// Favorit und Löschen, oben rechts neben dem Schließen-X (die Begründung für
/// diese Stelle steht am `aktionsleiste`-Aufruf im Rumpf).
///
/// **Was die drei Aktionen dürfen und was nicht:**
///
/// - *Teilen* geht über das System-Teilenblatt und braucht eine Datei. Liegt
///   das Original schon auf der Platte (gepinntes Album), nimmt es die; sonst
///   lädt es das Original in ein temporäres Verzeichnis. Das ist die einzige
///   der drei Aktionen, die **ohne Server** funktionieren kann.
/// - *Favorit* schaltet `PUT /api/assets/{id}` um und ist per zweitem Tipp
///   sofort wieder rückgängig — deshalb ohne Rückfrage.
/// - *Löschen* legt in den **Papierkorb** (`force: false`), nie endgültig, und
///   fragt vorher nach. Der Weg zurück führt über den Papierkorb des Servers,
///   nicht über einen zweiten Tipp — das ist der Unterschied, an dem die
///   Rückfrage hängt.
///
/// **Die Rückfrage ist ein `.alert`, kein `confirmationDialog`.** Belegter
/// Befund dieses Projekts (siehe `PhoneAbmeldeBlatt` und `PhoneSettingsView`):
/// iOS 26 zeigte den `confirmationDialog` auf dem iPhone als Popover mit
/// **nur** der roten Taste und ließ „Abbrechen" weg. Bei einer zerstörenden
/// Aktion wäre das das Gegenteil dessen, was eine Rückfrage leisten soll.
///
/// `eintraege` kommt fertig aus `PhoneAlbumDetailView` (online per
/// `getAlbumAssets`, offline aus `CachedAlbum.assetIds` plus `CachedAsset`) —
/// diese Ansicht lädt selbst keine Albumdaten nach, sie zeigt nur die schon
/// bekannte Reihenfolge.
///
/// **Warum `[PhoneAlbumGridEintrag]` statt der früheren `[String]`:** Eine
/// Seite muss entscheiden, ob sie ein Standbild oder einen Player zeigt, und
/// `isVideo` steht bereits in dem Eintrag, den das Raster ohnehin gebaut hat
/// (Task 1). Die Alternative — je Seite den Medientyp nachschlagen — hieße
/// entweder eine zusätzliche Serverabfrage oder ein `CachedAsset`-Lookup, der
/// online gerade nicht gefüllt sein muss.
struct PhoneAssetView: View {
    let eintraege: [PhoneAlbumGridEintrag]
    let start: Int
    /// Meldet der Elternansicht, dass dieses Asset im Papierkorb liegt, damit
    /// sie es aus ihrer Liste nimmt. Läuft **vor** dem `dismiss()`.
    ///
    /// Warum ein Rückruf und keine Notification: siehe
    /// `PhoneAlbumDetailView.entferne(assetId:)`.
    let onGeloescht: (String) -> Void
    /// Meldet den neuen Sternzustand nach oben, damit ein zweites Öffnen
    /// desselben Fotos nicht den alten zeigt.
    let onFavoritGeaendert: (String, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(ConnectionManager.self) private var connection
    @Environment(\.modelContext) private var modelContext

    @State private var currentIndex: Int
    /// Abweichungen vom Sternzustand, mit dem die Einträge hereinkamen —
    /// `eintraege` ist ein `let` und gehört der Elternansicht. Der wirksame
    /// Zustand steht in `istFavorit(_:)`.
    @State private var favoritenAenderungen: [String: Bool] = [:]
    @State private var zeigtLoeschfrage = false
    /// Welche der drei Aktionen gerade auf den Server wartet, oder `nil`.
    ///
    /// Sperrt die ganze Leiste (`arbeitet`), damit ein zweiter Tipp nicht
    /// denselben Aufruf noch einmal startet — beim Löschen wäre das ein
    /// zweiter DELETE auf ein Asset, das schon im Papierkorb liegt. Und sie
    /// sagt, **welcher** Knopf den Spinner zeigt: dort, wo getippt wurde.
    @State private var laufendeAktion: PhoneEinzelbildAktion?
    @State private var fehlermeldung: String?
    @State private var teilenGegenstand: PhoneTeilenGegenstand?

    init(
        eintraege: [PhoneAlbumGridEintrag],
        start: Int,
        onGeloescht: @escaping (String) -> Void = { _ in },
        onFavoritGeaendert: @escaping (String, Bool) -> Void = { _, _ in }
    ) {
        self.eintraege = eintraege
        self.start = start
        self.onGeloescht = onGeloescht
        self.onFavoritGeaendert = onFavoritGeaendert
        _currentIndex = State(initialValue: start)
    }

    /// Der Eintrag, auf den sich die Leiste bezieht. `nil`, wenn die
    /// Elternansicht die Liste unter uns geleert hat — dann zeichnet die
    /// Leiste gar nicht erst.
    private var aktuellerEintrag: PhoneAlbumGridEintrag? {
        eintraege.indices.contains(currentIndex) ? eintraege[currentIndex] : nil
    }

    private func istFavorit(_ eintrag: PhoneAlbumGridEintrag) -> Bool {
        favoritenAenderungen[eintrag.id] ?? eintrag.isFavorite
    }

    /// Favorit und Löschen brauchen den Server; Teilen nicht (siehe Doku am
    /// Typ). `apiClient` gehört zur selben Frage: Ohne ihn gibt es keinen
    /// Schreibweg, auch wenn die Verbindung als hergestellt gilt.
    private var serverVerfuegbar: Bool {
        connection.apiClient != nil && !connection.state.isOffline
    }

    private var arbeitet: Bool { laufendeAktion != nil }

    /// Ohne Favorit- und Löschknopf gibt es nichts, was der Offline-Hinweis erklären müsste.
    private var hatSchreibknoepfe: Bool {
        connection.keyRechte.darf(KeyRechte.favorit) || connection.keyRechte.darf(KeyRechte.loeschen)
    }

    /// Immich trennt die beiden Ablehnungen: fehlendes Key-Recht ist 403
    /// („Missing required permission"), ein fremdes Asset (etwa in einem geteilten
    /// Album) dagegen 400 („Not found or no … access"). Nur 403 sperrt den Knopf.
    ///
    /// Ein 403 heißt: Dem Key fehlt das Recht. Merken (der Knopf verschwindet,
    /// auch nach einem Neustart) und das statt „HTTP 403" sagen.
    private func meldeFehler(_ error: Error, recht: String) {
        if case APIError.httpError(403) = error {
            connection.merkeAbgelehnt(recht)
            fehlermeldung = Self.rechtFehltText
        } else {
            fehlermeldung = error.localizedDescription
        }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            TabView(selection: $currentIndex) {
                ForEach(Array(eintraege.enumerated()), id: \.offset) { index, eintrag in
                    PhoneAssetPage(eintrag: eintrag, isCurrentPage: index == currentIndex)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            // Befund aus der Prüfung von Task 6: `.simultaneousGesture` allein
            // trennt die beiden Erkenner nicht nach Fingerzahl — ein Kneifen
            // mit ungleichmäßiger Fingerbewegung (praktisch immer) erzeugt
            // zusätzlich eine horizontale Nettobewegung, die der
            // Wisch-Erkenner des `.page`-`TabView` mitten im Zoomen als
            // Seitenwechsel deutet.
            //
            // Zwei verworfene Versuche, damit sie niemand wiederholt:
            //
            // 1. `.scrollDisabled(scale > 1)` auf dem `TabView`. Am Simulator
            //    geprüft (Zoom sauber committed, per zweitem Screenshot ohne
            //    Zwischen-Touch bestätigt) — die Seite wechselte trotzdem beim
            //    Wischen. `.scrollDisabled` greift beim `.page`-Stil **nicht**.
            // 2. `PageScrollLock`, ein unsichtbares `UIViewRepresentable`, das
            //    die `UIScrollView` des `TabView` aus der Ansichtshierarchie
            //    heraussuchte und dort `isScrollEnabled` schrieb. Wirkte, ließ
            //    das Blättern aber gelegentlich *zwischen* zwei Fotos stehen:
            //    Eine `UIScrollView` bricht ihre laufende Animation ab, sobald
            //    man das Kennzeichen anfasst, und `updateUIView` läuft bei
            //    jeder Aktualisierung — also auch mitten im Seitenwechsel.
            //    Zwei Nachbesserungen leiteten den sicheren Zeitpunkt aus
            //    `isDragging`/`isDecelerating`/`contentOffset` ab und machten
            //    das Symptom nur seltener; das Einschwingen nach einem sanften
            //    Wisch zeigt keines der drei an.
            //
            // Was jetzt sperrt, steht in `PhoneAssetPage.bildinhalt`: ein
            // `.gesture(DragGesture(), isEnabled: scale > 1)`, das den Wisch
            // schluckt, statt am `TabView` herumzuschreiben. Begründung dort.
            //
            // Kein `.onChange(of: currentIndex)` mehr, das den Zoom
            // zurücksetzt: Befund aus der Prüfung der letzten Nachbesserung —
            // ein einziger, über alle Seiten geteilter `scale` ließ jede
            // instanziierte Seite (auch eine von `TabView` nur zur
            // Wischvorbereitung geladene Nachbarseite) denselben Zoomwert
            // zeigen, bis dieser `onChange` einen Tick später zurücksetzte.
            // `scale` liegt jetzt wieder seiteneigen in `PhoneAssetPage`
            // (`@State`, siehe dort) — das Zurücksetzen passiert dort per
            // `.onAppear`, nicht mehr zentral hier.
            //
            // `.fullScreenCover` bringt keine eigene Zurück-Navigation mit —
            // ohne diese Schaltfläche käme man aus dem Einzelbild nicht mehr
            // heraus.
            //
            // Oben **rechts**, nicht links: AVKit legt die eigene
            // Vollbild-Schaltfläche des `VideoPlayer` oben links ab. Dort lag
            // dieses X vorher darüber, gewann den Treffertest und verbaute
            // damit den einzigen Weg ins AVKit-Vollbild — sichtbar, sobald die
            // Transportleiste eingeblendet war. Rechts kollidiert nichts, und
            // Foto- wie Videoseiten behalten dieselbe Stelle.
            //
            // **Warum die drei Aktionen hier oben stehen und nicht, wie sonst
            // in Fotoapps üblich, unten:** Die eingeblendete Transportleiste
            // des AVKit-`VideoPlayer` liegt am **unteren** Rand derselben
            // Fläche. Eine Aktionsleiste dort läge auf einer Videoseite genau
            // über Abspielknopf und Zeitleiste und gewänne den Treffertest —
            // derselbe Fehler, den dieses X oben links schon einmal gemacht
            // hat. Die drei Aktionen an einer Stelle für Foto und Video zu
            // halten ist mehr wert als die gewohnte Position; oben rechts ist
            // die einzige Kante, die AVKit nachweislich freilässt.
            aktionsleiste
                .padding(16)
        }
        .preferredColorScheme(.dark)
        // `.alert`, nicht `confirmationDialog` — Begründung am Typ oben.
        .alert(Self.loeschTitel, isPresented: $zeigtLoeschfrage) {
            Button(Self.abbrechenText, role: .cancel) { }
            Button(Self.loeschBestaetigenText, role: .destructive) { loesche() }
        } message: {
            Text(Self.loeschErklaerung)
        }
        .alert(
            Self.fehlerTitel,
            isPresented: Binding(get: { fehlermeldung != nil }, set: { if !$0 { fehlermeldung = nil } })
        ) {
            Button(Self.okText, role: .cancel) { fehlermeldung = nil }
        } message: {
            // Immer über eine Variable — SwiftUI parst `Text`-Literale als
            // Markdown, und eine Fehlermeldung des Servers kann eine URL
            // enthalten (siehe die Falle in `CLAUDE.md`).
            Text(fehlermeldung ?? "")
        }
        .sheet(item: $teilenGegenstand) { gegenstand in
            PhoneTeilenBlatt(url: gegenstand.url)
        }
    }

    // MARK: - Aktionsleiste

    private var aktionsleiste: some View {
        VStack(alignment: .trailing, spacing: 6) {
            // 6 statt 10: Die Trefferflächen sind je Seite 2 pt breiter als der
            // sichtbare Kreis, der Abstand zwischen den Kreisen bleibt gleich.
            HStack(spacing: 6) {
                if let eintrag = aktuellerEintrag {
                    leistenknopf(
                        symbol: "square.and.arrow.up",
                        beschriftung: Self.teilenText,
                        aktion: .teilen
                    ) {
                        teile(eintrag)
                    }
                    // Nur, was der API-Key darf (`KeyRechte`): Ein Nur-Lese-Key
                    // bekommt keine Knöpfe, die garantiert scheitern.
                    if connection.keyRechte.darf(KeyRechte.favorit) {
                        leistenknopf(
                            symbol: istFavorit(eintrag) ? "star.fill" : "star",
                            beschriftung: istFavorit(eintrag) ? Self.favoritEntfernenText : Self.favoritSetzenText,
                            aktion: .favorit,
                            farbe: istFavorit(eintrag) ? Theme.favorite : .white,
                            aktiv: serverVerfuegbar
                        ) {
                            schalteFavorit(eintrag)
                        }
                    }
                    if connection.keyRechte.darf(KeyRechte.loeschen) {
                        leistenknopf(
                            symbol: "trash",
                            beschriftung: Self.loeschenText,
                            aktion: .loeschen,
                            aktiv: serverVerfuegbar
                        ) {
                            zeigtLoeschfrage = true
                        }
                    }
                }
                // Das Schließen steht **nicht** unter der `arbeitet`-Sperre:
                // Auch während eines laufenden Downloads muss man hier
                // herauskommen.
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(.thinMaterial, in: Circle())
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(Self.schliessenText)
            }
            if !serverVerfuegbar && aktuellerEintrag != nil && hatSchreibknoepfe {
                // Nicht bloß ausgrauen, sondern den Grund nennen — eine stumm
                // graue Taste sieht aus wie ein Fehler. Immer über eine
                // Konstante, nie als Literal (Markdown-Falle).
                Text(Self.offlineHinweis)
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.trailing)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.thinMaterial, in: Capsule())
            }
        }
    }

    /// Ein Knopf der Leiste — dieselbe Kreisform wie das X daneben, damit die
    /// vier eine Reihe ergeben und nicht drei Symbole neben einer Taste.
    ///
    /// `arbeitet` zeigt sich als Spinner an der Stelle des Symbols, nicht als
    /// zusätzliche Ansicht: Wo etwas läuft, soll man dort sehen, wo man
    /// getippt hat.
    private func leistenknopf(
        symbol: String,
        beschriftung: String,
        aktion: PhoneEinzelbildAktion,
        farbe: Color = .white,
        aktiv: Bool = true,
        tippen: @escaping () -> Void
    ) -> some View {
        Button(action: tippen) {
            Group {
                if laufendeAktion == aktion {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: symbol)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(aktiv ? farbe : Color.white.opacity(0.35))
                }
            }
            .frame(width: 20, height: 20)
            .padding(10)
            .background(.thinMaterial, in: Circle())
            // Sichtbar bleibt der 40-pt-Kreis; getroffen wird auf 44 × 44 pt
            // (Mindestmaß der Human Interface Guidelines).
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!aktiv || arbeitet)
        .accessibilityLabel(beschriftung)
    }

    // MARK: - Teilen

    /// Besorgt eine Datei und übergibt sie dem System-Teilenblatt.
    ///
    /// Erst ein lokales **Original**, dann der Server, zuletzt eine lokale
    /// Vorschau oder kleine Videofassung (`PhoneTeilenWeg`). Das Original, nicht
    /// die Vorschau: Wer teilt, will die Datei, nicht ein bildschirmgroßes JPEG —
    /// ohne Netz ist die Vorschau aber besser als eine Fehlermeldung.
    private func teile(_ eintrag: PhoneAlbumGridEintrag) {
        guard !arbeitet else { return }
        let id = eintrag.id
        let lokal = PhoneOriginaldatei.aufPlatte(assetId: id, context: modelContext)
        switch PhoneTeilenWeg.bestimme(lokal: lokal, hatServer: connection.apiClient != nil) {
        case .lokal(let url):
            AppLogger.library.info("Teilen \(id, privacy: .public): lokale Datei \(url.lastPathComponent, privacy: .public)")
            teilenGegenstand = PhoneTeilenGegenstand(url: url)
        case .nichts:
            fehlermeldung = Self.teilenOhneQuelle
        case .server(let ersatz):
            guard let apiClient = connection.apiClient else { return }
            laufendeAktion = .teilen
            Task {
                defer { laufendeAktion = nil }
                do {
                    let url = try await Self.ladeOriginalInTemp(assetId: id, apiClient: apiClient)
                    AppLogger.library.info("Teilen \(id, privacy: .public): Original vom Server geladen")
                    teilenGegenstand = PhoneTeilenGegenstand(url: url)
                } catch {
                    AppLogger.library.error("Teilen \(id, privacy: .public) fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
                    if let ersatz {
                        AppLogger.library.info("Teilen \(id, privacy: .public): lokale Fassung statt Original")
                        teilenGegenstand = PhoneTeilenGegenstand(url: ersatz)
                    } else {
                        fehlermeldung = error.localizedDescription
                    }
                }
            }
        }
    }

    /// Lädt das Original in ein eigenes Unterverzeichnis von
    /// `temporaryDirectory` und benennt es nach dem Namen, den der Server
    /// meldet.
    ///
    /// Eigenes Unterverzeichnis je Aufruf, damit zwei Assets mit demselben
    /// Dateinamen (aus zwei Kameras, `IMG_0001.JPG`) sich nicht überschreiben.
    /// Der endgültige Name steht erst nach dem Download fest — `downloadOriginalToFile`
    /// liefert ihn aus `Content-Disposition` zurück —, deshalb erst unter einem
    /// Platzhalter laden und dann umbenennen. Direkt nach dem Öffnen des Blattes
    /// wird nichts gelöscht — das zöge der Ziel-App die Datei unter den Füßen
    /// weg —, sondern beim nächsten Teilen alles, was älter als eine Stunde ist
    /// (``PhoneTeilenAblage``). Der Servername läuft durch
    /// ``PhoneTeilenAblage/sichererName(_:assetId:)``, damit er den Ordner nicht
    /// verlassen kann.
    private static func ladeOriginalInTemp(assetId: String, apiClient: ImmichAPIClient) async throws -> URL {
        await Task.detached(priority: .utility) { _ = PhoneTeilenAblage.raeumeAuf() }.value
        let verzeichnis = FileManager.default.temporaryDirectory
            .appending(path: "\(PhoneTeilenAblage.praefix)\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: verzeichnis, withIntermediateDirectories: true)
        let platzhalter = verzeichnis.appending(path: assetId)
        let dateiname = try await apiClient.downloadOriginalToFile(
            assetId: assetId,
            destinationURL: platzhalter
        )
        let ziel = verzeichnis.appending(path: PhoneTeilenAblage.sichererName(dateiname, assetId: assetId))
        guard ziel != platzhalter else { return platzhalter }
        try? FileManager.default.removeItem(at: ziel)
        try FileManager.default.moveItem(at: platzhalter, to: ziel)
        return ziel
    }

    // MARK: - Favorit

    /// Schaltet den Stern um — optimistisch, mit Rücknahme bei Fehlschlag.
    ///
    /// Optimistisch, weil die Aktion ohne Rückfrage läuft und der Nutzer sonst
    /// bis zur Serverantwort nicht sähe, ob sein Tipp angekommen ist. Scheitert
    /// der Aufruf, geht der Stern zurück und die Meldung steht im Fehler-Alert
    /// — kein stiller Rückfall.
    private func schalteFavorit(_ eintrag: PhoneAlbumGridEintrag) {
        guard !arbeitet, let apiClient = connection.apiClient, serverVerfuegbar else { return }
        let id = eintrag.id
        let neu = !istFavorit(eintrag)
        favoritenAenderungen[id] = neu
        onFavoritGeaendert(id, neu)
        laufendeAktion = .favorit
        Task {
            defer { laufendeAktion = nil }
            do {
                try await apiClient.toggleFavorite(assetId: id, isFavorite: neu)
                merkeFavoritImCache(assetId: id, ist: neu)
                AppLogger.library.info("Favorit \(id, privacy: .public) auf \(neu, privacy: .public) gesetzt")
            } catch {
                favoritenAenderungen[id] = !neu
                onFavoritGeaendert(id, !neu)
                AppLogger.library.error("Favorit \(id, privacy: .public) fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
                meldeFehler(error, recht: KeyRechte.favorit)
            }
        }
    }

    /// Zieht den Sternzustand im Offline-Cache nach, sofern es dort einen
    /// Eintrag gibt. Ohne das zeigte ein gepinntes Album nach dem nächsten
    /// Start wieder den alten Stand — der Offline-Pfad von
    /// `PhoneAlbumDetailView` liest `CachedAsset.isFavorite`.
    ///
    /// Ein fehlender Eintrag ist kein Fehler: Nur gepinnte Alben legen
    /// `CachedAsset` an.
    private func merkeFavoritImCache(assetId: String, ist: Bool) {
        let descriptor = FetchDescriptor<CachedAsset>(predicate: #Predicate<CachedAsset> { $0.assetId == assetId })
        guard let cached = try? modelContext.fetch(descriptor).first else { return }
        cached.isFavorite = ist
        try? modelContext.save()
    }

    // MARK: - Löschen

    /// Legt das Asset in den **Papierkorb** des Servers (`force: false`),
    /// meldet es nach oben und schließt das Einzelbild.
    ///
    /// `force: true` — das endgültige Löschen — kommt hier nicht vor und soll
    /// auch nicht hinzukommen: Der Papierkorb ist der einzige Weg zurück, den
    /// diese Ansicht dem Nutzer lässt.
    ///
    /// Das `dismiss()` steht im Erfolgszweig, nicht davor: Ein gescheiterter
    /// Aufruf soll das Bild stehen lassen und den Grund zeigen, statt die
    /// Ansicht zu schließen und den Eindruck zu hinterlassen, es sei gelöscht.
    private func loesche() {
        guard !arbeitet, let eintrag = aktuellerEintrag,
              let apiClient = connection.apiClient, serverVerfuegbar else { return }
        let id = eintrag.id
        laufendeAktion = .loeschen
        Task {
            do {
                try await apiClient.deleteAssets(ids: [id], force: false)
                AppLogger.library.info("Asset \(id, privacy: .public) in den Papierkorb gelegt")
                onGeloescht(id)
                dismiss()
            } catch {
                laufendeAktion = nil
                AppLogger.library.error("Löschen \(id, privacy: .public) fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
                meldeFehler(error, recht: KeyRechte.loeschen)
            }
        }
    }

    // MARK: - Texte

    // Alle Anzeigetexte als Konstanten, nie als `Text`-Literal — SwiftUI
    // parst Literale als Markdown (siehe `CLAUDE.md`).
    private static let schliessenText = String(localized: "Close")
    private static let teilenText = String(localized: "Share")
    private static let favoritSetzenText = String(localized: "Add to Favorites")
    private static let favoritEntfernenText = String(localized: "Remove from Favorites")
    private static let loeschenText = String(localized: "Delete")
    private static let loeschTitel = String(localized: "Move to Trash?")
    private static let loeschErklaerung =
        String(localized: "The photo moves to the server’s trash and can be restored there. Nothing is permanently deleted here.")
    private static let loeschBestaetigenText = String(localized: "Move to Trash")
    private static let abbrechenText = String(localized: "Cancel")
    private static let fehlerTitel = String(localized: "Something Went Wrong")
    private static let okText = String(localized: "OK")
    private static let offlineHinweis =
        String(localized: "No server connection: favoriting and deleting are unavailable.")
    private static let rechtFehltText =
        String(localized: "Your API key doesn’t allow this, so the button is now hidden. You can add the permission to the key in Immich.")
    private static let teilenOhneQuelle =
        String(localized: "There’s no file for this photo, and the server can’t be reached.")
}

/// Welche der drei Aktionen gerade läuft — nur dieser Knopf zeigt den Spinner.
enum PhoneEinzelbildAktion {
    case teilen
    case favorit
    case loeschen
}

/// Wrapper, damit `.sheet(item:)` eine URL tragen kann — `URL` ist nicht
/// `Identifiable`, und `.sheet(isPresented:)` plus separatem `@State` könnten
/// auseinanderlaufen (dieselbe Überlegung wie bei `PhoneAssetStartIndex`).
struct PhoneTeilenGegenstand: Identifiable {
    let id = UUID()
    let url: URL
}

/// Wo eine offline gehaltene Originaldatei liegt — oder `nil`.
///
/// Steht als eigener Typ da, weil zwei Stellen dieselbe Frage stellen: die
/// Seite beim Anzeigen (`PhoneAssetPage.bestimmeQuelle`) und die Leiste beim
/// Teilen. `LocalFileCacheManager.localFileURL(forPath:)` gibt nur dann eine
/// URL zurück, wenn die Datei wirklich auf der Platte liegt — ein `CachedAsset`
/// mit gesetztem `localFilePath` allein genügt also nicht.
enum PhoneOriginaldatei {
    /// Läuft auf dem MainActor, an den der `modelContext` gebunden ist. Nur die
    /// Zeichenfolge verlässt das Modellobjekt; das `CachedAsset` selbst darf die
    /// Aktorgrenze nicht überqueren.
    @MainActor
    static func aufPlatte(assetId: String, context: ModelContext) -> URL? {
        let descriptor = FetchDescriptor<CachedAsset>(predicate: #Predicate<CachedAsset> { $0.assetId == assetId })
        guard let cached = try? context.fetch(descriptor).first else { return nil }
        return LocalFileCacheManager.localFileURL(forPath: cached.localFilePath)
    }

    /// Der Dateiname des Originals, sofern er im Cache steht.
    ///
    /// Zweiter Zugriff statt eines gemeinsamen Rückgabepaars mit
    /// ``aufPlatte(assetId:context:)``: Den Namen braucht genau **eine** Stelle
    /// (die Bedienung in `PhoneVideoPlayer`, während das Bild auf dem Fernseher
    /// läuft), die Datei-URL dagegen jede Seite und die Teilen-Aktion. Ein
    /// gemeinsames Paar zwänge alle Aufrufer, etwas mitzuschleppen, das sie
    /// nicht brauchen — und dieser Zugriff hier läuft nur für Videoseiten und
    /// nur einmal je Asset, aus demselben `.task` wie der andere.
    @MainActor
    static func dateiname(assetId: String, context: ModelContext) -> String? {
        let descriptor = FetchDescriptor<CachedAsset>(predicate: #Predicate<CachedAsset> { $0.assetId == assetId })
        guard let cached = try? context.fetch(descriptor).first else { return nil }
        let name = cached.originalFileName
        return name.isEmpty ? nil : name
    }
}

/// Eine Seite in `PhoneAssetView`. Eigener Ladezustand pro Seite, weil jede
/// Seite unabhängig entscheidet, ob eine lokale Originaldatei vorliegt —
/// genau der Fall, den Task 5 vorbereitet hat: ein gepinntes Album bleibt
/// auch ohne Serververbindung durchsuchbar.
///
/// **Ladepfad:** existiert für `assetId` ein `CachedAsset` mit einer
/// tatsächlich auf der Platte liegenden Originaldatei
/// (`LocalFileCacheManager.localFileURL(forPath:)` — liefert nur dann eine
/// URL zurück, wenn die Datei wirklich existiert), zeigt die Seite genau
/// dieses Bild. Das ist der einzige Pfad, der auch ohne Server funktioniert.
/// Sonst `LazyImage` gegen `thumbnailURL(size: .preview)` — dieselbe
/// Auflösung wie ein Vollbild-Tap überall sonst im Mac-Client.
///
/// **Die Wahl trifft `PhoneMediaSource`, nicht diese Ansicht.** Das `if let`
/// von Hand stand hier vorher schon; seit Task 1 des Offline-Plans liegt die
/// Entscheidung in einem geprüften Wertetyp
/// (`Sources/ImmichPhone/PhoneMediaSource.swift`), damit Standbild und Player
/// sie nachweislich gleich treffen — und damit die gewählte Quelle einen
/// Namen für die Protokollzeile hat (`protokollName`). Diese Seite liefert
/// dem Typ nur den bereits geprüften Datei-Zustand zu.
///
/// **Wo der SwiftData-Zugriff sitzt und warum:** in `.task(id: assetId)`,
/// nicht im `body`. Der `FetchDescriptor<CachedAsset>` (dasselbe Muster wie
/// `PhoneAlbumDetailView.eintraege(fuer:)`) läuft damit genau einmal je
/// Asset — nicht bei jedem Neuzeichnen. Und Neuzeichnen gibt es hier reichlich:
/// jede Kneifgeste schreibt `scale`, jede Änderung am `@Observable`-
/// `ConnectionManager` baut den Rumpf neu auf, und `TabView(.page)` hält
/// Nachbarseiten mit auf. Ein Fetch im `body` liefe also dutzendfach je
/// gezeigtem Bild, mitten in der Geste, auf dem Hauptthread. Das Ergebnis
/// liegt stattdessen als `@State` (`lokaleDatei`) vor und wird an den Player
/// weitergereicht, statt dort ein zweites Mal nachgeschlagen zu werden.
private struct PhoneAssetPage: View {
    let eintrag: PhoneAlbumGridEintrag
    private var assetId: String { eintrag.id }
    /// Von `PhoneAssetView` durchgereicht: `index == currentIndex` für genau
    /// diese Seite. Nur noch der Player braucht das (er darf nicht auf einer
    /// Nachbarseite loslaufen, die `TabView(.page)` bloß vorhält); die
    /// Wischsperre kam früher ebenfalls hier vorbei, hängt seit dem Umbau auf
    /// `.gesture(DragGesture(), isEnabled:)` aber an nichts Geteiltem mehr.
    let isCurrentPage: Bool
    /// Seiteneigen — Befund aus der Prüfung der letzten Nachbesserung: ein
    /// über alle Seiten geteilter `@Binding` ließ jede instanziierte Seite
    /// (auch eine von `TabView` nur zur Wischvorbereitung geladene
    /// Nachbarseite) denselben Zoomwert zeigen, und ein erneuter
    /// `.task`-Lauf einer fremden Seite (z. B. nach Speicherdruck neu
    /// aufgebaut) konnte den Zoom einer gerade aktiv gezoomten Seite
    /// zurücksetzen. Mit `@State` betrifft jede Änderung nur die eigene
    /// Seite. Die Wischsperre in `bildinhalt` liest genau diesen Wert und
    /// wirkt damit ebenfalls nur auf die eigene Seite.
    @State private var scale: CGFloat = 1.0

    @Environment(ConnectionManager.self) private var connection
    @Environment(\.modelContext) private var modelContext

    @State private var localImage: UIImage?
    /// Die geprüfte Originaldatei auf der Platte, sofern es sie gibt — einmal
    /// je Asset in `.task` ermittelt (siehe Kommentar am Typ). Foto- und
    /// Videozweig hängen beide daran; der Player bekommt sie durchgereicht.
    @State private var lokaleDatei: URL?
    /// Nur für Videoseiten gefüllt — die Bedienung, die das Telefon zeigt,
    /// während das Bild auf dem Fernseher läuft, braucht einen Titel.
    @State private var dateiname: String?
    @State private var pruefungAbgeschlossen = false
    @GestureState private var kneifSkalierung: CGFloat = 1.0

    var body: some View {
        Group {
            if eintrag.isVideo {
                // Falle (2) aus Schritt 3 des Plans, erste Hälfte: Der
                // Videozweig bekommt **weder** `scaleEffect` **noch**
                // `MagnifyGesture`. Ein Kneifen auf einem Video kann die
                // Wiedergabe damit gar nicht erst verzerren — und `scale`
                // bleibt für diese Seite unverändert 1. Die Wischsperre
                // stellt sich damit gar nicht: Sie hängt in `bildinhalt`, und
                // den gibt es auf einer Videoseite nicht.
                // Erst zeigen, wenn die Quellenwahl steht. Sonst gäbe es ein
                // kurzes Fenster, in dem ein Tipp auf den Startknopf noch mit
                // `lokaleDatei == nil` liefe und ein gepinntes Video vom
                // Server holte, obwohl es auf der Platte liegt — offline also
                // gar nicht. Der Bildzweig wartet aus demselben Grund
                // (`pruefungAbgeschlossen`), das ist hier nur dieselbe Regel
                // für die zweite Hälfte.
                if pruefungAbgeschlossen {
                    PhoneVideoPlayer(
                        assetId: assetId,
                        isCurrentPage: isCurrentPage,
                        lokaleDatei: lokaleDatei,
                        titel: dateiname
                    )
                } else {
                    ProgressView().tint(.white)
                }
            } else {
                bildinhalt
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Ersetzt das frühere `.onChange(of: currentIndex)` auf dem
        // `TabView` in `PhoneAssetView`: setzt den Zoom **dieser** Seite
        // zurück, sobald sie erscheint. `TabView(.page)` hält Nachbarseiten
        // als Vorschau vor, statt sie bei jedem Wisch neu zu erzeugen — eine
        // einmal gezoomte, dann verlassene Seite behielte ihren `@State`
        // also einfach bei, wenn man zu ihr zurückwischt. `.onAppear` statt
        // `.onDisappear`: Am Simulator geprüft, dass `.onAppear` beim
        // Zurückwischen zuverlässig genau einmal vor dem sichtbaren Zoom
        // feuert; `.onDisappear` ist beim `.page`-Stil weniger verlässlich,
        // weil TabView Nachbarseiten oft dauerhaft eingehängt lässt statt
        // sie beim Wegwischen abzuhängen — ein Zurücksetzen „beim Verlassen"
        // liefe dann Gefahr, gar nicht zu feuern. `.onAppear` garantiert
        // dagegen: bevor der Nutzer eine Seite sieht, ist sie ungezoomt.
        .onAppear {
            scale = 1
        }
        .task(id: assetId) {
            await bestimmeQuelle()
        }
    }

    /// Der Bildzweig — unverändert gegenüber dem Stand vor der Videowiedergabe,
    /// nur aus `body` herausgelöst, damit Zoom-Modifikatoren ausschließlich
    /// hier hängen und nicht über der Fallunterscheidung.
    @ViewBuilder
    private var bildinhalt: some View {
        Group {
            if let localImage {
                Image(uiImage: localImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if pruefungAbgeschlossen {
                remoteImage
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scaleEffect(scale * kneifSkalierung)
        // `.simultaneousGesture`, NICHT `.gesture`: Ein einfaches `.gesture(_:)`
        // verlangt von JEDEM Vorfahren-Gestenerkenner, erst das Scheitern
        // dieser Geste abzuwarten, bevor er selbst beginnen darf — auch wenn
        // beide völlig unterschiedliche Eingaben brauchen. Der eingebaute
        // Wisch-zum-Blättern-Erkenner des `TabView` (eine UIKit-Pan-Geste im
        // Hintergrund) wartete dadurch auf das Scheitern von `MagnifyGesture`
        // (braucht zwei Finger), und dieses Scheitern kommt bei einem
        // einfingrigen Wisch erst an, wenn die Berührung schon wieder endet —
        // zu spät, um noch zu blättern. Ein einfingriger Wisch blätterte also
        // nie um; erst `.simultaneousGesture` lässt beide Erkenner unabhängig
        // laufen.
        .simultaneousGesture(magnifyGesture)
        // **Die Wischsperre.** Solange gezoomt ist, schluckt dieser Zieher den
        // Wisch, statt dass eine Seite umblättert.
        //
        // `.gesture(_:)` und **nicht** `.simultaneousGesture(_:)` — hier ist
        // genau die Eigenschaft erwünscht, die zwei Zeilen weiter oben für die
        // Kneifgeste das Problem war: Ein `.gesture(_:)` verlangt von jedem
        // Vorfahren-Erkenner, erst das Scheitern dieser Geste abzuwarten. Der
        // Wisch-Erkenner des `.page`-`TabView` wartet also — und ein
        // einfingriger Zieher *scheitert nicht*, er beginnt. Damit kommt der
        // Erkenner des `TabView` nie an die Reihe.
        //
        // `isEnabled:` statt eines bedingt angehängten Modifikators: Der
        // Erkenner bleibt durchgehend hängen und wird nur scharf geschaltet.
        // Ein Anhängen/Abhängen mitten in einer laufenden Berührung wäre
        // wieder ein Eingriff zur Unzeit — genau die Klasse Fehler, die diese
        // Änderung beseitigt.
        //
        // **Warum überhaupt neu:** Der Vorgänger `PageScrollLock` suchte sich
        // die `UIScrollView` des `TabView` aus der Ansichtshierarchie und
        // schrieb dort `isScrollEnabled`. Eine `UIScrollView` bricht ihre
        // laufende Animation ab, sobald man dieses Kennzeichen anfasst — und
        // `updateUIView` läuft bei *jeder* Aktualisierung, also auch mitten im
        // Seitenwechsel. Zwei Nachbesserungen versuchten, den sicheren
        // Zeitpunkt aus `isDragging`, `isDecelerating` und `contentOffset`
        // abzuleiten; das Symptom wurde seltener, blieb aber. Der Grund ist
        // strukturell: Nach einem *sanften* Wisch schwingt die Ansicht zur
        // Seitengrenze ein, ohne dass eines dieser drei Merkmale es anzeigt —
        // es gibt also keinen ableitbaren sicheren Zeitpunkt. Ein Zieher, der
        // gar nicht erst schreibt, braucht auch keinen.
        //
        // **Die Videofalle ist damit strukturell weg**, nicht mehr per
        // ausgeschriebener Bedingung abgewehrt: Diese Zeile steht in
        // `bildinhalt`, und `bildinhalt` gibt es auf einer Videoseite nicht.
        // Der Vorgänger musste `!eintrag.isVideo` ausdrücklich schreiben, weil
        // er eine von *allen* Seiten geteilte `UIScrollView` umschaltete und
        // eine hängengebliebene Sperre den Nutzer im Video eingesperrt hätte.
        // Ein Erkenner gehört dagegen nur seiner eigenen Seite.
        .gesture(DragGesture(), isEnabled: scale > 1)
    }

    private var remoteImage: some View {
        LazyImage(url: connection.apiClient?.thumbnailURL(assetId: assetId, size: .preview)) { state in
            if let image = state.image {
                image.resizable().aspectRatio(contentMode: .fit)
            } else if state.error != nil {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.white.opacity(0.6))
            } else {
                ProgressView().tint(.white)
            }
        }
        .pipeline(connection.imagePipeline ?? .shared)
    }

    /// 1–4×, wie im Auftrag vorgegeben. `@GestureState` liefert den während
    /// der aktiven Geste flüchtigen Faktor, `scale` hält den zuletzt
    /// abgeschlossenen Stand — dasselbe Muster wie `magnifyGesture` auf dem
    /// Mac (`ImageDetailNavigation.swift`), dort AppKit-gebunden und deshalb
    /// nicht wiederverwendbar.
    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .updating($kneifSkalierung) { value, state, _ in
                state = value.magnification
            }
            .onEnded { value in
                scale = min(4, max(1, scale * value.magnification))
            }
    }

    /// Ermittelt einmal je Asset, woher es kommt, und lädt im Fotofall gleich
    /// das Bild von der Platte.
    ///
    /// Läuft aus `.task(id: assetId)`, also nicht bei jedem Neuzeichnen —
    /// die Begründung steht am Typ oben. Der `FetchDescriptor` folgt dem
    /// Muster von `PhoneAlbumDetailView.eintraege(fuer:)`.
    ///
    /// **Auch für Videos**, anders als zuvor: Der frühere Stand sprang für
    /// eine Videoseite sofort heraus, weil es nichts zu dekodieren gab — womit
    /// aber auch niemand nachsah, ob das Video auf der Platte liegt. Genau
    /// das braucht der Player jetzt (`lokaleDatei`). Dekodiert wird für ein
    /// Video weiterhin nichts: `heruntergerechnetesBild` ist ein
    /// `CGImageSource`-Pfad für Standbilder.
    private func bestimmeQuelle() async {
        localImage = nil
        lokaleDatei = nil
        dateiname = nil
        pruefungAbgeschlossen = false

        let id = assetId
        let datei = await lokaleOriginaldatei(fuer: id)
        lokaleDatei = datei

        // Der Player protokolliert seine Quelle selbst, und zwar erst beim
        // Start — dort wird sie tatsächlich benutzt. Hier eine zweite Zeile
        // je Videoseite zu schreiben, hieße im Protokoll zwei Einträge für
        // dasselbe Asset, von denen einer nur eine Absicht beschreibt.
        guard !eintrag.isVideo else {
            // Nur hier, nicht für Fotoseiten: Den Namen zeigt ausschließlich
            // die Bedienung am Zweitbildschirm (siehe `PhoneVideoPlayer`).
            dateiname = PhoneOriginaldatei.dateiname(assetId: id, context: modelContext)
            pruefungAbgeschlossen = true
            return
        }

        guard let quelle = standbildquelle(lokaleDatei: datei) else {
            // Weder Datei noch `apiClient`: `remoteImage` unten zeigt dann
            // seinen eigenen Leerzustand (LazyImage mit `nil`-URL), wie
            // bisher. Das ist kein stiller Ausfall mehr.
            AppLogger.library.error("Einzelbild \(id, privacy: .public): weder lokale Datei noch Serververbindung")
            pruefungAbgeschlossen = true
            return
        }

        AppLogger.library.info("Einzelbild \(id, privacy: .public): Quelle \(quelle.protokollName, privacy: .public)")

        if quelle.istLokal {
            localImage = await Self.heruntergerechnetesBild(bei: quelle.url, laengsteKante: Self.maxKantenlaenge)
            if localImage == nil {
                // Die Datei liegt da, ließ sich aber nicht dekodieren (halb
                // geschriebener Download, unbekanntes Format). `localImage`
                // bleibt nil, `bildinhalt` fällt damit auf `remoteImage`
                // zurück — dieses Verhalten stand hier schon, nur unbenannt.
                AppLogger.library.error("Einzelbild \(id, privacy: .public): lokale Datei nicht dekodierbar, Rückfall auf den Server")
            }
        }
        pruefungAbgeschlossen = true
    }

    /// Der eine SwiftData-Zugriff dieser Seite: `assetId` → `CachedAsset` →
    /// geprüfte Datei-URL. `localFileURL(forPath:)` gibt nur dann eine URL
    /// zurück, wenn die Datei wirklich auf der Platte liegt — genau die
    /// Vorprüfung, die `PhoneMediaSource.waehle` bewusst nicht selbst macht
    /// (siehe die Begründung dort).
    private func lokaleOriginaldatei(fuer id: String) async -> URL? {
        // Seit den Aktionen im Einzelbild stellt auch das Teilen dieselbe
        // Frage — deshalb liegt die Antwort in `PhoneOriginaldatei` und nicht
        // mehr hier, damit die beiden nicht auseinanderlaufen können.
        PhoneOriginaldatei.aufPlatte(assetId: id, context: modelContext)
    }

    /// Die Quelle fürs Standbild. `nil` heißt: Es gibt weder eine lokale Datei
    /// noch einen `apiClient` — dann existiert schlicht keine URL, aus der
    /// sich ein Bild holen ließe.
    ///
    /// Der `guard` ist kein Sonderweg um `waehle` herum: Ohne `apiClient` gibt
    /// es keine Fern-URL, die man übergeben könnte. Eine ausgedachte wäre
    /// schlimmer als keine.
    private func standbildquelle(lokaleDatei: URL?) -> PhoneMediaSource? {
        guard let apiClient = connection.apiClient else {
            return lokaleDatei.map { PhoneMediaSource.lokal($0) }
        }
        return .waehle(
            lokaleDatei: lokaleDatei,
            fernURL: apiClient.thumbnailURL(assetId: assetId, size: .preview),
            apiKey: apiClient.apiKey
        )
    }

    /// Obergrenze für die längste Kante beim Dekodieren einer lokalen
    /// Originaldatei — Befund aus der Prüfung von Task 6:
    /// `UIImage(contentsOfFile:)` dekodierte bislang das komplette Original.
    /// Bei einem 50-MP-Foto sind das grob 150–200 MB Bitmapdaten für **eine**
    /// `TabView`-Seite, und `TabView(.page)` hält Nachbarseiten vor — genau
    /// der Offline-Fall, für den diese Ansicht gebaut ist, arbeitet mit
    /// solchen Originalen.
    ///
    /// Herleitung: längste Bildschirmkante × Gerätefaktor. Ein iPhone 16 Pro
    /// Max misst 932 pt in der Höhe bei `UIScreen.main.scale == 3`, also
    /// ≈ 2796 px längste Kante im Hochformat. Großzügig aufgerundet auf
    /// 3000 px — reicht beim im Auftrag erlaubten vierfachen Zoom
    /// (`scale` in `magnifyGesture` unten, gedeckelt auf 4) noch für ein
    /// scharfes Bild, ohne beliebig hohe Sensorauflösungen mitzuschleppen.
    private static let maxKantenlaenge: CGFloat = 3000

    /// Dekodiert `url` direkt auf `laengsteKante` herunterskaliert statt in
    /// voller Auflösung — läuft dafür auf einem Hintergrundthread
    /// (`Task.detached`), denn auch das reine Dekodieren eines 50-MP-Originals
    /// blockierte den Hauptthread spürbar, bevor dieser Fix kam (derselbe
    /// Aufruf lag zuvor direkt im `@MainActor`-Kontext von `pruefeLokaleDatei`).
    /// `kCGImageSourceCreateThumbnailWithTransform` bäckt die EXIF-Ausrichtung
    /// in die Ausgabe-Pixel ein — sonst läge ein hochkant fotografiertes Bild
    /// nach dem Herunterskalieren seitlich verdreht da. Vergleichbares Muster
    /// wie `loadImage` in `Sources/ImmichMac/Views/ImageDetailSupport.swift:106`,
    /// dort für den vollaufgelösten Mac-Vollbildpfad.
    private static func heruntergerechnetesBild(bei url: URL, laengsteKante: CGFloat) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: laengsteKante
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return nil
            }
            return UIImage(cgImage: cgImage)
        }.value
    }
}
