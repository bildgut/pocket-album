import SwiftUI
import SwiftData

/// Ziel der Kachel „Letzte N Tage“ im Albumraster.
struct PhoneZuletztZiel: Hashable {}

/// Die Kachel „Letzte N Tage“ über den Albumabschnitten — breit wie die
/// Favoriten-Kachel, aus demselben Grund (siehe `PhoneFavoritenKachel`). Steht auch
/// ohne Netz da: Genau dann ist sie der Zweck der Funktion.
struct PhoneZuletztKachel: View {
    let stand: PhoneZuletztStand

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: OfflinePinKind.zuletzt.iconName)
                .font(.title2)
                .foregroundStyle(Marke.akzent)
                .frame(width: 52, height: 52)
                .background(Marke.akzent.opacity(0.15), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(stand.titel)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(String(localized: "\(stand.anzahl) photos"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: stand.badge.symbolName)
                .foregroundStyle(.secondary)
                .accessibilityLabel(stand.badge.label)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(Rectangle())
    }
}

/// Die Fotos von „Letzte Tage offline“ als Raster, neueste zuerst.
///
/// Liest ausschließlich die Mitgliedschaft des Vermerks und `CachedAsset` — kein
/// Netz. Das ist Absicht: Die Ansicht soll ohne Verbindung genauso aussehen wie mit.
/// Neue Fotos kommen mit dem nächsten Offline-Lauf (Start, Vordergrund).
struct PhoneZuletztView: View {
    var offline: PhoneOfflineModel

    var body: some View {
        PhoneZuletztInhalt(offline: offline)
            .navigationTitle(offline.zuletzt?.titel ?? PhoneZuletztStand.titel(tage: 0))
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// Das Raster selbst — auch der Reiter „Fotos“ zeigt es ohne Netz, statt nur
/// „Offline“ zu melden (Gerätebefund 14.10.2026).
struct PhoneZuletztInhalt: View {
    /// Ohne Modell (Fotos-Reiter) entfällt nur das Nachführen der Abzeichen.
    var offline: PhoneOfflineModel?

    @Environment(\.modelContext) private var modelContext
    @State private var eintraege: [PhoneAlbumGridEintrag] = []
    @State private var geladen = false
    @State private var praesentierterStartindex: PhoneAssetStartIndex?

    private let columns = PhoneRasterSpalten.fotos

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(Array(eintraege.enumerated()), id: \.element.id) { index, eintrag in
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
        .overlay {
            if geladen && eintraege.isEmpty {
                ContentUnavailableView(
                    "No Photos",
                    systemImage: OfflinePinKind.zuletzt.iconName,
                    description: Text(String(localized: "No photos taken in this period yet."))
                )
            }
        }
        .onAppear { lade() }
        .onChange(of: OfflineSyncProgress.shared.isActive) { _, aktiv in
            if !aktiv {
                offline?.refresh(context: modelContext)
                lade()
            }
        }
        .fullScreenCover(item: $praesentierterStartindex) { start in
            PhoneAssetView(
                eintraege: eintraege,
                start: start.index,
                onGeloescht: { id in eintraege.removeAll { $0.id == id } },
                onFavoritGeaendert: { id, ist in
                    if let i = eintraege.firstIndex(where: { $0.id == id }) {
                        eintraege[i] = eintraege[i].mitFavorit(ist)
                    }
                }
            )
        }
    }

    private func lade() {
        defer { geladen = true }
        guard let pin = OfflinePinStore.pin(kind: .zuletzt, targetId: ZuletztOffline.targetId, in: modelContext) else {
            eintraege = []
            return
        }
        let ids = pin.assetIds
        let descriptor = FetchDescriptor<CachedAsset>(
            predicate: #Predicate<CachedAsset> { ids.contains($0.assetId) && $0.isTrashed == false }
        )
        let assets = (try? modelContext.fetch(descriptor)) ?? []
        eintraege = assets
            .sorted { $0.fileCreatedAt != $1.fileCreatedAt ? $0.fileCreatedAt > $1.fileCreatedAt : $0.assetId < $1.assetId }
            .map {
                PhoneAlbumGridEintrag(
                    id: $0.assetId,
                    isVideo: $0.type == AssetType.video.rawValue,
                    duration: $0.duration,
                    isFavorite: $0.isFavorite
                )
            }
    }
}
