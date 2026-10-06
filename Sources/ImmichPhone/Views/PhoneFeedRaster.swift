import SwiftUI

/// Das Tagesraster eines ``PhonePhotoFeed``: Kacheln, angeheftete
/// Tagesüberschriften, Nachladen, Rasterfuß und Einzelbild.
///
/// Aus `PhonePhotoFeedView` herausgelöst, damit der Orte-Reiter dasselbe Raster
/// zeigt, statt es nachzubauen. Gehört **in** ein `ScrollView`; Leerzustand,
/// Umschalter oder Filterleiste, Aktualisieren-Zug und `.task` bleiben bei der
/// aufrufenden Ansicht.
struct PhoneFeedRaster: View {

    var feed: PhonePhotoFeed
    let apiClient: ImmichAPIClient
    /// Offline fragt das Raster nicht nach — siehe `PhonePhotoFeedView.istOffline`.
    let istOffline: Bool

    @State private var praesentierterStartindex: PhoneAssetStartIndex?

    /// Dreispaltig mit 2 pt Abstand, exakt wie `PhoneAlbumDetailView`.
    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2)
    ]

    var body: some View {
        VStack {
            // `pinnedViews`, damit die Tagesüberschrift beim Scrollen stehen
            // bleibt, solange ihr Tag läuft.
            LazyVGrid(columns: columns, spacing: 2, pinnedViews: [.sectionHeaders]) {
                ForEach(feed.abschnitte) { abschnitt in
                    Section {
                        ForEach(abschnitt.kacheln) { kachel in
                            kachelButton(kachel)
                        }
                    } header: {
                        tagesUeberschrift(abschnitt.titel)
                    }
                }
            }
            .padding(.horizontal, 2)

            fuss
        }
        // Über die **flache** Liste, nicht über den Tagesabschnitt: Wischen im
        // Einzelbild läuft über Tagesgrenzen hinweg. Der Rückruf hält das
        // Raster beim Papierkorb gleich; den Stern meldet das Einzelbild app-weit.
        .fullScreenCover(item: $praesentierterStartindex) { start in
            PhoneAssetView(
                eintraege: feed.eintraege,
                start: start.index,
                onGeloescht: { id in Task { await feed.entferne(assetId: id) } }
                // Kein `onFavoritGeaendert`: Der Stern läuft über
                // ``PhoneFavoritMeldung`` und erreicht so **jeden** Feed.
            )
        }
    }

    private func kachelButton(_ kachel: PhoneFeedKachel) -> some View {
        Button {
            praesentierterStartindex = PhoneAssetStartIndex(index: kachel.flachIndex)
        } label: {
            PhoneGridTile(eintrag: kachel.eintrag)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(PhoneGridTile.beschriftung(fuer: kachel.eintrag))
        // Das Nachladen hängt an der Kachel, nicht am Rasterfuß: Ein Fuß unter
        // einer `LazyVGrid` erscheint erst, wenn das Raster fertig ausgelegt ist.
        // Die Sperre gegen Mehrfachläufe sitzt in `PhonePhotoFeed.ladeWeitere`.
        .onAppear {
            guard kachel.flachIndex >= feed.eintraege.count - PhonePhotoFeed.nachladeSchwelle else { return }
            Task {
                guard !istOffline else { return }
                await feed.ladeWeitere(apiClient: apiClient)
            }
        }
    }

    /// Immer eine Variable, nie ein `Text`-Literal — SwiftUI parst Literale als
    /// Markdown (siehe `PhoneAlbumTile`).
    private func tagesUeberschrift(_ titel: String) -> some View {
        HStack {
            Text(titel)
                .font(.subheadline.weight(.semibold))
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.bar)
    }

    /// Spinner, solange noch etwas kommt — oder die Fehlermeldung samt
    /// Wiederholung. Ein stiller Abbruch sähe sonst aus wie „mehr gibt es nicht".
    @ViewBuilder
    private var fuss: some View {
        if let fehler = feed.fehler, !feed.eintraege.isEmpty {
            VStack(spacing: 8) {
                Text(fehler)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Try Again") {
                    Task {
                        guard !istOffline else { return }
                        await feed.ladeWeitere(apiClient: apiClient)
                    }
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity)
            .padding(24)
        } else if feed.laedt && !feed.eintraege.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(24)
        }
    }
}
