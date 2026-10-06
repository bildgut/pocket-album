import Foundation

/// Formatiert die Laufzeit eines Videos für die Anzeige. Reiner Wertetyp,
/// kein SwiftUI — deshalb prüfbar, siehe `Tests/ImmichPhoneTests/VideoDurationTests.swift`.
///
/// **Eingabe:** `Asset.duration`. Der Decoder in
/// `Sources/Shared/Models/Asset.swift:119-130` nimmt drei Serverformen an
/// (Zeichenfolge, Millisekunden als `Double`, Millisekunden als `Int`) und
/// normalisiert alle auf `"HH:MM:SS.mmm"` — die Zeichenfolge wird unverändert
/// durchgereicht, die beiden Zahlenformen über
/// `String(format: "%02d:%02d:%06.3f", …)` in dieselbe Form gebracht. Der
/// Bestand deckt sich damit: In `grid_index.sqlite` sind alle gesetzten
/// Laufzeiten genau 12 Zeichen lang.
///
/// **Warum ein eigener Formatierer und nicht `DateComponentsFormatter`?**
/// Dessen `.positional`-Stil liefert je nach Locale und `zeroFormattingBehavior`
/// mal `"1:23"`, mal `"01:23"`, mal `"0:01:23"`; die Anzeige auf einer Kachel
/// soll aber überall gleich aussehen und nie länger werden als nötig.
enum VideoDuration {

    /// `"00:01:23.456"` → `"1:23"`, `"01:02:03.000"` → `"1:02:03"`.
    ///
    /// Gibt `nil` zurück, wenn nichts vorliegt oder die Zeichenfolge nicht der
    /// erwarteten Form entspricht — der Aufrufer lässt die Dauer dann weg. Eine
    /// halb geratene Zahl wäre schlechter als keine.
    ///
    /// **Abgeschnitten, nicht gerundet:** `"00:01:23.456"` ergibt `"1:23"`.
    /// Angezeigt wird damit die Zahl vollständig verstrichener Sekunden, wie
    /// bei jeder Wiedergabeanzeige — und wie schon auf dem Mac
    /// (`AssetInfoFormat.duration`). Gerundet stünde auf der Kachel eine
    /// Sekunde, die das Video nicht hat.
    static func kurzform(_ dauer: String?) -> String? {
        guard let f = felder(dauer) else { return nil }
        let sekunden = Int(f.sekunden)

        if f.stunden > 0 {
            return String(format: "%d:%02d:%02d", f.stunden, f.minuten, sekunden)
        }
        return String(format: "%d:%02d", f.minuten, sekunden)
    }

    /// `"00:01:23.500"` → `83.5` — für die Größenschätzung beim Offline-Speichern.
    /// Dieselbe Formprüfung wie ``kurzform(_:)``.
    static func sekunden(_ dauer: String?) -> Double? {
        guard let f = felder(dauer) else { return nil }
        return Double(f.stunden * 3_600 + f.minuten * 60) + f.sekunden
    }

    /// Die drei Felder von `"HH:MM:SS.mmm"`, geprüft.
    private static func felder(_ dauer: String?) -> (stunden: Int, minuten: Int, sekunden: Double)? {
        guard let dauer else { return nil }

        let teile = dauer.split(separator: ":", omittingEmptySubsequences: false)
        // Genau drei Felder: "HH:MM:SS.mmm". Alles andere ("12", "00:12",
        // "abc", "") ist nicht die Form, die der Decoder erzeugt — und damit
        // etwas, über das dieser Typ nichts weiß.
        guard teile.count == 3,
              let stunden = Int(teile[0]),
              let minuten = Int(teile[1]),
              let sekundenGenau = Double(teile[2]),
              // `Double("nan")`, `Double("inf")` und `Double("1e30")` parsen
              // alle erfolgreich — `Int(sekundenGenau)` stürzt bei ihnen ab.
              // Die Sekundenstelle eines `"HH:MM:SS.mmm"` bleibt unter einem
              // Tag; alles darüber ist ohnehin keine Sekundenangabe mehr.
              sekundenGenau.isFinite, sekundenGenau < 86_400,
              stunden >= 0, minuten >= 0, sekundenGenau >= 0
        else { return nil }
        return (stunden, minuten, sekundenGenau)
    }
}
