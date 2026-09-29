import Foundation
import Testing
@testable import ImmichPhone

// Prüft `VideoDuration.kurzform` — den Formatierer für die Laufzeit, die im
// Albumraster auf der Videokachel steht.
//
// **Welche Eingabe hier wirklich ankommt** (vor dem Schreiben nachgesehen,
// nicht geraten): `Asset.duration` ist ein `String?`, den der Decoder in
// `Sources/Shared/Models/Asset.swift:119-130` aus drei Serverformen auf eine
// einzige normalisiert — eine bereits gelieferte Zeichenfolge bleibt, wie sie
// ist, Millisekunden als `Double`/`Int` werden zu
// `String(format: "%02d:%02d:%06.3f", …)`. Beides ergibt `"HH:MM:SS.mmm"`.
// Der Bestand bestätigt das: In `grid_index.sqlite` dieser Mediathek sind alle
// gesetzten Werte exakt 12 Zeichen lang und passen auf `HH:MM:SS.mmm`
// (längster Wert `"00:37:36.325"`, kürzester `"00:00:00.040"`), ohne einen
// einzigen Abweichler. Eine Dauer zu haben heißt aber **nicht**, ein Video zu
// sein: Rund 200 Fotos tragen ebenfalls eine (Live Photos, etwa
// `"00:00:01.250"`). Das Abzeichen hängt deshalb an `isVideo`, nicht daran, ob
// eine Dauer vorliegt. Umgekehrt haben einzelne Videos `NULL` — die bekommen
// das Symbol ohne Zeitangabe.
//
// **Abschneiden statt Runden:** `"00:01:23.456"` wird `"1:23"`, nicht `"1:24"`.
// So hält es auch der Mac (`AssetInfoFormat.duration`, `Int(sDouble)`), und so
// hält es jeder Player, dessen Restzeitanzeige bei 0 ankommt statt bei 1 — eine
// aufgerundete Anzeige behauptete eine Sekunde, die das Video nicht hat.
@Suite("VideoDuration")
struct VideoDurationTests {

    @Test("Sekunden unter einer Minute: einstellige Minute, zweistellige Sekunde")
    func sekunden() {
        #expect(VideoDuration.kurzform("00:00:07.000") == "0:07")
    }

    @Test("Millisekunden werden abgeschnitten, nicht gerundet")
    func abschneiden() {
        #expect(VideoDuration.kurzform("00:01:23.456") == "1:23")
        #expect(VideoDuration.kurzform("00:00:01.999") == "0:01")
    }

    @Test("Stunden erscheinen nur, wenn es welche gibt")
    func stunden() {
        #expect(VideoDuration.kurzform("01:02:03.000") == "1:02:03")
        #expect(VideoDuration.kurzform("00:10:00.000") == "10:00")
    }

    @Test("Null Sekunden ergeben eine Anzeige, keinen Leerwert")
    func null() {
        #expect(VideoDuration.kurzform("00:00:00.000") == "0:00")
    }

    // Die Stundenstelle des Formats zählt Stunden, sie zeigt keine Uhrzeit:
    // Der Decoder rechnet `Int(totalSeconds) / 3600` ohne obere Grenze und
    // formatiert mit `%02d`, das bei dreistelligen Werten schlicht breiter
    // wird. Über 24 h ist also darstellbar — in dieser Mediathek kommt es
    // nicht vor (längstes Video 37 Minuten), deshalb steht hier nur der
    // Formatierer auf dem Prüfstand, keine Behauptung über den Bestand.
    @Test("Mehr als 24 Stunden bleiben lesbar, weil das Format sie zulässt")
    func ueber24Stunden() {
        #expect(VideoDuration.kurzform("25:00:00.000") == "25:00:00")
        #expect(VideoDuration.kurzform("100:30:00.000") == "100:30:00")
    }

    @Test("Ohne Wert bleibt es ohne Wert")
    func fehlend() {
        #expect(VideoDuration.kurzform(nil) == nil)
    }

    @Test("Unsinn ergibt nil statt eines Absturzes oder einer erfundenen Zahl")
    func unsinn() {
        #expect(VideoDuration.kurzform("") == nil)
        #expect(VideoDuration.kurzform("abc") == nil)
        #expect(VideoDuration.kurzform("12") == nil)
        #expect(VideoDuration.kurzform("00:12") == nil)
        #expect(VideoDuration.kurzform("00:00:07.000:99") == nil)
        #expect(VideoDuration.kurzform("aa:bb:cc.ddd") == nil)
        #expect(VideoDuration.kurzform("   ") == nil)
    }

    /// Der einzige Fall, in dem `kurzform` wirklich abstürzen könnte statt nur
    /// Unsinn zu liefern — und deshalb der wichtigste Test der Datei.
    /// `Double("nan")`, `Double("inf")` und `Double("1e30")` parsen alle
    /// erfolgreich, `Int(...)` bricht auf allen dreien mit SIGTRAP ab. Der
    /// Unsinns-Test oben erreicht diese Stelle **nicht**: `"aa:bb:cc.ddd"`
    /// stirbt schon an `Int("aa")`, bevor die Sekundenstelle geprüft wird.
    /// Ohne diesen Test bliebe das Streichen von `isFinite`/`< 86_400` in
    /// `VideoDuration.swift` unbemerkt — alle anderen Tests blieben grün.
    @Test("Nicht-endliche Sekunden stürzen nicht ab")
    func nichtEndlicheSekunden() {
        #expect(VideoDuration.kurzform("00:00:nan") == nil)
        #expect(VideoDuration.kurzform("00:00:inf") == nil)
        #expect(VideoDuration.kurzform("00:00:1e30") == nil)
    }

    @Test("Negative Angaben sind keine Laufzeit")
    func negativ() {
        #expect(VideoDuration.kurzform("-01:00:00.000") == nil)
        #expect(VideoDuration.kurzform("00:-1:00.000") == nil)
        #expect(VideoDuration.kurzform("00:00:-7.000") == nil)
    }

    @Test("Sekunden ohne Nachkommastellen gehen auch")
    func ohneMillisekunden() {
        #expect(VideoDuration.kurzform("00:02:05") == "2:05")
    }

    @Test("Sekunden als Zahl für die Größenschätzung")
    func sekundenAusDauer() {
        #expect(VideoDuration.sekunden("00:01:23.500") == 83.5)
        #expect(VideoDuration.sekunden("01:00:00.000") == 3_600)
        #expect(VideoDuration.sekunden(nil) == nil)
        #expect(VideoDuration.sekunden("12") == nil)
        #expect(VideoDuration.sekunden("00:00:nan") == nil)
    }
}
