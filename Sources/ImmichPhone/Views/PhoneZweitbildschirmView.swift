import AVFoundation
import SwiftUI

/// Was auf dem Fernseher steht: schwarzer Grund, Foto eingepasst, sonst
/// nichts.
///
/// **Bewusst ohne jedes Bedienelement.** Die Szene läuft in der Rolle
/// `windowExternalDisplayNonInteractive` — es gibt dort niemanden, der tippen
/// könnte. Ein Knopf wäre ein Bild von einem Knopf.
///
/// **`.fit`, nicht `.fill`** — dieselbe Überlegung wie in `PhoneDiashowView`:
/// Auf einem Fernseher zählt das ganze Bild, und schwarze Balken sind auf
/// schwarzem Grund nicht zu sehen. Ein beschnittenes Hochformat verlöre Köpfe.
///
/// **Video vor Bild.** Läuft ein `AVPlayer` auf der Bühne, zeichnet diese
/// Ansicht dessen Bild statt eines Standbilds — über `PhoneVideoflaeche`, also
/// eine nackte `AVPlayerLayer` ohne Transportleiste (Begründung dort). Die
/// Daten holt weiterhin das Telefon; hier kommen nur Pixel an. Das ist der
/// ganze Grund, warum es das gibt: Bei nativem AirPlay holte sich der Apple TV
/// die Datei selbst — ohne unseren API-Schlüssel, also mit schwarzem Bild.
///
/// **Der Ruhezustand ist kein Versehen.** Solange die Zweitbildschirm-Szene
/// hängt, zeigt der Fernseher *diese* Ansicht — auch dann, wenn gerade keine
/// Diashow läuft und der Nutzer nur durch seine Alben blättert. Bliebe sie
/// dann einfach schwarz, sähe das nach einem Defekt aus. Deshalb der Hinweis.
struct PhoneZweitbildschirmView: View {

    let buehne: PhoneBuehne

    // Immer Konstanten, nie Text-Literale: SwiftUI parst `Text`-Literale als
    // Markdown (siehe `PhoneAlbumTile`).
    private static let ruheTitel = "Immich"
    private static let ruheText = String(localized: "Start a slideshow or a video on your iPhone.")

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let spieler = buehne.spieler {
                // Vorrang vor dem Standbild — siehe „Video vor Bild" oben.
                // Ohne `.animation` und ohne `.transition`: Ein Videobild
                // überblendet man nicht, das gäbe beim Start einen sichtbaren
                // Schleier über dem ersten Halbbild.
                PhoneVideoflaeche(spieler: spieler)
                    .ignoresSafeArea()
            } else if let bild = buehne.bild {
                Image(uiImage: bild)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .ignoresSafeArea()
                    // Der Wechsel wird überblendet, damit der Fernseher nicht
                    // hart umschaltet. Der Schlüssel ist das Bild selbst — ein
                    // Index steht hier nicht zur Verfügung, die Bühne kennt
                    // nur das, was zu sehen sein soll.
                    .transition(.opacity)
                    .id(ObjectIdentifier(bild))
            } else {
                ruhezustand
            }
        }
        .animation(.easeInOut(duration: 0.35), value: buehne.bild)
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
    }

    private var ruhezustand: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(Marke.akzent)
            Text(Self.ruheTitel)
                .font(.largeTitle.weight(.semibold))
                .foregroundStyle(.white)
            Text(Self.ruheText)
                .font(.title3)
                .foregroundStyle(.white.opacity(0.6))
        }
    }
}
