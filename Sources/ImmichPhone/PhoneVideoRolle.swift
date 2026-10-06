import Foundation

/// Wo das Videobild landet — auf dem Telefon selbst oder auf dem
/// Zweitbildschirm — und was daraus für den laufenden `AVPlayer` folgt.
///
/// **Warum überhaupt ein eigener Wertetyp.** Derselbe Schnitt wie bei
/// ``PhoneDiashowRolle``: `PhoneVideoPlayer` ist eine Ansicht mit einem
/// `AVPlayer` darin, die Zweitbildschirm-Szene eine `UIScene` — an beidem
/// lässt sich in einem Testlauf nichts prüfen, und einen Apple TV kann weder
/// dieser Rechner noch der Simulator herstellen. Prüfbar ist genau die Frage
/// dazwischen: *Was folgt daraus, dass ein Zweitbildschirm hängt — und was
/// folgt daraus, dass sich das während der Wiedergabe ändert?*
///
/// **Warum das Videobild überhaupt umzieht.** Bei nativem AirPlay holt sich
/// der Apple TV die Datei selbst vom Immich-Server. Unser API-Schlüssel steht
/// in einer HTTP-Kopfzeile (``PhoneMediaSource/avAssetOptions``), und die
/// überlebt den Weg zum Empfänger nicht — der Fernseher fragt ohne Schlüssel
/// und bekommt eine Abfuhr, also ein schwarzes Bild. Zeichnen wir das Video
/// dagegen selbst in die Zweitbildschirm-Szene, streamt das Telefon (mit
/// Schlüssel) und der Fernseher zeigt nur noch Pixel. Ein **offline** auf der
/// Platte liegendes Video läuft damit sogar ganz ohne Server.
enum PhoneVideoRolle: Equatable, Sendable {

    /// Kein Zweitbildschirm: Das Telefon zeigt das Video selbst, mit der
    /// Transportleiste von AVKit. Das ist der Zustand, in dem der Player bis
    /// hierher immer lief.
    case aufDemTelefon

    /// Ein Zweitbildschirm hängt: Das Videobild steht dort, das Telefon zeigt
    /// stattdessen eine Bedienung.
    case aufDerBuehne

    static func fuer(zweitbildschirmAngeschlossen: Bool) -> PhoneVideoRolle {
        zweitbildschirmAngeschlossen ? .aufDerBuehne : .aufDemTelefon
    }

    /// Zeigt das Telefon das Videobild? Nur ohne Zweitbildschirm — sonst
    /// liefe dasselbe Bild zweimal dekodiert, und die Bedienung hätte keinen
    /// Platz.
    var zeigtVideoAufTelefon: Bool { self == .aufDemTelefon }

    /// Zeigt das Telefon stattdessen Knöpfe? Genau das Gegenstück; steht
    /// trotzdem als eigene Eigenschaft da, damit im Body keine Verneinung
    /// gelesen werden muss.
    var zeigtBedienungAufTelefon: Bool { self == .aufDerBuehne }

    /// Liegt der Player auf der ``PhoneBuehne``?
    var speistBuehne: Bool { self == .aufDerBuehne }

    /// Was mit dem laufenden Player zu geschehen hat, wenn sich die Rolle
    /// ändert.
    ///
    /// **Warum das hier steht und nicht als `if` im `onChange`.** Es ist die
    /// Stelle, an der Ton weiterlaufen kann, während niemand mehr hinsieht:
    /// Ein Player, der auf der Bühne liegen bleibt, obwohl die Szene weg ist,
    /// hält eine zweite starke Referenz und stirbt nicht mit der Ansicht.
    /// Deshalb hat der Fall einen Namen und einen Test.
    enum Buehnenschritt: Equatable, Sendable {
        /// Nichts zu tun — kein Player, oder die Rolle ist dieselbe geblieben.
        case nichts
        /// Player auf die Bühne legen.
        case uebergeben
        /// Player von der Bühne zurücknehmen.
        case zuruecknehmen
    }

    /// - Parameter spielerVorhanden: Ob gerade überhaupt ein `AVPlayer`
    ///   existiert. Ohne ihn gibt es nichts zu übergeben — und ein
    ///   `zuruecknehmen` ins Leere wäre zwar harmlos, aber eine Aussage, die
    ///   nicht stimmt.
    static func schritt(
        von alt: PhoneVideoRolle,
        nach neu: PhoneVideoRolle,
        spielerVorhanden: Bool
    ) -> Buehnenschritt {
        guard spielerVorhanden, alt != neu else { return .nichts }
        return neu.speistBuehne ? .uebergeben : .zuruecknehmen
    }
}
