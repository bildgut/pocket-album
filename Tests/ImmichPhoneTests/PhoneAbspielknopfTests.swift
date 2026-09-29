import AVFoundation
import Testing
@testable import ImmichPhone

// Prüft den Abspielknopf der Zweitbildschirm-Bedienung — Symbol, Beschriftung,
// Wirkung und der Zustand nach dem Tipp.
//
// **Warum es diese Tests gibt.** Der Nutzer hat am Apple TV gemeldet: Pause
// wirkt, aber danach lässt sich nicht wieder auf Play drücken. Die Ursache lag
// zur Hälfte im Beobachter (siehe `PhoneKVOStromTests`) und zur Hälfte darin,
// dass die Entscheidung „welches Symbol, welche Wirkung" als drei Ternäre im
// Rumpf einer SwiftUI-Ansicht stand — an einer Stelle also, an der kein Test
// hinkommt.
@Suite("PhoneAbspielknopf")
struct PhoneAbspielknopfTests {

    @Test("Läuft es, bietet der Knopf Pause an")
    func laufendZeigtPause() {
        #expect(PhoneAbspielknopf.pausieren.symbol == "pause.fill")
        #expect(PhoneAbspielknopf.pausieren.beschriftung == "Pause")
        #expect(PhoneAbspielknopf.pausieren.getippt().wirkung == .anhalten)
    }

    @Test("Steht es, bietet der Knopf Weiter an")
    func gestopptZeigtWeiter() {
        #expect(PhoneAbspielknopf.fortsetzen.symbol == "play.fill")
        #expect(PhoneAbspielknopf.fortsetzen.beschriftung == "Play")
        #expect(PhoneAbspielknopf.fortsetzen.getippt().wirkung == .abspielen)
    }

    // Das ist der gemeldete Fehler, als Test: Nach einem Tipp auf Pause muss
    // der Knopf „Weiter" anbieten. Vorher hing er auf „Pause" fest, und der
    // zweite Tipp rief noch einmal `pause()`.
    @Test("Ein Tipp auf Pause macht aus dem Knopf sofort Weiter")
    func tippAufPauseKehrtUm() {
        let (wirkung, danach) = PhoneAbspielknopf.pausieren.getippt()
        #expect(wirkung == .anhalten)
        #expect(danach == .fortsetzen)
    }

    @Test("Ein Tipp auf Weiter macht aus dem Knopf sofort Pause")
    func tippAufWeiterKehrtUm() {
        let (wirkung, danach) = PhoneAbspielknopf.fortsetzen.getippt()
        #expect(wirkung == .abspielen)
        #expect(danach == .pausieren)
    }

    @Test("Zwei Tipps führen zurück zum Ausgangszustand")
    func zweiTippsSindEineRunde() {
        // Genau das ging nicht: pausieren, dann wieder starten.
        let nachPause = PhoneAbspielknopf.pausieren.getippt().danach
        let nachWeiter = nachPause.getippt()
        #expect(nachWeiter.wirkung == .abspielen)
        #expect(nachWeiter.danach == .pausieren)
    }

    @Test("Ein pausierter Player ergibt Weiter")
    func spielstandPausiert() {
        #expect(PhoneAbspielknopf.fuer(spielstand: .paused) == .fortsetzen)
    }

    @Test("Ein laufender Player ergibt Pause")
    func spielstandLaeuft() {
        #expect(PhoneAbspielknopf.fuer(spielstand: .playing) == .pausieren)
    }

    // Der Fall, der die Anzeige sonst flackern ließe: Beim Puffern will der
    // Player spielen und wartet nur auf Daten. Als „steht" gewertet, böte der
    // Knopf bei jedem Aussetzer kurz „Weiter" an.
    @Test("Ein wartender Player zählt als laufend")
    func spielstandWartet() {
        #expect(PhoneAbspielknopf.fuer(spielstand: .waitingToPlayAtSpecifiedRate) == .pausieren)
    }

    // Die Begründung, warum das Nachführen aus dem Player nicht durch das
    // Mitschreiben beim Tippen ersetzt wurde: Am Ende des Videos steht der
    // Player auf `.paused`, ohne dass jemand getippt hätte.
    @Test("Am Ende des Videos korrigiert der Spielstand einen Knopf, der auf Pause steht")
    func endeKorrigiertDenKnopf() {
        var knopf = PhoneAbspielknopf.pausieren
        knopf = .fuer(spielstand: .paused)
        #expect(knopf == .fortsetzen)
    }
}
