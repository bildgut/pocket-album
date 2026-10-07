import SwiftUI
import SwiftData

/// Ladezustand des Albumdetails. Assets als schmale Einträge — für das Raster
/// und die Navigation ins Einzelbild genügt das; EXIF, Name usw. lädt hier
/// niemand.
enum PhoneAlbumDetailState {
    case laedt
    case assets([PhoneAlbumGridEintrag])
    case leer
    case fehler(String)
}

/// Was eine Rasterkachel über ihr Asset wissen muss: die Kennung fürs
/// Thumbnail und fürs Einzelbild, und ob dort ein Video liegt — dann trägt die
/// Kachel ein Abzeichen mit der Laufzeit.
///
/// Bewusst kein `Asset`: Das Raster lud bisher nur IDs, und dabei bleibt es
/// weitgehend — EXIF, Name, Personen holt hier niemand. `isVideo` und
/// `duration` sind die zwei Felder, ohne die ein Video im Raster nicht von
/// einem Foto zu unterscheiden wäre.
///
/// `isFavorite` kam mit den Aktionen im Einzelbild dazu: Der Stern dort muss
/// beim Öffnen schon den richtigen Zustand zeigen, und die einzige Angabe, die
/// beide Wege (Albumdetail und Fotos-Reiter) ohnehin in der Hand haben, ist
/// die aus der Liste, die sie gebaut haben. Ein Nachschlagen je Einzelbild
/// wäre eine zusätzliche Serverabfrage für ein einzelnes Bit.
struct PhoneAlbumGridEintrag: Identifiable, Hashable {
    let id: String
    let isVideo: Bool
    /// Rohform des Servers (`"HH:MM:SS.mmm"`), gekürzt erst in der Anzeige —
    /// siehe `VideoDuration.kurzform`.
    let duration: String?
    let isFavorite: Bool

    init(id: String, isVideo: Bool = false, duration: String? = nil, isFavorite: Bool = false) {
        self.id = id
        self.isVideo = isVideo
        self.duration = duration
        self.isFavorite = isFavorite
    }

    init(asset: Asset) {
        self.init(
            id: asset.id,
            isVideo: asset.isVideo,
            duration: asset.duration,
            isFavorite: asset.isFavorite
        )
    }

    /// Derselbe Eintrag mit anderem Sternzustand — die Listen oben sind
    /// Wertetypen, ein Setzen von Hand an drei Stellen wäre drei Gelegenheiten,
    /// ein Feld zu vergessen.
    func mitFavorit(_ ist: Bool) -> PhoneAlbumGridEintrag {
        PhoneAlbumGridEintrag(id: id, isVideo: isVideo, duration: duration, isFavorite: ist)
    }
}

/// Albumdetail: dreispaltiges Raster quadratischer Thumbnails, Kopf mit Name,
/// Anzahl und Offline-Schaltfläche. Tippen auf eine Kachel öffnet
/// `PhoneAssetView` im Vollbild, gestartet an genau diesem Index.
///
/// **Laden:** online zuerst `getAlbumAssets` — liefert die volle, aktuelle
/// Reihenfolge. Schlägt das fehl, oder ist der Server laut `ConnectionManager`
/// ohnehin nicht erreichbar (`.offline`, siehe `PhoneRootView`s Weiche, die
/// diese Ansicht überhaupt erst erreichbar macht), fallen wir auf die in
/// `CachedAlbum.assetIds` vermerkten IDs zurück. Für das Raster reicht das:
/// Jede Kachel lädt ihr Thumbnail selbst (Nuke-Diskcache), das Einzelbild holt
/// sich sein Original bei Bedarf aus `LocalFileCacheManager` — siehe
/// `PhoneAssetView`.
struct PhoneAlbumDetailView: View {
    let album: Album
    var offline: PhoneOfflineModel

    @Environment(ConnectionManager.self) private var connection
    @Environment(\.modelContext) private var modelContext

    @State private var state: PhoneAlbumDetailState = .laedt
    @State private var praesentierterStartindex: PhoneAssetStartIndex?
    @State private var zeigtDiashow = false
    /// Gesetzt, solange das Blatt „Offline speichern“ offen ist.
    @State private var offlineBlattAlbum: Album?

    private let columns = PhoneRasterSpalten.fotos

    private var badge: OfflineBadge { offline.badge(for: album.id) }

    /// Hielt der letzte Lauf dieses Albums vor einer Datei an, weil das Netz teuer
    /// ist und das Album nicht über Mobilfunk laden darf?
    private var wartetAufWLAN: Bool {
        OfflineSyncProgress.shared.wartetAufWLAN.contains(OfflinePin.pinId(kind: .album, targetId: album.id))
    }

    /// Der Text stand hier einmal als „Wartet auf WLAN oder auf den nächsten
    /// Durchgang" — und war an beiden Hälften falsch.
    ///
    /// Die zweite Hälfte versprach etwas, das es auf dem Telefon **nicht gibt**:
    /// `syncOfflineAlbums` wird hier ausschließlich durch das Antippen des
    /// Nutzers ausgelöst. Es gibt keinen `SyncEngine`, keinen Timer und keine
    /// Hintergrundaufgabe — das ist alles PR 2c und ungebaut. Ein Album, dessen
    /// einziger Lauf nicht durchkam, bliebe für immer stehen.
    ///
    /// Die erste Hälfte war unbelegbar: `OfflineDownloadManager.isMetered` ist
    /// `private`. Statt eine Ursache zu raten, sagt die Ansicht jetzt nur, was
    /// sie weiß — es fehlen noch Dateien — und bietet den einzigen Weg an, der
    /// auf diesem Gerät überhaupt existiert: es noch einmal anstoßen.
    ///
    /// Dass diese Meldung überhaupt so oft zu sehen war, lag an einer anderen
    /// Stelle: `isActive` wurde erst gesetzt, wenn die Dateiliste feststand,
    /// also nach dem Auflösen der Albumzugehörigkeit über die API. Für die
    /// Ansicht sah ein längst laufender Download aus wie gar keiner. Das ist in
    /// `OfflineDownloadManager` behoben; diese Meldung erscheint seither nur
    /// noch, wenn wirklich nichts läuft.
    private var zeigtUnvollstaendig: Bool {
        badge == .pending && !OfflineSyncProgress.shared.isActive
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                // Bis hierher zeigte das Detail einen laufenden Durchgang gar
                // nicht an — wer *hier* ein Album offline nahm, sah nichts,
                // obwohl im Hintergrund Dateien liefen.
                if OfflineSyncProgress.shared.isActive {
                    PhoneOfflineProgressBanner(fortschritt: OfflineSyncProgress.shared)
                }
                if zeigtUnvollstaendig {
                    HStack(spacing: 8) {
                        // Immer eine Variable, nie ein Literal — SwiftUI parst
                        // Text-Literale als Markdown (siehe `PhoneAlbumTile`).
                        Text(wartetAufWLAN ? Self.wartetText : Self.unvollstaendigText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        // „Jetzt laden“ gibt nur **dieses** Album für Mobilfunk frei;
                        // „Erneut versuchen“ achtet weiter auf die Wahl jedes Albums.
                        Button(wartetAufWLAN ? Self.jetztLadenText : Self.erneutText) {
                            stosseLaufAn(mobilfunkFreigeben: wartetAufWLAN)
                        }
                            .font(.caption.weight(.semibold))
                            .buttonStyle(.borderless)
                    }
                    .padding(.horizontal, 16)
                }
                content(for: state)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task(id: album.id) {
            await load()
        }
        .offlineBlatt(album: $offlineBlattAlbum, offline: offline)
        // Wie in `PhoneAlbumGridView`: `syncOfflineAlbums` kann zurückkehren,
        // ohne `OfflineSyncProgress.isActive` je auf `true` zu setzen (getaktete
        // Verbindung, laufender Lauf, nichts zu laden). Ohne dieses `.onAppear`
        // bliebe das Abzeichen im Kopf hier auf dem letzten Stand beim Öffnen
        // dieser Ansicht stehen, auch wenn ein Lauf inzwischen still fertig wurde.
        .onAppear {
            offline.refresh(context: modelContext)
        }
        .fullScreenCover(item: $praesentierterStartindex) { start in
            if case .assets(let eintraege) = state {
                PhoneAssetView(
                    eintraege: eintraege,
                    start: start.index,
                    onGeloescht: { entferne(assetId: $0) },
                    onFavoritGeaendert: { setzeFavorit(assetId: $0, ist: $1) }
                )
            }
        }
    }

    @ViewBuilder
    private func content(for state: PhoneAlbumDetailState) -> some View {
        switch state {
        case .laedt:
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
        case .assets(let eintraege):
            grid(eintraege: eintraege)
        case .leer:
            // Befund aus der Prüfung dieser Nachbesserung: `.leer` deckt auch
            // den Offline-Fall ohne Cache ab (siehe `loadFromCache`) — dort hat
            // niemand geprüft, ob das Album wirklich leer ist, nur dass nichts
            // vorliegt. "Dieses Album ist leer" wäre dann eine unbelegte
            // Behauptung über den Server.
            ContentUnavailableView(
                "No Photos",
                systemImage: "photo.on.rectangle",
                description: Text(
                    connection.state.isOffline
                        ? String(localized: "No photos in the offline cache for this album.")
                        : String(localized: "This album is empty.")
                )
            )
            .padding(.top, 40)
        case .fehler(let meldung):
            ContentUnavailableView(
                "Album Unavailable",
                systemImage: "exclamationmark.triangle",
                description: Text(meldung)
            )
            .padding(.top, 40)
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                // Immer eine Variable, nie ein Text-Literal — siehe
                // `PhoneAlbumTile`: ein Literal, das wie eine URL aussieht,
                // würde SwiftUI als Markdown-Link parsen.
                //
                // Über `anzeigename`, damit ein gespiegeltes Smart Album auch
                // hier ohne `✦` steht. Das Präfix ist eine Marke des
                // Spiegel-Dienstes (`SmartAlbumMirrorService`), keine
                // Information für den Leser — und es an einer Stelle zu zeigen
                // und an der anderen nicht, wäre die schlechteste der drei
                // Möglichkeiten. Nicht-Smart-Alben gibt die Funktion unverändert
                // zurück, der Aufruf ist hier also unbedenklich.
                Text(PhoneAlbumSections.anzeigename(fuer: album))
                    .font(.title2.weight(.bold))
                Text(assetCountText).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            diashowButton
            offlineButton
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        // Sitzt am Kopf und nicht am `ScrollView` wie der zweite
        // Vollbildvorhang (`praesentierterStartindex`): Zwei
        // `.fullScreenCover` an derselben Ansicht sind eine bekannte Quelle
        // dafür, dass einer von beiden stumm nicht aufgeht.
        .fullScreenCover(isPresented: $zeigtDiashow) {
            // Der Name wird nur gebraucht, wenn ein Zweitbildschirm hängt und
            // das Telefon zur Fernbedienung wird — siehe `PhoneDiashowRolle`.
            PhoneDiashowView(eintraege: diashowEintraege, albumName: album.albumName)
        }
    }

    /// Die Liste, mit der die Diashow startet — genau die, die auch das Raster
    /// zeigt, in derselben Reihenfolge. Videos bleiben darin; sie auszulassen
    /// ist Sache von `PhoneDiashowFolge` (Begründung dort).
    private var diashowEintraege: [PhoneAlbumGridEintrag] {
        if case .assets(let eintraege) = state { return eintraege }
        return []
    }

    /// Startet die Diashow — für die Bildschirmsynchronisierung auf einen
    /// Apple TV, siehe `PhoneDiashowView`. Nur sichtbar, wenn überhaupt etwas
    /// geladen ist: Ein Knopf, der in eine schwarze Fläche führt, wäre
    /// schlechter als keiner.
    @ViewBuilder
    private var diashowButton: some View {
        if case .assets = state {
            Button {
                zeigtDiashow = true
            } label: {
                Image(systemName: "play.rectangle")
                    .font(.body.weight(.semibold))
                    .padding(8)
                    .background(.thinMaterial, in: Circle())
            }
            .accessibilityLabel(Self.diashowLabel)
        }
    }

    private static let diashowLabel = String(localized: "Start Slideshow")

    private static let unvollstaendigText = String(localized: "Not fully downloaded yet.")
    private static let erneutText = String(localized: "Try Again")
    private static let wartetText = String(localized: "Waiting for Wi-Fi.")
    private static let jetztLadenText = String(localized: "Download Now")

    /// Der einzige Weg, einen Lauf auf dem Telefon nachzuholen. `force: true`
    /// überspringt das Wartefenster. Die Netzregel bleibt an: Früher lief dieser
    /// Anstoß mit `respectMetered: false` und lud damit **jedes** gepinnte Album
    /// über Mobilfunk, auch solche, deren Wahl „nur WLAN“ sagt — und blieb für den
    /// ganzen Lauf ohne Prüfung, auch wenn man unterwegs das WLAN verließ.
    /// `mobilfunkFreigeben` („Jetzt laden“) gibt nur dieses Album frei.
    private func stosseLaufAn(mobilfunkFreigeben: Bool) {
        guard let apiClient = connection.apiClient else { return }
        let container = modelContext.container
        let freigabe: Set<String> = mobilfunkFreigeben
            ? [OfflinePin.pinId(kind: .album, targetId: album.id)] : []
        Task.detached(priority: .userInitiated) {
            await OfflineDownloadManager.shared.syncOfflineAlbums(
                container: container,
                apiClient: apiClient,
                force: true,
                mobilfunkFreigabe: freigabe
            )
        }
    }

    private var assetCountText: String {
        if case .assets(let eintraege) = state {
            return String(localized: "\(eintraege.count) photos")
        }
        return String(localized: "\(album.assetCount) photos")
    }

    /// Dieselbe Aktion wie das Kontextmenü im Raster
    /// (`PhoneAlbumGridView.tile(for:)`) — ein no-op ohne `apiClient`, genau
    /// wie dort.
    private var offlineButton: some View {
        Button {
            guard let apiClient = connection.apiClient else { return }
            if badge == .cloud {
                offlineBlattAlbum = album
            } else {
                offline.gibFrei(album: album, context: modelContext, apiClient: apiClient)
            }
        } label: {
            Image(systemName: badge.symbolName)
                .font(.body.weight(.semibold))
                .padding(8)
                .background(.thinMaterial, in: Circle())
        }
        .accessibilityLabel(badge.label)
    }

    @ViewBuilder
    private func grid(eintraege: [PhoneAlbumGridEintrag]) -> some View {
        LazyVGrid(columns: columns, spacing: 2) {
            ForEach(Array(eintraege.enumerated()), id: \.offset) { index, eintrag in
                Button {
                    praesentierterStartindex = PhoneAssetStartIndex(index: index)
                } label: {
                    PhoneGridTile(eintrag: eintrag)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(PhoneGridTile.beschriftung(fuer: eintrag))
            }
        }
        .padding(.horizontal, 2)
    }

    private func load() async {
        // `canBrowse` (die Voraussetzung, unter der `PhoneRootView` diese
        // Ansicht überhaupt zeigt) ist `isConnected || isOffline` — hier bleibt
        // also nur die Unterscheidung zwischen den beiden.
        guard let apiClient = connection.apiClient, connection.state.isConnected else {
            loadFromCache()
            return
        }
        do {
            let assets = try await apiClient.getAlbumAssets(albumId: album.id)
            state = assets.isEmpty ? .leer : .assets(assets.map(PhoneAlbumGridEintrag.init(asset:)))
        } catch {
            loadFromCache(fehlermeldung: error.localizedDescription)
        }
    }

    private func loadFromCache(fehlermeldung: String? = nil) {
        let albumId = album.id
        let descriptor = FetchDescriptor<CachedAlbum>(
            predicate: #Predicate<CachedAlbum> { $0.albumId == albumId }
        )
        guard let cached = try? modelContext.fetch(descriptor).first, !cached.assetIds.isEmpty else {
            // Kein Netz UND nichts im Cache: bei einem echten Fehler ist das
            // ein Fehlerzustand, im schlichten Offline-Fall (Server nicht
            // erreichbar, Album nie gepinnt) ist "leer" die ehrlichere
            // Beschreibung — der Nutzer hat sich fürs Offline-Stöbern
            // entschieden, das ist kein Absturz.
            state = fehlermeldung.map { .fehler($0) } ?? .leer
            return
        }
        state = .assets(eintraege(fuer: cached.assetIds))
    }

    /// Offline-Pfad: `CachedAlbum` vermerkt nur die Reihenfolge der IDs, den
    /// Medientyp hält `CachedAsset`. Ein Nachschlagen in einem Rutsch, statt je
    /// Kachel einer — was nicht im Cache liegt, gilt als Foto: Ein Abzeichen
    /// zu setzen, ohne den Typ zu kennen, wäre eine Behauptung, das Weglassen
    /// ist nur eine fehlende Auszeichnung.
    private func eintraege(fuer ids: [String]) -> [PhoneAlbumGridEintrag] {
        let descriptor = FetchDescriptor<CachedAsset>(
            predicate: #Predicate<CachedAsset> { ids.contains($0.assetId) }
        )
        guard let cachedAssets = try? modelContext.fetch(descriptor) else {
            return ids.map { PhoneAlbumGridEintrag(id: $0) }
        }
        let nachTyp = Dictionary(
            cachedAssets.map { ($0.assetId, ($0.type, $0.duration, $0.isFavorite)) },
            uniquingKeysWith: { first, _ in first }
        )
        return ids.map { id in
            guard let (typ, dauer, favorit) = nachTyp[id] else { return PhoneAlbumGridEintrag(id: id) }
            return PhoneAlbumGridEintrag(
                id: id,
                isVideo: typ == AssetType.video.rawValue,
                duration: dauer,
                isFavorite: favorit
            )
        }
    }

    /// Ein im Einzelbild in den Papierkorb gelegtes Asset verschwindet hier
    /// sofort aus dem Raster.
    ///
    /// **Warum ein Rückruf und keine Benachrichtigung:** Auf dem Telefon gibt es
    /// (Stand PR 2b) weder `SyncEngine` noch die `.assetsDidChange`-Verdrahtung
    /// des Mac-Clients — eine Notification hätte hier gar keinen Empfänger, sie
    /// müsste erst einen bekommen. Und der einzige Interessent ist ohnehin genau
    /// die Ansicht, die das Einzelbild geöffnet hat: Sie hält die Liste, aus der
    /// das Asset fallen soll. Ein direkter Rückruf sagt das, eine Notification
    /// verstreute es über den Prozess.
    private func entferne(assetId: String) {
        guard case .assets(var liste) = state else { return }
        liste.removeAll { $0.id == assetId }
        // `.leer` statt einer leeren `.assets`-Liste, damit der Leerzustand
        // greift, den `content(for:)` ohnehin schon zeichnet.
        state = liste.isEmpty ? .leer : .assets(liste)
    }

    /// Hält den Sternzustand der Liste mit dem Einzelbild gleich — sonst zeigte
    /// ein zweites Öffnen desselben Fotos den alten Stand, bis `load()` wieder
    /// lief.
    private func setzeFavorit(assetId: String, ist: Bool) {
        guard case .assets(var liste) = state,
              let index = liste.firstIndex(where: { $0.id == assetId }) else { return }
        liste[index] = liste[index].mitFavorit(ist)
        state = .assets(liste)
    }
}

/// `Int` ist nicht `Identifiable` — `.fullScreenCover(item:)` braucht das aber,
/// um zwischen "kein Einzelbild offen" und "Index 0 offen" zu unterscheiden
/// (ein simples `Bool` + separater `@State var index` könnte beides
/// auseinanderlaufen lassen).
struct PhoneAssetStartIndex: Identifiable {
    let index: Int
    var id: Int { index }
}
