import AVFoundation
import UIKit

/// Das Standbild eines Videos, aus der **lokalen Datei** statt vom Server.
///
/// Bewusst ein eigener, von SwiftUI unabhängiger Einstieg: Als privates
/// `.task` in `PhoneVideoPlayer` ließe sich genau der Teil nicht prüfen, der
/// hier heikel ist — dass `AVAssetImageGenerator` an einer echten Datei
/// überhaupt ein Bild liefert und an allem anderen ruhig `nil` statt eines
/// Absturzes. Siehe `Tests/ImmichPhoneTests/PhoneVideoPosterTests.swift`.
enum PhoneVideoPoster {

    /// Ein Bild aus dem Anfang von `datei`, oder `nil`.
    ///
    /// `nil` heißt hier immer „kein Bild", nie „Absturz": eine fehlende Datei,
    /// eine Datei ohne Videospur und ein unbekannter Codec landen alle im
    /// `catch`. Das ist der Punkt gegenüber einem `try!` — die Datei kommt aus
    /// dem Offline-Cache und kann ein halb geschriebener Download sein.
    static func bild(fuer datei: URL, maximaleKante: CGFloat = 3000) async -> UIImage? {
        let asset = AVURLAsset(url: datei)
        let generator = AVAssetImageGenerator(asset: asset)

        // **Warum `appliesPreferredTrackTransform`.** Ein hochkant
        // aufgenommenes Video speichert seine Bilder quer und trägt die
        // Drehung als Transformation an der Videospur. Ohne dieses Flag käme
        // genau dieses quer liegende Rohbild heraus — und zwar auf einer
        // Seite, deren Wiedergabe danach aufrecht startet, weil `AVPlayer` die
        // Transformation von sich aus auswertet. Das Standbild spränge beim
        // Antippen um 90 Grad. Belegt in `PhoneVideoPosterTests`
        // (`hochkantWirdGedreht`), nicht nur behauptet. Dieselbe Rolle, die
        // `kCGImageSourceCreateThumbnailWithTransform` im Bildzweig von
        // `PhoneAssetView` für die EXIF-Ausrichtung spielt.
        generator.appliesPreferredTrackTransform = true

        // Dieselbe Obergrenze und dieselbe Begründung wie
        // `PhoneAssetView.maxKantenlaenge`: Ein 4K-Bild in voller Auflösung
        // wäre für ein Standbild hinter einem Startknopf verschwendeter
        // Speicher, und `TabView(.page)` hält Nachbarseiten vor. Sie
        // *begrenzt* nur — ein kleineres Video wird nicht hochskaliert.
        generator.maximumSize = CGSize(width: maximaleKante, height: maximaleKante)

        do {
            // Die Standardtoleranzen sind bewusst nicht enger gesetzt: Sie
            // erlauben dem Generator, das nächstgelegene Schlüsselbild zu
            // nehmen, statt bis zum exakten Zeitpunkt zu dekodieren. Für ein
            // Vorschaubild ist das der richtige Tausch.
            let (cgImage, _) = try await generator.image(at: .zero)
            return UIImage(cgImage: cgImage)
        } catch {
            // Kein `throw`: Der Aufrufer hat für diesen Fall bereits einen
            // Weg — das Vorschaubild vom Server. Ein Fehler, der bis in die
            // Ansicht durchschlüge, hätte dort nur wieder in ein `nil`
            // zurückverwandelt werden müssen.
            AppLogger.library.error(
                "Standbild aus lokaler Datei fehlgeschlagen: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }
}
