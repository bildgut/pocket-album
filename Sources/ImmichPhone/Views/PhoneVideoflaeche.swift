import AVFoundation
import SwiftUI
import UIKit

/// Das nackte Videobild eines `AVPlayer` — ohne Transportleiste, ohne
/// Einblendungen, ohne alles.
///
/// **Warum nicht `VideoPlayer` aus AVKit.** Der bringt eine Transportleiste
/// mit, die sich weder abschalten noch dauerhaft verbergen lässt. Auf dem
/// Telefon ist das genau richtig und wird dort auch weiter benutzt; auf dem
/// Zweitbildschirm wäre es ein Bild von einer Bedienung, die niemand berühren
/// kann — die Szene läuft in der Rolle
/// `windowExternalDisplayNonInteractive`, dort gibt es keine Berührungen.
/// Schlimmer noch: AVKit blendet die Leiste bei jedem Zustandswechsel kurz
/// ein, der Fernseher bekäme also mitten in der Vorführung Knöpfe übers Bild.
/// `AVPlayerLayer` zeichnet ausschließlich Videobilder und hat keine
/// Bedienung, die man erst wegkonfigurieren müsste.
///
/// **`.resizeAspect`, nicht `.resizeAspectFill`** — dieselbe Überlegung wie
/// beim Foto in `PhoneZweitbildschirmView`: Auf einem Fernseher zählt das
/// ganze Bild, und schwarze Balken sind auf schwarzem Grund nicht zu sehen.
/// Ein beschnittenes Hochformatvideo verlöre Köpfe.
struct PhoneVideoflaeche: UIViewRepresentable {

    let spieler: AVPlayer

    func makeUIView(context: Context) -> PhoneVideoflaechenAnsicht {
        let ansicht = PhoneVideoflaechenAnsicht()
        ansicht.backgroundColor = .black
        ansicht.spielerEbene.videoGravity = .resizeAspect
        ansicht.spielerEbene.player = spieler
        return ansicht
    }

    func updateUIView(_ ansicht: PhoneVideoflaechenAnsicht, context: Context) {
        // Identitätsvergleich, nicht bedingungsloses Zuweisen: `AVPlayerLayer`
        // baut beim Setzen von `player` seine Wiedergabekette neu auf, und
        // `updateUIView` läuft bei jeder Aktualisierung der umgebenden Ansicht
        // — bei jedem Tick der Bühne also einmal. Bedingungslos gesetzt
        // stotterte das Bild auf dem Fernseher.
        if ansicht.spielerEbene.player !== spieler {
            ansicht.spielerEbene.player = spieler
        }
    }

    /// Beim Abbau die Ebene vom Player lösen.
    ///
    /// Das ist kein Aufräumen um des Aufräumens willen: Solange eine
    /// `AVPlayerLayer` einen Player hält, hat sie eine Meinung darüber, wohin
    /// dessen Bild geht. Bleibt eine abgehängte Ebene daran, kann derselbe
    /// Player auf dem Telefon nicht sauber weiterzeichnen — genau der Fall,
    /// wenn der Zweitbildschirm mitten in der Wiedergabe abgezogen wird.
    static func dismantleUIView(_ ansicht: PhoneVideoflaechenAnsicht, coordinator: ()) {
        ansicht.spielerEbene.player = nil
    }
}

/// Eine `UIView`, deren Ebene eine `AVPlayerLayer` **ist**.
///
/// Der Umweg über `layerClass` statt einer als Unterebene eingehängten
/// `AVPlayerLayer` spart das Nachführen von Hand: Die Ebene bekommt die
/// Abmessungen der Ansicht vom Layoutsystem, ohne dass irgendwo ein
/// `layoutSubviews` `frame` schreiben müsste — und ohne das ruckelt sie beim
/// Drehen um einen Rahmen hinterher.
final class PhoneVideoflaechenAnsicht: UIView {

    override static var layerClass: AnyClass { AVPlayerLayer.self }

    /// Sichere Umschrift: `layerClass` oben legt den Typ fest, den UIKit
    /// erzeugt — ein anderer kann hier nicht ankommen.
    var spielerEbene: AVPlayerLayer {
        // swiftlint:disable:next force_cast
        layer as! AVPlayerLayer
    }

    /// Die zuletzt protokollierte Geometrie. `layoutSubviews` läuft oft; ohne
    /// diesen Merker stünde dieselbe Zeile hundertfach im Protokoll.
    private var zuletztProtokolliert: CGRect = .null

    /// Schreibt einmal je Größenänderung auf, in wie vielen Pixeln das
    /// Videobild hier tatsächlich landet.
    ///
    /// **Wozu.** Die Gegenprobe zu ``PhoneZweitbildschirmSzenenDelegat`` und
    /// dem Bericht über zackige Kanten: Dort steht, wie groß die Szene ist,
    /// hier, wie groß das Videobild darin ist — und wie groß die Quelle
    /// überhaupt ist (`presentationSize`, die Pixelmaße des Videos). Ein
    /// 4K-Video in einer Fläche von 1920×1080 px zu zeigen ist in Ordnung; ein
    /// 1080p-Video in einer Fläche von 960×540 px wäre der behebbare Fall.
    ///
    /// Auslesen ohne Xcode:
    /// `log stream --predicate 'subsystem == "com.ralksta.immichmac"' --info`
    override func layoutSubviews() {
        super.layoutSubviews()
        let bildRahmen = spielerEbene.videoRect
        guard bildRahmen != zuletztProtokolliert, bildRahmen.width > 0 else { return }
        zuletztProtokolliert = bildRahmen
        let massstab = spielerEbene.contentsScale
        let quelle = spielerEbene.player?.currentItem?.presentationSize ?? .zero
        AppLogger.app.info(
            "Videofläche: Ebene \(Int(self.bounds.width), privacy: .public)x\(Int(self.bounds.height), privacy: .public) pt bei contentsScale \(massstab, privacy: .public), Videobild \(Int(bildRahmen.width * massstab), privacy: .public)x\(Int(bildRahmen.height * massstab), privacy: .public) px, Quelle \(Int(quelle.width), privacy: .public)x\(Int(quelle.height), privacy: .public) px"
        )
    }
}
