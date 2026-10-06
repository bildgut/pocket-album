import AVFoundation
import Observation
import UIKit

/// Was auf dem Zweitbildschirm steht — und ob überhaupt einer hängt.
///
/// **Warum ein Einzelstück und nicht die SwiftUI-Umgebung.** Der
/// Zweitbildschirm ist eine eigene `UIScene` mit eigenem `UIWindow` (siehe
/// ``PhoneZweitbildschirmSzenenDelegat``). Sie wird von UIKit aufgebaut, nicht
/// von der `WindowGroup` des Telefons — es gibt zwischen beiden Szenen keine
/// gemeinsame `Environment`-Kette, durch die sich etwas durchreichen ließe.
/// Ein `@Observable`-Einzelstück ist die schmalste Brücke, die beide Seiten
/// erreichen: Die Diashow legt das Bild hier ab, die Zweitbildschirm-Ansicht
/// liest es, und weil der Typ `@Observable` ist, zeichnet sie sich von selbst
/// neu.
///
/// **Warum ein fertiges `UIImage` und keine URL.** Die Zweitbildschirm-Szene
/// hat weder `ConnectionManager` noch Nuke-Pipeline in der Hand — beides hängt
/// an der Telefonszene. Ein fertig dekodiertes Bild braucht auf der anderen
/// Seite gar nichts: kein Netz, keinen API-Schlüssel, keinen Ladezustand. Die
/// Ansicht dort ist damit so dumm, wie sie sein soll (schwarzer Grund, Bild
/// eingepasst, sonst nichts), und der ganze Ladepfad bleibt an genau der
/// Stelle, an der er ohnehin schon steht.
///
/// **Warum daneben ein `AVPlayer` steht und kein zweites fertiges Bild.** Für
/// ein Video gibt es nichts „fertig Dekodiertes" zum Ablegen — es ist ein
/// laufender Strom. Der Player selbst wandert deshalb herüber, und die
/// Zweitbildschirm-Ansicht hängt ihn nur an eine `AVPlayerLayer`. Das ist der
/// ganze Unterschied zum Bild: Die Daten holt weiterhin das Telefon (mit
/// API-Schlüssel in der Kopfzeile, oder gleich von der Platte), der Fernseher
/// bekommt Pixel. Genau das kann nativer AirPlay nicht — dort fragt der Apple
/// TV den Server selbst, ohne unseren Schlüssel.
///
/// **Der Player gehört der Bühne nicht.** Er gehört ``PhoneVideoPlayer``; die
/// Bühne hält nur, solange er dort zu sehen ist, eine zweite starke Referenz.
/// Deshalb gibt es zum Ablegen ein Gegenstück (``nimmSpielerZurueck(_:)``),
/// das der Eigentümer selbst ruft, und deshalb prüft es die Identität: Ein
/// verspätetes Aufräumen darf keinen inzwischen aufgelegten *anderen* Player
/// von der Bühne fegen.
///
/// **Warum gezählt wird.** ``szenen`` ist ein Zähler und kein `Bool`, aus
/// demselben Grund wie bei ``PhoneRuhemodus``: Beim Umschalten der Quelle kann
/// eine neue Szene verbunden werden, bevor die alte getrennt ist. Ein `Bool`
/// stünde danach auf `false`, obwohl noch ein Bildschirm hängt.
@MainActor
@Observable
final class PhoneBuehne {

    /// Das eine Exemplar. Beide Szenen greifen darauf zu; ein zweites gäbe es
    /// nur zum Zweck, aneinander vorbeizureden.
    static let geteilt = PhoneBuehne()

    /// Wie viele Zweitbildschirm-Szenen gerade verbunden sind. In der Praxis 0
    /// oder 1 — iOS gibt einer App genau eine nicht-interaktive
    /// Zweitbildschirm-Szene.
    private(set) var szenen = 0

    /// Das Bild, das der Zweitbildschirm zeigen soll. `nil` heißt: schwarz mit
    /// Hinweis, siehe `PhoneZweitbildschirmView`.
    private(set) var bild: UIImage?

    /// Der Player, dessen Bild der Zweitbildschirm zeigen soll — `nil`, solange
    /// kein Video läuft. Hat Vorrang vor ``bild``: Diashow und Videowiedergabe
    /// können sich in der App nicht überschneiden (die eine ist ein
    /// Vollbild-Blatt über der Albumliste, die andere eine Seite im
    /// Einzelbild), aber falls doch je ein Rest stehen bliebe, ist ein
    /// laufendes Video das, was der Nutzer gerade angefordert hat.
    private(set) var spieler: AVPlayer?

    /// Hängt ein Zweitbildschirm? Einziger Eingang von
    /// ``PhoneDiashowRolle/fuer(zweitbildschirmAngeschlossen:)``.
    var angeschlossen: Bool { szenen > 0 }

    private init() {}

    func szeneKam() {
        szenen += 1
        AppLogger.app.info("Zweitbildschirm verbunden (\(self.szenen, privacy: .public) Szene(n))")
    }

    func szeneGing() {
        szenen = max(0, szenen - 1)
        AppLogger.app.info("Zweitbildschirm getrennt (\(self.szenen, privacy: .public) Szene(n))")
        // Kein Bild ohne Bildschirm: Sonst hielte die App eine Bitmap von
        // mehreren Megabyte fest, die niemand mehr sieht.
        //
        // Und kein Player ohne Bildschirm, aus dem stärkeren Grund: Die zweite
        // starke Referenz hier hielte ihn am Leben, auch wenn `PhoneVideoPlayer`
        // ihn längst fallen gelassen hat — der Ton liefe weiter, während der
        // Nutzer schon weitergewischt ist. `PhoneVideoPlayer` merkt den Wegfall
        // an ``angeschlossen`` und zeigt das Video wieder auf dem Telefon.
        if szenen == 0 {
            bild = nil
            spieler = nil
        }
    }

    func zeige(_ neues: UIImage) {
        bild = neues
    }

    /// Legt den Player auf die Bühne. Aufrufer ist ``PhoneVideoPlayer``, und
    /// zwar nur dann, wenn ein Zweitbildschirm hängt.
    func zeige(spieler neuer: AVPlayer) {
        spieler = neuer
        AppLogger.app.info("Video auf den Zweitbildschirm übergeben")
    }

    /// Nimmt den Player wieder herunter — vom Eigentümer gerufen, wenn er ihn
    /// beendet oder wenn kein Zweitbildschirm mehr hängt.
    ///
    /// **Die Identitätsprüfung ist der Sinn der Sache.** Ohne sie könnte ein
    /// verspätetes `beende()` der vorigen Seite den Player der nächsten von der
    /// Bühne nehmen; der Fernseher fiele mitten in einer laufenden Wiedergabe
    /// auf den Hinweis zurück. Dass zu jedem Zeitpunkt höchstens ein `AVPlayer`
    /// existiert (siehe Falle (1) in ``PhoneVideoPlayer``), macht den Fall
    /// unwahrscheinlich — nicht unmöglich, denn die Reihenfolge von
    /// `onChange`-Läufen zweier `TabView`-Seiten steht nirgends zu.
    func nimmSpielerZurueck(_ welcher: AVPlayer) {
        guard spieler === welcher else { return }
        spieler = nil
        AppLogger.app.info("Video vom Zweitbildschirm zurückgenommen")
    }

    /// Räumt die Bühne — beim Ende der Diashow. Der Fernseher wird dann
    /// schwarz und zeigt wieder den Hinweis, statt das letzte Bild
    /// einzufrieren.
    ///
    /// **Bewusst nur das Bild.** Der Player hat einen Eigentümer, der ihn
    /// selbst zurücknimmt (``nimmSpielerZurueck(_:)``). Ihn hier mit
    /// wegzuräumen hieße, dass die Diashow beim Beenden einem laufenden Video
    /// den Bildschirm entzöge, ohne dass dessen Eigentümer davon erführe — er
    /// hielte sich weiter für den, der die Bühne speist.
    func raeumen() {
        bild = nil
    }
}
