import Foundation
import Testing
@testable import ImmichPhone

// Prüft die Aufbereitung der Offline-Kennzahlen. `PhoneStorageSummary` ist ein
// reiner Wertetyp ohne SwiftData, ohne Netz und ohne Oberfläche — die Zahlen
// kommen als fertige Vierergruppen herein, genau wie sie auf dem Mac aus
// `LocalFileCacheManager.status(forAssetIds:container:)` und `OfflinePin.lastError`
// fallen. Deshalb braucht dieser Test keinen `ModelContainer`.
//
// Die Byte-Formatierung wird hier auf **exakte** Zeichenfolgen geprüft. Das ist
// nur zulässig, weil `PhoneStorageSummary.groesse(_:)` bewusst keinen
// `ByteCountFormatter` benutzt (Begründung im Kopf der Quelldatei) und damit
// weder von der Locale noch von der OS-Version abhängt. Käme dort je ein
// `ByteCountFormatter` hinein, müssten diese Erwartungen auf Bestandteile
// ausweichen — dann wäre aber auch die Zahl selbst nicht mehr geprüft.

@Suite("PhoneStorageSummary")
struct PhoneStorageSummaryTests {

    private func eintrag(
        _ name: String = "Urlaub",
        vorhanden: Int = 0,
        erwartet: Int = 0,
        bytes: Int64 = 0,
        fehler: String? = nil
    ) -> PhoneStorageSummary.Eintrag {
        PhoneStorageSummary.Eintrag(
            name: name, vorhanden: vorhanden, erwartet: erwartet, bytes: bytes, fehler: fehler
        )
    }

    // MARK: - Summen

    @Test("Ohne Vermerke entsteht eine leere Zusammenfassung, kein nil und kein Absturz")
    func leereEingabe() {
        let summe = PhoneStorageSummary(eintraege: [])

        #expect(summe.istLeer)
        #expect(summe.eintraege.isEmpty)
        #expect(summe.anzahlAlben == 0)
        #expect(summe.gesamtBytes == 0)
        #expect(summe.vorhandeneFotos == 0)
        #expect(summe.erwarteteFotos == 0)
        #expect(summe.gesamtGroesse == "0 B")
        #expect(!summe.hatFehler)
    }

    @Test("Die Summe über mehrere Alben stimmt in Bytes und Fotozahlen")
    func summeUeberMehrereAlben() {
        let summe = PhoneStorageSummary(eintraege: [
            eintrag("Urlaub", vorhanden: 10, erwartet: 10, bytes: 1_000_000),
            eintrag("Familie", vorhanden: 3, erwartet: 12, bytes: 2_500_000),
            eintrag("Berge", vorhanden: 7, erwartet: 7, bytes: 500_000)
        ])

        #expect(!summe.istLeer)
        #expect(summe.anzahlAlben == 3)
        #expect(summe.gesamtBytes == 4_000_000)
        #expect(summe.vorhandeneFotos == 20)
        #expect(summe.erwarteteFotos == 29)
        #expect(summe.gesamtGroesse == "4,0 MB")
    }

    @Test("Die Gesamtgröße ist die Summe der Einzelgrößen, nicht die Summe der Texte")
    func gesamtgroesseEntsprichtEinzelsumme() {
        let eintraege = [
            eintrag("A", bytes: 1_500_000),
            eintrag("B", bytes: 2_500_000)
        ]
        let summe = PhoneStorageSummary(eintraege: eintraege)

        #expect(eintraege[0].groesse == "1,5 MB")
        #expect(eintraege[1].groesse == "2,5 MB")
        // Bewusst die ausgerechnete Zahl statt `reduce` über dieselbe Liste —
        // das baute nur die Implementierung nach und bewiese nichts.
        #expect(summe.gesamtBytes == 4_000_000)
        #expect(summe.gesamtGroesse == "4,0 MB")
    }

    // MARK: - Zustände

    @Test("Vollständig, teilweise und fehlerhaft sind unterscheidbare Zustände")
    func dreiZustaendeSindUnterscheidbar() {
        let voll = eintrag(vorhanden: 10, erwartet: 10)
        let teil = eintrag(vorhanden: 3, erwartet: 10)
        let kaputt = eintrag(vorhanden: 3, erwartet: 10, fehler: "Netz weg")

        #expect(voll.zustand == .vollstaendig(anzahl: 10))
        #expect(teil.zustand == .teilweise(vorhanden: 3, erwartet: 10))
        #expect(kaputt.zustand == .fehlerhaft("Netz weg"))

        #expect(voll.zustand != teil.zustand)
        #expect(teil.zustand != kaputt.zustand)
        #expect(voll.zustand != kaputt.zustand)

        #expect(!voll.zustand.istFehler)
        #expect(!teil.zustand.istFehler)
        #expect(kaputt.zustand.istFehler)
    }

    @Test("Jeder Zustand hat einen eigenen, nichtleeren Beschreibungstext")
    func beschreibungenSindEigenstaendig() {
        let voll = eintrag(vorhanden: 10, erwartet: 10).zustand.beschreibung
        let teil = eintrag(vorhanden: 3, erwartet: 10).zustand.beschreibung
        let kaputt = eintrag(vorhanden: 3, erwartet: 10, fehler: "Netz weg").zustand.beschreibung
        let ohne = eintrag(vorhanden: 0, erwartet: 0).zustand.beschreibung

        #expect(!voll.isEmpty)
        #expect(Set([voll, teil, kaputt, ohne]).count == 4)
        #expect(teil.contains("3") && teil.contains("10"))
        #expect(kaputt.contains("Netz weg"))
    }

    @Test("Ein gesetzter Fehler gewinnt über 'vollständig' — wie OfflineBadge.from(pin:)")
    func fehlerGewinntUeberVollstaendig() {
        // `OfflineBadge.from(pin:)` prüft `lastError` **vor** `lastCompletedAt`
        // (Sources/Shared/Models/OfflineBadge.swift): ein vollständiger Lauf mit
        // gesetztem Fehler ist `.failed`, nicht `.offline`. Hier gilt dasselbe,
        // sonst zeigten Kachel und Einstellungen für denselben Vermerk anderes an.
        let kaputt = eintrag(vorhanden: 10, erwartet: 10, bytes: 1_000, fehler: "Platte voll")

        #expect(kaputt.zustand == .fehlerhaft("Platte voll"))
        #expect(kaputt.zustand != .vollstaendig(anzahl: 10))
        #expect(kaputt.zustand.istFehler)
        #expect(PhoneStorageSummary(eintraege: [kaputt]).hatFehler)
    }

    @Test("Ein leerer oder nur aus Leerraum bestehender Fehlertext gewinnt nicht")
    func leererFehlertextGewinntNicht() {
        // Sonst stünde in der Zeile ein leerer Zustand — schlechter als die Zahl,
        // die man ohne den Fehler gesehen hätte.
        #expect(eintrag(vorhanden: 10, erwartet: 10, fehler: "").zustand == .vollstaendig(anzahl: 10))
        #expect(eintrag(vorhanden: 10, erwartet: 10, fehler: "   \n").zustand == .vollstaendig(anzahl: 10))
        #expect(!PhoneStorageSummary(eintraege: [eintrag(fehler: "")]).hatFehler)
    }

    @Test("Mehr vorhandene als erwartete Dateien gelten als vollständig, nicht als Überlauf")
    func mehrVorhandenAlsErwartet() {
        // Kommt vor, wenn die Mitgliedschaft schrumpft, bevor die Dateien
        // weggeräumt sind. Der Mac hält es mit `present >= expected` genauso.
        let eintrag = eintrag(vorhanden: 12, erwartet: 10)

        #expect(eintrag.zustand == .vollstaendig(anzahl: 10))
        #expect(eintrag.anteil == 1.0)
    }

    // MARK: - Der Sonderfall expected == 0

    @Test("expected == 0 ergibt weder eine Division durch null noch '100 %'")
    func keineFotosErgibtKeinenVollstaendigZustand() {
        let leer = eintrag("Frisch gepinnt", vorhanden: 0, erwartet: 0, bytes: 0)

        // Kein Anteil: `nil` statt 0 oder 1 — die Ansicht zeigt dann gar keinen
        // Fortschritt, statt einen erfundenen.
        #expect(leer.anteil == nil)
        #expect(leer.zustand == .ohneFotos)
        #expect(leer.zustand != .vollstaendig(anzahl: 0))
        #expect(!leer.zustand.beschreibung.contains("100"))
        #expect(!leer.zustand.beschreibung.contains("complete"))
    }

    @Test("expected == 0 mit gesetztem Fehler bleibt fehlerhaft")
    func keineFotosMitFehler() {
        let leer = eintrag(vorhanden: 0, erwartet: 0, fehler: "Album nicht gefunden")

        #expect(leer.zustand == .fehlerhaft("Album nicht gefunden"))
        #expect(leer.anteil == nil)
    }

    @Test("Der Anteil ist nur bei bekannter Erwartung gesetzt")
    func anteil() {
        #expect(eintrag(vorhanden: 0, erwartet: 10).anteil == 0.0)
        #expect(eintrag(vorhanden: 5, erwartet: 10).anteil == 0.5)
        #expect(eintrag(vorhanden: 10, erwartet: 10).anteil == 1.0)
        #expect(eintrag(vorhanden: 0, erwartet: 0).anteil == nil)
        // Auch ein Fehler nimmt den Fortschritt nicht weg — er steht daneben.
        #expect(eintrag(vorhanden: 5, erwartet: 10, fehler: "Netz weg").anteil == 0.5)
    }

    // MARK: - Byte-Formatierung

    @Test("Byte-Formatierung: null und wenige Bytes")
    func groesseKlein() {
        #expect(PhoneStorageSummary.groesse(0) == "0 B")
        #expect(PhoneStorageSummary.groesse(1) == "1 B")
        #expect(PhoneStorageSummary.groesse(512) == "512 B")
        #expect(PhoneStorageSummary.groesse(999) == "999 B")
        // Negative Zahlen kann eine Dateigröße nicht haben; falls doch eine
        // durchrutscht, ist "0 B" die harmlose Anzeige.
        #expect(PhoneStorageSummary.groesse(-5) == "0 B")
    }

    @Test("Byte-Formatierung: Kilo-, Mega-, Giga- und Terabyte")
    func groesseGross() {
        #expect(PhoneStorageSummary.groesse(1_000) == "1,0 KB")
        #expect(PhoneStorageSummary.groesse(1_500) == "1,5 KB")
        #expect(PhoneStorageSummary.groesse(12_345) == "12 KB")
        #expect(PhoneStorageSummary.groesse(5_000_000) == "5,0 MB")
        #expect(PhoneStorageSummary.groesse(523_000_000) == "523 MB")
        #expect(PhoneStorageSummary.groesse(2_500_000_000) == "2,5 GB")
        #expect(PhoneStorageSummary.groesse(1_000_000_000_000) == "1,0 TB")
    }

    @Test("Byte-Formatierung springt an der Einheitengrenze sauber weiter")
    func groesseAnDerGrenze() {
        // 999_999 rundet auf 1000 KB — angezeigt wird die nächste Einheit,
        // nicht eine vierstellige Zahl vor "KB".
        #expect(PhoneStorageSummary.groesse(999_999) == "1,0 MB")
        #expect(PhoneStorageSummary.groesse(999_400) == "999 KB")
    }

    /// Der Grenzfall, an dem die Nachkommastelle kippt. Entschiede sie sich am
    /// **rohen** Wert statt am gerundeten, stünde bei 9 950 Bytes „10,0 KB" und
    /// bei 10 000 „10 KB" — also eine Nachkommastelle bei genau 10, entgegen der
    /// Regel. Kein Test lag bisher in diesem Fenster.
    @Test("Bei genau zehn Einheiten fällt die Nachkommastelle weg")
    func zehnerGrenze() {
        #expect(PhoneStorageSummary.groesse(9_949) == "9,9 KB")
        #expect(PhoneStorageSummary.groesse(9_950) == "10 KB")
        #expect(PhoneStorageSummary.groesse(10_000) == "10 KB")
    }

    /// Der Übertrag an der Einheitengrenze: 999 999 Bytes runden auf 1000 KB,
    /// was als „1,0 MB" erscheinen muss, nicht als „1000 KB".
    @Test("Der Übertrag an der Einheitengrenze stimmt")
    func einheitenUebertrag() {
        #expect(PhoneStorageSummary.groesse(999) == "999 B")
        #expect(PhoneStorageSummary.groesse(999_999) == "1,0 MB")
    }

}
