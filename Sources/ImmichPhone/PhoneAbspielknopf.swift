import AVFoundation

/// Was der Abspielknopf der Zweitbildschirm-Bedienung gerade anbietet —
/// welches Symbol er trägt, wie er heißt, und was ein Tipp bewirkt.
///
/// **Warum ein eigener Wertetyp.** Derselbe Schnitt wie bei
/// ``PhoneVideoRolle``: An einer SwiftUI-Ansicht mit einem `AVPlayer` darin
/// lässt sich im Testlauf nichts prüfen, an der Frage „welches Symbol, welche
/// Wirkung, welcher Zustand danach" sehr wohl. Und genau dort saß der Fehler,
/// den der Nutzer am Apple TV gefunden hat: Ein Knopf, der sich für „läuft"
/// hielt, obwohl längst pausiert war, rief beim zweiten Tipp wieder `pause()`.
/// Als drei verstreute Ternäre im Ansichtsrumpf (`laeuft ? … : …` für Symbol,
/// Beschriftung und Wirkung) war das unprüfbar.
///
/// **Warum der Knopf nach dem Tipp sofort umspringt.** Bis hierher wurde der
/// Zustand ausschließlich aus dem Player nachgeführt, mit einem guten Grund:
/// Läuft ein Video zu Ende oder bleibt es beim Puffern stehen, böte ein beim
/// Tippen mitgeschriebener Zustand weiter „Pause" an, obwohl nichts läuft.
/// Das Argument gilt weiterhin — deshalb bleibt das Nachführen (``fuer(spielstand:)``)
/// bestehen. Es genügt nur eben nicht: Klemmt der Beobachter, hängt die Anzeige
/// **dauerhaft** fest, und der Knopf tut das Gegenteil dessen, was er zeigt.
/// Beides zusammen ist robust: ``getippt()`` setzt sofort, was gleich gilt, und
/// der Player korrigiert es, sobald er es besser weiß.
enum PhoneAbspielknopf: Equatable, Sendable {

    /// Es läuft etwas; der Tipp hält an.
    case pausieren

    /// Es steht; der Tipp lässt weiterlaufen.
    case fortsetzen

    /// Was ein Tipp mit dem `AVPlayer` machen soll.
    enum Wirkung: Equatable, Sendable {
        case anhalten
        case abspielen
    }

    var symbol: String {
        switch self {
        case .pausieren: "pause.fill"
        case .fortsetzen: "play.fill"
        }
    }

    /// Die VoiceOver-Beschriftung. Immer über diese Konstanten, nie als
    /// `Text`-Literal im Rumpf: SwiftUI parst solche Literale als Markdown
    /// (siehe `PhoneAlbumTile`).
    var beschriftung: String {
        switch self {
        case .pausieren: String(localized: "Pause")
        case .fortsetzen: String(localized: "Play")
        }
    }

    /// Der Tipp: was er am Player auslöst und wie der Knopf danach aussieht.
    ///
    /// Beides in einem Zug, damit an der Aufrufstelle nicht erst die Wirkung
    /// gelesen und dann der Zustand überschrieben werden muss — in dieser
    /// Reihenfolge liegt genau der Fehler, den man einmal falsch herum
    /// schreibt.
    func getippt() -> (wirkung: Wirkung, danach: PhoneAbspielknopf) {
        switch self {
        case .pausieren: (.anhalten, .fortsetzen)
        case .fortsetzen: (.abspielen, .pausieren)
        }
    }

    /// Der Knopf zu einem Spielstand des Players.
    ///
    /// `.waitingToPlayAtSpecifiedRate` zählt als „läuft": Der Player *will*
    /// spielen und wartet nur auf Daten. Böte der Knopf in diesem Moment
    /// „Weiter" an, führte ein Tipp beim Puffern zu einem `play()` auf einem
    /// Player, der ohnehin schon spielen will — und das Symbol flackerte bei
    /// jedem Pufferstillstand.
    static func fuer(spielstand: AVPlayer.TimeControlStatus) -> PhoneAbspielknopf {
        spielstand == .paused ? .fortsetzen : .pausieren
    }
}
