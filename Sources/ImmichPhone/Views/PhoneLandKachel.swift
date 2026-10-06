import SwiftUI
import NukeUI

/// Eine Länderkachel der Übersicht: Titelbild (jüngstes Foto des Landes), Name,
/// Anzahl und Monat des letzten Fotos. Gebaut wie `PhoneAlbumTile`.
struct PhoneLandKachel: View {

    let land: PhoneOrtsLand

    @Environment(ConnectionManager.self) private var connection

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { titelbild }
                .clipShape(RoundedRectangle(cornerRadius: 10))
            Text(Laendernamen.anzeigename(fuer: land.name, sprache: .current))
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(PhoneOrtsTexts.landUntertitel(land))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private var titelbild: some View {
        if let id = land.titelbildId, let url = connection.apiClient?.thumbnailURL(assetId: id, size: .thumbnail) {
            // `.pipeline` gehört an die `LazyImage` selbst — bei NukeUI 12.8 eine
            // Instanzmethode, kein Umgebungsmodifier.
            LazyImage(url: url) { state in
                if let image = state.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    platzhalter
                }
            }
            .pipeline(connection.imagePipeline ?? .shared)
        } else {
            platzhalter
        }
    }

    private var platzhalter: some View {
        Rectangle()
            .fill(Marke.akzent.opacity(0.15))
            .overlay(Image(systemName: "map").foregroundStyle(Marke.akzent))
    }
}
