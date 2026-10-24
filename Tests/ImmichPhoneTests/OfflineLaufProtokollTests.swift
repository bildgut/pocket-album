import Foundation
import Testing
@testable import ImmichPhone

@Suite("OfflineLaufProtokoll", .serialized)
struct OfflineLaufProtokollTests {

    private func protokoll() -> OfflineLaufProtokoll {
        let suite = "offline.laufprotokoll.test.\(UUID().uuidString)"
        return OfflineLaufProtokoll(defaults: UserDefaults(suiteName: suite)!)
    }

    @Test("Zeitangaben: Sekunden und Minuten, Unsinn wird zum Fragezeichen")
    func sekunden() {
        #expect(OfflineLaufEintrag.sek(4.4) == "4.4 s")
        #expect(OfflineLaufEintrag.sek(12.4) == "12 s")
        #expect(OfflineLaufEintrag.sek(125) == "2 min 5 s")
        #expect(OfflineLaufEintrag.sek(.nan) == "?")
        #expect(OfflineLaufEintrag.sek(-1) == "?")
    }

    @Test("Die Zeile nennt Auflösung, Ladezahlen, Netz und ersten Fehler")
    func zeile() {
        var e = OfflineLaufEintrag(start: Date(timeIntervalSince1970: 0))
        e.ende = .netzTeuer
        e.aufloesungSek = 95
        e.geplant = 200
        e.geladen = 80
        e.ladeSek = 40
        e.fehler = 3
        e.netzTeuerBeiStart = true
        e.ersterFehler = "timed out"
        let z = e.zeile(sprache: Locale(identifier: "de_DE"))
        #expect(z.contains("angehalten (Netz teuer)"))
        #expect(z.contains("Auflösung 1 min 35 s"))
        #expect(z.contains("80/200 geladen in 40 s, 3 fehlgeschlagen"))
        #expect(z.contains("Netz: teuer/eingeschränkt"))
        #expect(z.contains("Fehler: timed out"))
    }

    @Test("Ein Lauf ohne Zahlen nennt keine Ladezeile")
    func ohneZahlen() {
        var e = OfflineLaufEintrag(start: Date())
        e.ende = .nichtsZuTun
        #expect(!e.zeile().contains("geladen"))
    }

    @Test("Das Protokoll behält nur die letzten Läufe, neueste zuerst im Text")
    func ringpuffer() {
        let p = protokoll()
        for i in 0..<(OfflineLaufProtokoll.hoechstens + 5) {
            var e = OfflineLaufEintrag(start: Date(timeIntervalSince1970: Double(i)))
            e.geplant = i
            p.haengeAn(e)
        }
        #expect(p.eintraege.count == OfflineLaufProtokoll.hoechstens)
        #expect(p.eintraege.first?.geplant == 5)
        #expect(p.eintraege.last?.geplant == OfflineLaufProtokoll.hoechstens + 4)
        let ersteZeile = p.text(sprache: Locale(identifier: "de_DE")).split(separator: "\n").first.map(String.init) ?? ""
        #expect(ersteZeile.contains("/\(OfflineLaufProtokoll.hoechstens + 4) geladen"))
    }

    @Test("Leeren entfernt alles")
    func leeren() {
        let p = protokoll()
        p.haengeAn(OfflineLaufEintrag(start: Date()))
        p.leere()
        #expect(p.eintraege.isEmpty)
    }
}

@Suite("OfflineMessung")
struct OfflineMessungTests {

    private func datei(_ sek: Double, ttfb: Double? = 1, neu: Bool = true, bytes: Int64 = 100_000,
                       versuche: Int = 1, fehler: String? = nil, timeout: Bool = false) -> OfflineDateiMessung {
        OfflineDateiMessung(
            gesamtSek: sek,
            transfer: OfflineTransferMetrik(ttfbSek: ttfb, verbindungSek: neu ? 0.8 : nil, wiederverwendet: !neu,
                                            protokoll: "h2", bytes: bytes),
            versuche: versuche, fehler: fehler, zeitueberschreitung: timeout)
    }

    @Test("Perzentile: nächster Rang, leere Liste und Unsinn")
    func perzentile() {
        let w = [1.0, 2, 3, 4, 5, 6, 7, 8, 9, 10]
        #expect(OfflineMessSammler.perzentil(w, 0.5) == 5)
        #expect(OfflineMessSammler.perzentil(w, 0.9) == 9)
        #expect(OfflineMessSammler.perzentil([], 0.5) == nil)
        #expect(OfflineMessSammler.perzentil([.nan, 3], 0.5) == 3)
    }

    @Test("Zusammenfassung zählt Dateien, Bytes, Verbindungen und Wiederholungen")
    func zusammenfassung() {
        var s = OfflineMessSammler()
        s.nimm(datei(2, neu: true), minute: 0)
        s.nimm(datei(4, neu: false, versuche: 2), minute: 0)
        s.nimm(datei(40, neu: false), minute: 2)
        s.nimm(datei(120, fehler: "URLError -1001", timeout: true), minute: 2)
        s.nimm(datei(1, fehler: "HTTP 404"), minute: 2)
        let m = s.zusammenfassung(ladeSek: 100)
        #expect(m.dateienOk == 3)
        #expect(m.bytes == 300_000)
        #expect(m.ueber30s == 1)
        #expect(m.gesamtMedian == 4)
        #expect(m.gesamtMax == 40)
        #expect(m.neueVerbindungen == 1)
        #expect(m.wiederverwendet == 2)
        #expect(m.wiederholte == 1)
        #expect(m.zeitueberschreitungen == 1)
        #expect(m.fehlerArten == ["URLError -1001": 1, "HTTP 404": 1])
        #expect(m.proMinute == [2, 0, 1])
        #expect(m.protokolle == ["h2": 3])
        #expect(m.durchsatzKBs != nil)
    }

    @Test("Fehlerschlüssel benennt URLError-Code und HTTP-Status")
    func schluessel() {
        let t = OfflineDateiMessung.schluessel(fuer: URLError(.timedOut))
        #expect(t.text == "URLError -1001" && t.zeitueberschreitung)
        let h = OfflineDateiMessung.schluessel(fuer: APIError.httpError(404))
        #expect(h.text == "HTTP 404" && !h.zeitueberschreitung)
        #expect(OfflineDateiMessung.schluessel(fuer: APIError.httpError(408)).zeitueberschreitung)
    }

    @Test("Details nennen Auslöser, Abbruchgrund, Netz und Messung")
    func details() {
        var e = OfflineLaufEintrag(start: Date(timeIntervalSince1970: 0))
        e.ausloeser = "Vordergrund"
        e.abbruchGrund = "Hintergrundzeit abgelaufen"
        e.netzStart = "WLAN"
        e.netzEnde = "Mobilfunk (teuer)"
        e.netzWechsel = 2
        var s = OfflineMessSammler()
        s.nimm(OfflineDateiMessung(gesamtSek: 3, transfer: nil, versuche: 1, fehler: nil, zeitueberschreitung: false), minute: 0)
        e.messung = s.zusammenfassung(ladeSek: 10)
        let text = e.details().joined(separator: "\n")
        #expect(text.contains("Auslöser: Vordergrund"))
        #expect(text.contains("Abbruch: Hintergrundzeit abgelaufen"))
        #expect(text.contains("WLAN → Mobilfunk (teuer) · 2 Wechsel"))
        #expect(text.contains("Median 3.0 s"))
        #expect(text.contains("Fertig je Minute: 1"))
    }

    @Test("Einträge ohne die neuen Felder bleiben lesbar")
    func altesFormat() throws {
        let alt = #"{"start":0,"ende":"fertig","geplant":3,"geladen":3,"fehler":0,"netzTeuerBeiStart":false,"erzwungen":false}"#
        let e = try JSONDecoder().decode(OfflineLaufEintrag.self, from: Data(alt.utf8))
        #expect(e.messung == nil && e.ausloeser == nil)
    }

    @Test("Der Bildschirm bleibt nur wach, wenn geladen wird und die App vorn ist")
    func bildschirm() {
        #expect(PhoneBildschirmWach.soll(syncLaeuft: true, aktiv: true))
        #expect(!PhoneBildschirmWach.soll(syncLaeuft: true, aktiv: false))
        #expect(!PhoneBildschirmWach.soll(syncLaeuft: false, aktiv: true))
    }
}
