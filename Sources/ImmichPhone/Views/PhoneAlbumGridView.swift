import SwiftUI
import SwiftData

/// Albumraster: eigene und geteilte Alben als zweispaltige Kacheln mit
/// Titelbild, in drei Abschnitten — "Auf dem Telefon" (gepinnte Alben, nur
/// sichtbar wenn die Verbindung offline ist), dann "Meine Alben" und
/// "Geteilte Alben" wie `AlbumManager.albums` / `.sharedAlbums` sie schon
/// trennt. Ersetzt die rohe `PhoneAlbumListView`. Welches Album in welchen
/// Abschnitt fällt, rechnet `PhoneAlbumSections.berechnen` — bewusst außerhalb
/// dieser Ansicht, damit es prüfbar ist (`Tests/ImmichPhoneTests`).
///
/// Gespiegelte Smart Alben (Serveralben mit ✦-Präfix) stehen in einem eigenen
/// Abschnitt nach „Auf dem Telefon“ — nur, wenn es welche gibt. **Eine Ausnahme:**
/// Ist ein solches Album offline gepinnt, gewinnt „Auf dem Telefon“ (mit ✦ im
/// Namen). Die Begründung steht an der Rangfolge in `PhoneAlbumSections.berechnen`.
struct PhoneAlbumGridView: View {

    var albumManager: AlbumManager
    var offline: PhoneOfflineModel

    /// Unterscheidet "noch nichts geladen" von "der Server kennt keine Alben".
    /// Ohne das sähe der allererste Start — bevor der erste `loadAlbums()`
    /// zurückgekehrt ist — wie ein Fehler statt wie ein normaler Zwischenstand aus.
    var hasLoadedOnce: Bool

    /// Der Aktualisieren-Zug ruft ausschließlich das hier durchgereichte
    /// `PhoneRootView.reloadAlbumsAndWarmCovers(manager:apiClient:)` — dieselbe
    /// Abfolge (laden, Offline-Abzeichen neu ableiten, Titelbilder vorwärmen)
    /// wie beim Erstaufbau. Vorher rief `.refreshable` `albumManager.loadAlbums()`
    /// direkt und ließ dabei den Vorwärmer aus; genau der Zug, mit dem neue
    /// Alben und geänderte Titelbilder auftauchen, wärmte deren Bilder also nie
    /// vor. Die Abfolge selbst lebt bewusst nicht hier: `PhoneRootView` kennt
    /// `connection.apiClient` und den `coverPrefetcher`, dieses Raster nicht.
    var onRefresh: () async -> Void

    @Environment(ConnectionManager.self) private var connection
    @Environment(\.modelContext) private var modelContext

    @State private var suchtext = ""
    /// Album, für das gerade das Blatt „Offline speichern“ offen ist.
    @State private var offlineBlattAlbum: Album?

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    private var istLeer: Bool {
        albumManager.albums.isEmpty && albumManager.sharedAlbums.isEmpty
    }

    /// Die gesamte Auswahllogik der drei Abschnitte liegt in `PhoneAlbumSections`
    /// (reiner Wertetyp, ohne SwiftUI) und ist dort in
    /// `Tests/ImmichPhoneTests/PhoneAlbumSectionsTests.swift` geprüft — welcher
    /// Abschnitt was enthält, wie entdoppelt und wie gesucht wird, steht
    /// vollständig dort. Hier bleibt nur das Einsammeln der Eingaben.
    private var abschnitte: PhoneAlbumSections {
        PhoneAlbumSections.berechnen(
            eigene: albumManager.albums,
            geteilte: albumManager.sharedAlbums,
            abzeichen: offline.badges,
            suchtext: suchtext,
            istOffline: connection.state.isOffline
        )
    }

    /// Die Suche ist aktiv, findet aber in keinem Abschnitt etwas — anders als
    /// `istLeer` (der Server/Cache kennt keine Alben) braucht das einen eigenen
    /// Leerzustand, sonst behauptet die bestehende Meldung fehlende Serverdaten,
    /// wo tatsächlich nur der Suchbegriff nichts trifft.
    private func sucheOhneTreffer(_ abschnitte: PhoneAlbumSections) -> Bool {
        !suchtext.isEmpty && abschnitte.alleLeer
    }

    var body: some View {
        // Einmal gerechnet und an alle Stellen weitergereicht, statt vier Mal je
        // Neuzeichnen: dieselben Listen speisen Raster und Leerzustand.
        let abschnitte = self.abschnitte
        return NavigationStack {
            ScrollView {
                // Nur online und ohne Suchbegriff: Die Favoriten kommen direkt vom
                // Server, und eine Albumsuche soll nur Alben zeigen.
                if suchtext.isEmpty, !connection.state.isOffline, connection.apiClient != nil {
                    NavigationLink(value: PhoneFavoritenZiel()) {
                        PhoneFavoritenKachel()
                    }
                    .buttonStyle(.plain)
                    .padding([.horizontal, .top], 16)
                }
                LazyVGrid(columns: columns, spacing: 16) {
                    if !abschnitte.aufDemTelefon.isEmpty {
                        Section {
                            ForEach(abschnitte.aufDemTelefon) { album in tile(for: album) }
                        } header: {
                            sectionHeader(String(localized: "On This iPhone"))
                        }
                    }
                    // Nur mit gespiegelten Smart Alben (Mac-Client, Präfix „✦ “) —
                    // `PhoneAlbumSections` sortiert sie aus „Meine/Geteilte Alben“ heraus.
                    if !abschnitte.smart.isEmpty {
                        Section {
                            ForEach(abschnitte.smart) { album in
                                tile(for: album)
                            }
                        } header: {
                            sectionHeader(String(localized: "Smart Albums"))
                        }
                    }
                    if !abschnitte.eigene.isEmpty {
                        Section {
                            ForEach(abschnitte.eigene) { album in tile(for: album) }
                        } header: {
                            sectionHeader(String(localized: "My Albums"))
                        }
                    }
                    if !abschnitte.geteilte.isEmpty {
                        Section {
                            ForEach(abschnitte.geteilte) { album in tile(for: album) }
                        } header: {
                            sectionHeader(String(localized: "Shared Albums"))
                        }
                    }
                }
                .padding(16)
            }
            .searchable(text: $suchtext, prompt: Text("Search Albums"))
            // KEIN `.pipeline(...)` hier am Raster: Bei NukeUI 12.8 ist
            // `pipeline(_:)` eine Instanzmethode auf `LazyImage` selbst
            // (`LazyImage.swift:100`), kein Umgebungswert, den ein Vorfahre
            // für alle `LazyImage`s darunter setzen könnte — anders als der
            // Auftrag es beschrieb. Jede `PhoneAlbumTile` holt sich die
            // Pipeline stattdessen selbst aus der Umgebung, genau wie es die
            // fünf referenzierten Mac-Ansichten pro Bildansicht tun.
            // Als `.overlay` statt als Kachel im Rasterrumpf: Genau wie zuvor
            // in `PhoneAlbumListView` legt sich der Leerzustand nur optisch
            // über das (dann leere) Raster, das darunter samt `.refreshable`
            // erhalten bleibt.
            .overlay {
                if sucheOhneTreffer(abschnitte) {
                    keineTrefferState
                } else if istLeer {
                    emptyState
                }
            }
            // `safeAreaInset` statt einer Kachel im Rasterrumpf: Der Hinweis
            // erscheint und verschwindet mit `isActive`, ohne dass die
            // Kacheln darunter dabei nach oben/unten springen — ein
            // Abschnitt *in* der `LazyVGrid` würde bei jedem Wechsel die
            // Zeilenumbrüche aller folgenden Kacheln neu berechnen.
            // **Unten**, über der Reiterleiste: Oben schob der Einschub den
            // großen Titel „Albums“ aus dem Bild — übrig blieb ein leerer Block
            // von rund 180 pt über der Leiste (Praxistest).
            .safeAreaInset(edge: .bottom) {
                if OfflineSyncProgress.shared.isActive {
                    offlineProgressBanner
                }
            }
            .navigationTitle("Albums")
            .navigationDestination(for: Album.self) { album in
                PhoneAlbumDetailView(album: album, offline: offline)
            }
            .navigationDestination(for: PhoneFavoritenZiel.self) { _ in
                if let apiClient = connection.apiClient {
                    PhoneFavoritenView(apiClient: apiClient)
                }
            }
            .refreshable {
                await onRefresh()
            }
            .offlineBlatt(album: $offlineBlattAlbum, offline: offline)
            // Befund aus der Prüfung dieser Nachbesserung: `syncOfflineAlbums`
            // kehrt in mehreren Fällen zurück, bevor `isActive` je `true` wird
            // (getaktete Verbindung, ein Lauf läuft schon, nichts zu laden —
            // siehe `OfflineDownloadManager.swift`). Der `.onChange` unten
            // greift dann nicht, und ein still abgeschlossener Vermerk (aus
            // einem Lauf, der lief, während dieses Raster nicht sichtbar war)
            // bliebe bis zum nächsten `isActive`-Wechsel unsichtbar. Dieses
            // `.onAppear` holt ihn beim nächsten Erscheinen nach — ohne neue
            // Maschinerie, nur ein zusätzlicher Lesevorgang der ohnehin schon
            // vorhandenen Vermerke.
            .onAppear {
                offline.refresh(context: modelContext)
            }
            // Der (von `setPinned` intern per `Task.detached` gestartete)
            // Download-Lauf meldet sich nicht bei diesem Raster — er meldet
            // sich nur über `OfflineSyncProgress.shared`. Sobald `isActive`
            // auf `false` wechselt, ist der Lauf fertig (oder nie gestartet),
            // und die Abzeichen werden neu aus den Vermerken gelesen.
            .onChange(of: OfflineSyncProgress.shared.isActive) { _, isActive in
                if !isActive {
                    offline.refresh(context: modelContext)
                }
            }
        }
    }

    @ViewBuilder
    private func tile(for album: Album) -> some View {
        let badge = offline.badge(for: album.id)
        NavigationLink(value: album) {
            PhoneAlbumTile(album: album, badge: badge, coverURL: coverURL(for: album))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                guard let apiClient = connection.apiClient else { return }
                if badge == .cloud {
                    offlineBlattAlbum = album
                } else {
                    offline.gibFrei(album: album, context: modelContext, apiClient: apiClient)
                }
            } label: {
                if badge == .cloud {
                    Label("Keep Offline", systemImage: "icloud.and.arrow.down")
                } else {
                    Label("Remove Offline Copy", systemImage: "trash")
                }
            }
        }
    }

    /// Der laufende Offline-Durchgang am Rasterkopf. Dieselbe Ansicht benutzt
    /// das Albumdetail — siehe `PhoneOfflineProgressBanner`.
    private var offlineProgressBanner: some View {
        PhoneOfflineProgressBanner(fortschritt: OfflineSyncProgress.shared)
    }

    private func coverURL(for album: Album) -> URL? {
        guard let apiClient = connection.apiClient, let assetId = album.albumThumbnailAssetId else { return nil }
        return apiClient.thumbnailURL(assetId: assetId, size: .thumbnail)
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title).font(.title3.weight(.semibold))
            Spacer()
        }
        .padding(.top, 4)
    }

    /// Eigener Leerzustand für eine Suche ohne Treffer — der bestehende `emptyState`
    /// spricht über fehlende Serverdaten, was hier schlicht falsch wäre: Der Server/
    /// Cache kennt durchaus Alben, nur keines passt zum Suchbegriff.
    private var keineTrefferState: some View {
        ContentUnavailableView(
            "No Albums Found",
            systemImage: "magnifyingglass",
            description: Text("No album matches this search.")
        )
    }

    @ViewBuilder
    private var emptyState: some View {
        if hasLoadedOnce {
            // Befund aus der Prüfung dieser Nachbesserung: Offline mit leerem
            // Cache konnte niemand geprüft haben, ob der Server wirklich keine
            // Alben kennt — die Zeile behauptete das trotzdem. Unterscheidet
            // hier nach `connection.state`, ohne neuen Zustand im Enum.
            ContentUnavailableView(
                "No Albums",
                systemImage: "square.stack",
                description: Text(
                    connection.state.isOffline
                        ? String(localized: "No albums in the offline cache.")
                        : String(localized: "The server has no albums yet.")
                )
            )
        } else {
            ContentUnavailableView {
                ProgressView()
            } description: {
                Text("Loading albums…")
            }
        }
    }
}
