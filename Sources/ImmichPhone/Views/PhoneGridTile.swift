import SwiftUI
import NukeUI

/// Eine quadratische Rasterkachel: Thumbnail, Platzhalter solange nichts da ist,
/// und bei einem Video das Abzeichen mit der Laufzeit.
///
/// Wörtlich aus `PhoneAlbumDetailView` herausgelöst (dort vormals `tile(eintrag:)`,
/// `videoAbzeichen(dauer:)`, `platzhalter` und `accessibilityLabel(for:)`), weil
/// der Reiter „Fotos" dieselbe Kachel zeigt. Zwei Kopien derselben ~90 Zeilen
/// wären zwei Stellen, an denen ein künftiger Fix am Videoabzeichen ausbleiben
/// kann. Am Verhalten ändert sich dabei nichts — die Beschriftung setzen beide
/// Aufrufer weiterhin selbst an ihrem Button (`beschriftung(fuer:)`), nicht hier
/// an der Kachel, damit der Treffertest bleibt, wo er war.
struct PhoneGridTile: View {

    let eintrag: PhoneAlbumGridEintrag

    @Environment(ConnectionManager.self) private var connection

    var body: some View {
        if let url = connection.apiClient?.thumbnailURL(assetId: eintrag.id, size: .thumbnail) {
            GeometryReader { geo in
                LazyImage(url: url) { imgState in
                    if let image = imgState.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else if let fehler = imgState.error {
                        // Der Platzhalter steht auch dann, wenn das Thumbnail
                        // dauerhaft **fehlt** — für den Nutzer sieht ein Asset
                        // ohne Vorschau dann aus wie eines, das gerade lädt.
                        // Beobachtet bei Videos, die der Server nicht in
                        // Vorschaugröße vorhält: leere Kachel, obwohl das Video
                        // einwandfrei spielt. Wenigstens im Protokoll soll das
                        // eine Spur hinterlassen, statt still zu bleiben.
                        //
                        // Der `.task` hängt bewusst **nur** am Fehlerzweig: An
                        // den Platzhalter allgemein gehängt, liefe er für jede
                        // gerade ladende Kachel einmal leer — in einem Raster
                        // mit hunderten Kacheln also hunderte Leerläufe.
                        //
                        // Nicht mehr direkt `AppLogger`, und nicht mehr
                        // `localizedDescription`: Das eine ergab 250 Zeilen in
                        // 10 Minuten, das andere warf genau die Auskunft weg,
                        // die man dafür braucht („error 0" statt „HTTP 404").
                        // Beides erklärt ``ThumbnailFehlerDrossel``.
                        Self.platzhalter
                            .task(id: eintrag.id) {
                                ThumbnailFehlerJournal.melde(
                                    assetId: eintrag.id,
                                    fehler: fehler,
                                    // Was die App selbst über ihre Verbindung
                                    // denkt — die Kachel richtet sich nicht
                                    // danach, aber das Protokoll soll die
                                    // Frage „war das Gerät offline?" künftig
                                    // selbst beantworten können.
                                    zustand: connection.state
                                )
                            }
                    } else {
                        Self.platzhalter
                    }
                }
                .pipeline(connection.imagePipeline ?? .shared)
                .frame(width: geo.size.width, height: geo.size.width)
                .clipped()
                .overlay(alignment: .bottomTrailing) {
                    if eintrag.isVideo {
                        Self.videoAbzeichen(dauer: VideoDuration.kurzform(eintrag.duration))
                    }
                }
            }
            .aspectRatio(1, contentMode: .fit)
        } else {
            Self.platzhalter
                .aspectRatio(1, contentMode: .fit)
                .overlay(alignment: .bottomTrailing) {
                    if eintrag.isVideo {
                        Self.videoAbzeichen(dauer: VideoDuration.kurzform(eintrag.duration))
                    }
                }
        }
    }

    /// Kennzeichnung einer Videokachel: Symbol und, sofern die Serverangabe
    /// lesbar war, die Laufzeit.
    ///
    /// **Lesbarkeit ohne volle Fläche:** Statt eines Balkens liegt ein
    /// Verlauf von durchsichtig nach dunkel über der unteren Kante — auf einem
    /// hellen Bild trägt er die weiße Schrift, auf einem dunklen fällt er kaum
    /// auf, und in beiden Fällen bleibt das Thumbnail sichtbar. Der zusätzliche
    /// Schatten fängt den Fall ab, dass unten im Bild selbst etwas sehr Helles
    /// liegt. Weiß und Schwarz sind hier keine Themenfarben, sondern die
    /// Werkzeuge der Lesbarkeit — `Marke.akzent` bliebe auf beliebigen Fotos
    /// gerade nicht zuverlässig lesbar.
    @ViewBuilder
    static func videoAbzeichen(dauer: String?) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "play.fill")
                // Bewusst `.caption2` und keine feste Punktgröße: Die Zahl
                // daneben wächst mit den Textgrößen mit, ein `size: 9` täte es
                // nicht — bei Barrierefreiheits-Schriftgrößen liefen Symbol und
                // Zeit sonst auseinander, und die Zeile überragte den Verlauf,
                // auf den sie sich für den Kontrast verlässt.
                .font(.caption2.weight(.bold))
            if let dauer {
                // Wie im Kopf: immer eine Variable, nie ein Literal — SwiftUI
                // parst Text-Literale als Markdown.
                Text(dauer)
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.6), radius: 1.5, y: 0.5)
        .padding(.horizontal, 5)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .background(alignment: .bottom) {
            LinearGradient(
                colors: [.clear, .black.opacity(0.45)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 28)
            .allowsHitTesting(false)
        }
    }

    /// Setzen die Aufrufer an ihrem Button, nicht diese Kachel an sich selbst —
    /// siehe Kommentar am Typ.
    static func beschriftung(fuer eintrag: PhoneAlbumGridEintrag) -> String {
        guard eintrag.isVideo else { return String(localized: "Photo") }
        guard let dauer = VideoDuration.kurzform(eintrag.duration) else { return String(localized: "Video") }
        return String(localized: "Video, \(dauer)")
    }

    static var platzhalter: some View {
        Rectangle().fill(Marke.akzent.opacity(0.12))
    }
}
