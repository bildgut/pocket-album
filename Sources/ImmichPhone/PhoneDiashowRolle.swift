import Foundation

/// In welcher Rolle die Diashow gerade läuft — auf dem Telefon selbst, oder
/// als Fernbedienung für einen angeschlossenen Zweitbildschirm.
///
/// **Warum ein eigener Wertetyp.** Genau derselbe Schnitt wie bei
/// ``PhoneDiashowFolge`` und ``PhoneMediaSource``: `PhoneDiashowView` ist eine
/// Vollbildansicht, und die Zweitbildschirm-Szene ist eine `UIScene` — an
/// beidem lässt sich in einem Testlauf nichts prüfen. Prüfbar ist genau die
/// eine Frage, die dazwischen steht: *Was folgt daraus, dass ein
/// Zweitbildschirm hängt?* Diese Frage beantwortet dieser Typ, und die Antwort
/// steht damit an einer Stelle statt verteilt über vier `if`-Abfragen im Body.
///
/// **Warum ein `Bool` als Eingang genügt.** Ob ein Zweitbildschirm hängt, weiß
/// nur UIKit (die Szene wird verbunden oder nicht, siehe
/// ``PhoneZweitbildschirmSzenenDelegat``). Dieser Typ entscheidet nicht, *ob*
/// einer hängt — er zieht nur die Folgerungen. Deshalb ist der Eingang bewusst
/// so schmal wie möglich.
enum PhoneDiashowRolle: Equatable, Sendable {

    /// Kein Zweitbildschirm: Das Telefon zeigt das Foto selbst, formatfüllend.
    /// Das ist der Zustand, in dem die Diashow bis hierher immer lief.
    case vollbild

    /// Ein Zweitbildschirm hängt: Das Foto steht dort, das Telefon wird zur
    /// Fernbedienung.
    case fernbedienung

    static func fuer(zweitbildschirmAngeschlossen: Bool) -> PhoneDiashowRolle {
        zweitbildschirmAngeschlossen ? .fernbedienung : .vollbild
    }

    /// Zeigt das Telefon das Foto groß? Nur ohne Zweitbildschirm — sonst
    /// stünde dasselbe Bild zweimal, und die Bedienung hätte keinen Platz.
    var zeigtBildGross: Bool { self == .vollbild }

    /// Speist die Diashow den Zweitbildschirm? Das Vorbereiten eines fertigen
    /// `UIImage` je Bild (auch für Serverbilder, die sonst `LazyImage`
    /// nachlädt) kostet etwas — es passiert deshalb nur, wenn es jemand sieht.
    var versorgtZweitbildschirm: Bool { self == .fernbedienung }

    /// Verschwindet die Bedienung nach ein paar Sekunden von selbst?
    ///
    /// Im Vollbild ja: Auf dem Fernseher soll nichts stehen als das Bild. Als
    /// Fernbedienung nein — eine Fernbedienung, deren Knöpfe nach drei
    /// Sekunden verschwinden, ist keine.
    var bedienungBlendetAus: Bool { self == .vollbild }

    /// Statusleiste und Home-Indikator ausblenden? Im Vollbild ja, aus
    /// demselben Grund. Auf der Fernbedienung sind sie normal — dort ist das
    /// Telefon ein gewöhnlicher Bildschirm, und die Uhrzeit zu sehen ist
    /// mitten in einer Vorführung eher nützlich.
    var verstecktSystemleisten: Bool { self == .vollbild }

    /// Der Ruhemodus bleibt in **beiden** Rollen ausgesetzt: Sperrt sich das
    /// Telefon, endet auch die Vorführung auf dem Fernseher.
    var haeltBildschirmWach: Bool { true }
}
