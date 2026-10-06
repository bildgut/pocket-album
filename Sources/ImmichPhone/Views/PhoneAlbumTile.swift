import SwiftUI
import NukeUI

/// Eine Kachel im Albumraster: quadratisches Titelbild, Offline-Abzeichen in
/// der Ecke, Name und Anzahl darunter. Reiner Wertetyp ohne eigenen Zugriff
/// auf `AlbumManager`/`PhoneOfflineModel` — `PhoneAlbumGridView` reicht Bild-URL
/// und Abzeichen fertig berechnet herein, damit die Kachel unabhängig vom
/// Offline-Modell bleibt. Die Nuke-Pipeline holt sich die Kachel dagegen
/// selbst aus der Umgebung — siehe Kommentar unten, warum das genau hier
/// passieren muss.
struct PhoneAlbumTile: View {
    let album: Album
    let badge: OfflineBadge
    let coverURL: URL?

    // `.pipeline(_:)` ist bei NukeUI 12.8 eine Instanzmethode auf `LazyImage`
    // selbst (`LazyImage.swift:100`, gibt `Self` zurück), kein
    // Umgebungs-Modifikator, den ein Vorfahre wie `ScrollView` für alle
    // `LazyImage`s darunter setzen könnte — NukeUI liest dafür nichts aus der
    // Umgebung. Genau deshalb holt sich jede der fünf Mac-Ansichten (z. B.
    // `PeopleView.favoritePersonCard`, `PeopleView.swift:257`) die Pipeline
    // selbst per `@Environment(ConnectionManager.self)` und hängt `.pipeline`
    // direkt an ihre eigene `LazyImage` — dasselbe Muster hier.
    @Environment(ConnectionManager.self) private var connection

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                // NICHT `cover.frame(maxWidth: .infinity).aspectRatio(1, contentMode:
                // .fill)` (so im Auftrag skizziert): In einem `LazyVGrid` mit zwei
                // `.flexible()`-Spalten bekommt die Kachel keine feste Höhenvorgabe —
                // `.aspectRatio(_:contentMode: .fill)` darf dann wachsen, um sein
                // Zielverhältnis zu erfüllen, und riss die Spaltenbreite im
                // Simulator sichtbar auf (Kacheln landeten in völlig
                // unterschiedlichen Breiten statt zweispaltig gleich breit).
                // `GeometryReader` erzwingt stattdessen ein echtes Quadrat aus der
                // tatsächlich zugeteilten Spaltenbreite — das übliche, verlässliche
                // Muster für quadratische Rasterkacheln.
                GeometryReader { geo in
                    cover
                        .frame(width: geo.size.width, height: geo.size.width)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .aspectRatio(1, contentMode: .fit)
                Image(systemName: badge.symbolName)
                    .font(.caption.weight(.semibold))
                    .padding(6)
                    .background(.thinMaterial, in: Circle())
                    .padding(8)
                    .accessibilityLabel(badge.label)
            }
            // Der Albumname ist immer eine Variable, nie ein Text-Literal —
            // ein Literal, das wie eine URL oder E-Mail aussieht, würde SwiftUI
            // als Markdown-Link parsen und Taps auf die Kachel schlucken.
            // Immer über `anzeigename`, nie roh: Das ✦ ist eine Marke des
            // Spiegel-Dienstes und gehört nirgends auf den Bildschirm — auch
            // nicht im Abschnitt "Auf dem Telefon", wo ein gepinntes Smart
            // Album erscheint. Früher stand hier eine optionale Überschreibung,
            // die nur der Smart-Reiter setzte; damit gab es zwei Regeln für
            // dieselbe Beschriftung, und eine davon war an jeder neuen
            // Aufrufstelle zu vergessen. Nicht-Smart-Alben gibt die Funktion
            // unverändert zurück.
            Text(PhoneAlbumSections.anzeigename(fuer: album))
                .font(.subheadline.weight(.medium)).lineLimit(2)
            Text(album.assetCount.formatted()).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var cover: some View {
        if let coverURL {
            LazyImage(url: coverURL) { state in
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
        Rectangle().fill(Marke.akzent.opacity(0.15))
            .overlay(Image(systemName: "photo.on.rectangle").foregroundStyle(Marke.akzent))
    }
}
