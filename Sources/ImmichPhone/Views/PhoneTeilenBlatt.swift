import SwiftUI
import UIKit

/// Das System-Teilenblatt für **eine** Datei.
///
/// **Warum ein `UIViewControllerRepresentable` und kein `ShareLink`:**
/// `ShareLink` will den Gegenstand schon beim Zeichnen des Knopfes haben. Die
/// Datei steht hier aber erst nach dem Tippen fest — im Offline-Fall kommt sie
/// aus dem lokalen Cache, sonst muss sie erst vom Server geladen werden (siehe
/// `PhoneAssetView.teile(_:)`). Ein `ShareLink`, der beim Zeichnen bereits
/// jedes sichtbare Original herunterlüde, wäre genau das Gegenteil dessen, was
/// die Ansicht sonst tut.
///
/// Bewusst eine **Datei-URL**, kein `UIImage`: Wer teilt, will das Original mit
/// seinen EXIF-Daten und in seinem Format (auch ein Video), nicht ein neu
/// kodiertes JPEG in Bildschirmgröße.
struct PhoneTeilenBlatt: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    /// Nichts zu aktualisieren: Das Blatt bekommt seine Datei bei der
    /// Erzeugung, und `PhoneAssetView` erzeugt für jede Datei ein neues (der
    /// `PhoneTeilenGegenstand` trägt eine frische `UUID`, `.sheet(item:)`
    /// baut also neu auf, statt dieses hier umzuhängen).
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}
