import SwiftUI

/// Ziel der Favoriten-Kachel im Albumraster. Ein eigener Typ statt eines
/// `String`-Werts, damit `navigationDestination(for:)` nicht mit anderen
/// Zeichenketten-Zielen kollidiert.
struct PhoneFavoritenZiel: Hashable {}

/// Die Kachel „Favoriten“ über den Albumabschnitten. Breit statt quadratisch:
/// Als erste Rasterzelle stünde sie neben dem ersten Album eines Abschnitts
/// und risse dessen Überschrift auseinander.
struct PhoneFavoritenKachel: View {
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "star.fill")
                .font(.title2)
                .foregroundStyle(Theme.favorite)
                .frame(width: 52, height: 52)
                .background(Theme.favorite.opacity(0.15), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(PhoneOrtsTexts.favoriten)
                .font(.headline)
                .foregroundStyle(.primary)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(Rectangle())
    }
}

/// Alle Favoriten als Raster mit Tagesüberschriften — derselbe `PhonePhotoFeed`
/// wie im Reiter „Fotos“, nur mit der Auswahl „nur Favoriten“. Kein eigener
/// Such- oder Lade-Code: Der Filter `isFavorite` steckt schon in
/// ``PhoneSuchAuswahl/searchFilter(type:)``.
///
/// Der Feed gehört dieser Ansicht (`@State`), nicht `PhoneRootView`: Die
/// Favoriten sind ein Ziel im Alben-Stapel, kein Reiter, und sollen beim
/// Wiederkommen frisch sein — ein gerade entfernter Stern wäre sonst noch da.
struct PhoneFavoritenView: View {

    let apiClient: ImmichAPIClient

    @Environment(ConnectionManager.self) private var connection
    @State private var feed = PhonePhotoFeed()

    private var istOffline: Bool { connection.state.isOffline }

    var body: some View {
        ScrollView {
            PhoneFeedRaster(feed: feed, apiClient: apiClient, istOffline: istOffline)
        }
        .navigationTitle(PhoneOrtsTexts.favoriten)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if feed.abschnitte.isEmpty { leerzustand }
        }
        .refreshable {
            await feed.ladeVonVorne(apiClient: apiClient)
        }
        .task(id: apiClient.baseURL) {
            guard !istOffline else { return }
            await feed.setzeAuswahl(PhoneSuchAuswahl.leer.mitFavoriten(true), apiClient: apiClient)
        }
    }

    @ViewBuilder
    private var leerzustand: some View {
        if istOffline {
            ContentUnavailableView(
                "Offline",
                systemImage: "airplane",
                description: Text("Favorites load directly from the server.")
            )
        } else if let fehler = feed.fehler {
            ContentUnavailableView(
                "Favorites Unavailable",
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
            ContentUnavailableView(
                "No Favorites",
                systemImage: "star",
                description: Text("Tap the star on a photo to find it here.")
            )
        } else {
            ContentUnavailableView {
                ProgressView()
            } description: {
                Text("Loading favorites…")
            }
        }
    }
}
