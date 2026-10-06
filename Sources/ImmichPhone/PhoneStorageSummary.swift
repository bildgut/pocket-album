import Foundation

/// Was die Offline-Alben auf dem Telefon belegen — als reiner Wertetyp, damit die
/// Einstellungen ihn nur noch anzeigen müssen.
///
/// **Woher die Zahlen kommen.** Je Vermerk liefert
/// `LocalFileCacheManager.status(forAssetIds:container:)` das Tripel
/// `(present, expected, bytes)`, `OfflinePin` den Namen und `lastError`. Dieser Typ
/// kennt weder SwiftData noch Netz noch Oberfläche: Die Vierergruppen kommen fertig
/// herein. Genau deshalb ist er prüfbar, während dieselbe Rechnung auf dem Mac in
/// `OfflineAlbumsSettingsSection` (`PinStats`, `statusText`, `formatBytes`) im
/// View-Body sitzt und dort nicht geprüft werden kann. Die Mac-Datei bleibt
/// unverändert; übernommen sind ihre Regeln, nicht ihr Code.
///
/// **Warum kein `ByteCountFormatter`.** Der Mac benutzt ihn — hier bewusst nicht:
///
/// 1. Er ist locale- **und** OS-abhängig. Ein Test auf die entstehende Zeichenfolge
///    wäre spröde (das Dezimalzeichen, die Einheitennamen und der Sonderfall
///    „Zero KB" haben sich über OS-Versionen schon geändert). Prüfte man statt
///    dessen nur auf Bestandteile („enthält GB"), bliebe die Zahl selbst ungeprüft —
///    und die ist hier der ganze Punkt.
/// 2. Mit den Einheiten des Mac (`[.useMB, .useGB]`) steht bei einem frisch
///    gepinnten Album „0 MB", bei null Bytes „Zero KB". Auf dem Telefon soll dort
///    „0 B" bzw. „512 B" stehen.
///
/// Die **Stufung** folgt dennoch dem Mac: 1000er-Schritte wie `countStyle = .file`.
/// Nicht aber die Zahl — der Mac beschränkt sich auf `[.useMB, .useGB]` und zeigt
/// deshalb für dasselbe Album mitunter etwas anderes (`999 KB` hier gegen `1 MB`
/// dort, `1,0 TB` hier gegen `1.000 GB` dort). Das ist gewollt: Auf dem Telefon
/// soll auch ein kleines Album eine sinnvolle Zahl haben, statt „0 MB".
///
/// Das Dezimalzeichen kommt aus einer **fest gewählten deutschen Locale**, nicht
/// aus der des Geräts. Damit steht „1,5 GB" statt „1.5 GB" — und die Ausgabe
/// bleibt trotzdem Zeichen für Zeichen prüfbar, weil sie von keiner
/// Geräteeinstellung abhängt. Beides gleichzeitig zu haben ist der Grund, die
/// Locale ausdrücklich zu übergeben, statt sie wegzulassen. Fest deutsch ist im
/// Haus die Regel, nicht die Ausnahme: `PhotoFeedGrouping` schreibt seine
/// Wochentage aus, `TimelineGrouping` am Mac seine Monatsnamen.
struct PhoneStorageSummary: Equatable, Sendable {

    /// Fest, nicht `Locale.current`: Die Anzeige soll auf jedem Gerät gleich
    /// aussehen und in den Tests Zeichen für Zeichen festnagelbar sein.
    private static let anzeigeLocale = Locale(identifier: "de_DE")

    // MARK: - Zustand eines Vermerks

    /// Wie es um ein einzelnes offline vorgehaltenes Album steht.
    ///
    /// `fehlerhaft` steht bewusst **vor** allem anderen: `OfflineBadge.from(pin:)`
    /// (`Sources/Shared/Models/OfflineBadge.swift`) prüft `lastError` vor
    /// `lastCompletedAt` und macht aus einem vollständigen Lauf mit gesetztem Fehler
    /// `.failed`. Kehrte man die Reihenfolge hier um, zeigten Kachel und
    /// Einstellungen für denselben Vermerk Verschiedenes an.
    ///
    /// In **einem** Punkt weicht dieser Typ bewusst ab: `OfflineBadge` prüft nur
    /// `lastError != nil`, hier gewinnt ein leerer oder nur aus Leerraum
    /// bestehender Text nicht — er ergäbe eine Zeile, die einen Fehler behauptet
    /// und keinen nennt. Ein Vermerk mit `lastError == ""` wäre auf der Kachel
    /// also `.failed`, hier „vollständig". Erreichbar ist das nicht:
    /// `OfflineDownloadManager` (`:280`, `:324`) setzt nur nichtleere Texte oder
    /// `nil`.
    enum Zustand: Equatable, Hashable, Sendable {
        /// Letzter Lauf mit Fehler — schlägt jeden anderen Zustand.
        case fehlerhaft(String)
        /// Keine erwarteten Dateien: die Mitgliedschaft ist noch nicht aufgelöst
        /// oder das Album ist leer. Ausdrücklich **nicht** „vollständig": Ohne
        /// Erwartung gibt es nichts, was vollständig sein könnte.
        case ohneFotos
        /// Alle erwarteten Dateien liegen auf dem Gerät.
        case vollstaendig(anzahl: Int)
        /// Es fehlt noch etwas.
        case teilweise(vorhanden: Int, erwartet: Int)

        var beschreibung: String {
            switch self {
            case .fehlerhaft(let meldung):
                return meldung
            case .ohneFotos:
                // Neutral formuliert: Ob die Mitgliedschaft noch nicht aufgelöst ist
                // oder das Album wirklich leer, unterscheidet erst `lastResolvedAt` —
                // das gehört zum Vermerk, nicht zu diesen Zahlen. Der Mac kann es
                // trennen, weil er den `OfflinePin` selbst in der Hand hat.
                return String(localized: "no photos yet")
            case .vollstaendig(let anzahl):
                return String(localized: "complete · \(anzahl) photos")
            case .teilweise(let vorhanden, let erwartet):
                return String(localized: "\(vorhanden) of \(erwartet) photos")
            }
        }

        var istFehler: Bool {
            if case .fehlerhaft = self { return true }
            return false
        }
    }

    // MARK: - Eine Zeile

    /// Die Kennzahlen eines Vermerks, so wie sie hereinkommen — der Zustand wird
    /// daraus abgeleitet, nicht mitgeliefert.
    struct Eintrag: Equatable, Hashable, Sendable {
        let name: String
        /// Wie viele der erwarteten Dateien tatsächlich auf dem Gerät liegen.
        let vorhanden: Int
        /// Wie viele Dateien der Vermerk erwartet (`assetIds.count`).
        let erwartet: Int
        let bytes: Int64
        /// `OfflinePin.lastError`; `nil` = alles gut.
        let fehler: String?

        init(name: String, vorhanden: Int, erwartet: Int, bytes: Int64, fehler: String? = nil) {
            self.name = name
            self.vorhanden = vorhanden
            self.erwartet = erwartet
            self.bytes = bytes
            self.fehler = fehler
        }

        var zustand: Zustand {
            // Leerraum zählt nicht als Fehler: Eine leere Meldung ergäbe eine leere
            // Zeile — schlechter als die Zahl, die ohne sie dort stünde.
            if let fehler, !fehler.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .fehlerhaft(fehler)
            }
            guard erwartet > 0 else { return .ohneFotos }
            if vorhanden >= erwartet { return .vollstaendig(anzahl: erwartet) }
            return .teilweise(vorhanden: vorhanden, erwartet: erwartet)
        }

        /// Ladefortschritt zwischen 0 und 1 — `nil`, wenn nichts erwartet wird.
        ///
        /// Der `nil`-Fall ist der Grund, warum das hier kein `Double` ist: Bei
        /// `erwartet == 0` gäbe eine Division eine Ausnahme, und jeder Ersatzwert
        /// wäre gelogen (0 behauptet „nichts geladen", 1 behauptet „100 %"). Ein
        /// Fehler nimmt den Fortschritt dagegen nicht weg — er steht daneben.
        var anteil: Double? {
            guard erwartet > 0 else { return nil }
            return min(1.0, Double(vorhanden) / Double(erwartet))
        }

        var groesse: String { PhoneStorageSummary.groesse(bytes) }
    }

    // MARK: - Die Zusammenfassung

    let eintraege: [Eintrag]
    let gesamtBytes: Int64
    /// Summe der tatsächlich vorliegenden Dateien über alle Vermerke.
    let vorhandeneFotos: Int
    /// Summe der erwarteten Dateien über alle Vermerke.
    let erwarteteFotos: Int

    var anzahlAlben: Int { eintraege.count }
    /// Kein Vermerk vorhanden. Die Ansicht macht daraus ihren Leerzustand — eine
    /// leere Zusammenfassung ist nie `nil`.
    var istLeer: Bool { eintraege.isEmpty }
    var gesamtGroesse: String { Self.groesse(gesamtBytes) }
    var hatFehler: Bool { eintraege.contains { $0.zustand.istFehler } }

    init(eintraege: [Eintrag]) {
        self.eintraege = eintraege
        self.gesamtBytes = eintraege.reduce(Int64(0)) { $0 + $1.bytes }
        self.vorhandeneFotos = eintraege.reduce(0) { $0 + $1.vorhanden }
        self.erwarteteFotos = eintraege.reduce(0) { $0 + $1.erwartet }
    }

    // MARK: - Byte-Formatierung

    private static let einheiten = ["B", "KB", "MB", "GB", "TB", "PB"]

    /// `0 → "0 B"`, `1_500 → "1,5 KB"`, `523_000_000 → "523 MB"`.
    ///
    /// Eine Nachkommastelle unter 10, darüber keine — „2,5 GB" ist genauer als
    /// „2 GB", „523,0 MB" nur länger als „523 MB".
    static func groesse(_ bytes: Int64) -> String {
        // Eine Dateigröße kann nicht negativ sein; rutscht doch eine durch, ist
        // "0 B" die harmlose Anzeige.
        guard bytes > 0 else { return "0 B" }

        var wert = Double(bytes)
        var index = 0
        // Die Schleife prüft den **gerundeten** Wert: 999_999 Bytes wären sonst
        // "1000 KB" statt "1.0 MB".
        while index < einheiten.count - 1, angezeigterWert(wert, alsBytes: index == 0) >= 1000 {
            wert /= 1000
            index += 1
        }

        if index == 0 { return "\(bytes) B" }
        // Die Nachkommastelle entscheidet sich an dem Wert, der gleich **gedruckt**
        // wird — also auf eine Nachkommastelle gerundet, nicht am rohen und nicht
        // auf ganze Einheiten gerundet. Beide Nachbarlösungen sind falsch, jede auf
        // ihre Art: Am rohen Wert ergäben 9_950 Bytes „10,0 KB", 10_000 aber
        // „10 KB" — eine Nachkommastelle bei genau 10, entgegen der Regel oben. Auf
        // ganze Einheiten gerundet verlöre 9_949 seine Stelle und stünde als
        // „10 KB" da, obwohl „9,9 KB" genauer und richtig ist.
        return (wert * 10).rounded() / 10 < 10
            ? String(format: "%.1f %@", locale: Self.anzeigeLocale, wert, einheiten[index])
            : String(format: "%.0f %@", locale: Self.anzeigeLocale, wert, einheiten[index])
    }

    /// Der Wert so, wie er nach dem Runden auf dem Schirm stünde. Bytes werden nie
    /// gerundet, alles andere auf ganze Einheiten.
    ///
    /// Bewusst **ohne** eigenen Zweig für Werte unter 10: Diese Funktion beantwortet
    /// nur noch die Frage nach der nächsten Einheit (`>= 1000`), und dafür ist die
    /// Rundung auf ganze Einheiten die richtige. Die Frage nach der Nachkommastelle
    /// beantwortet ``groesse(_:)`` selbst — mit einer Rundung auf eine
    /// Nachkommastelle, weil dort genau das gedruckt wird.
    private static func angezeigterWert(_ wert: Double, alsBytes: Bool) -> Double {
        alsBytes ? wert : wert.rounded()
    }
}
