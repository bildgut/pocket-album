import Foundation
import Testing
@testable import ImmichPhone

// Prüft die Tagesgruppierung des Fotos-Reiters. `PhotoFeedGrouping` ist ein
// reiner Wertetyp: kein SwiftUI, kein Netz, keine Uhr — deshalb genügen hier
// Asset-Literale mit gesetztem `fileCreatedAt` und `localDateTime`.
//
// `fileCreatedAt` ist der UTC-Zeitpunkt, `localDateTime` die Ortszeit der
// Aufnahme (Immich hängt auch daran ein `Z`, das ist Schreibweise und keine
// Zonenangabe). Die Gruppierung liest die Ortszeit; wo ein Test sie wegläßt,
// prüft er absichtlich den Rückfall auf das UTC-Datum.
//
// Zwei Prüfungen stellen `NSTimeZone.default` vorübergehend um — das ist
// prozessweit und wirkt auf `TimeZone.current`. Die Suite ist deshalb
// `.serialized`, aber **darauf beruht die Sicherheit nicht**: `.serialized`
// ordnet nur innerhalb dieser Suite, andere Suiten laufen weiter parallel und
// sähen die veränderte Standardzone. Sicher ist es heute allein deshalb, weil
// keine der übrigen iOS-Suiten datumsabhängig ist (`VideoDuration` rechnet
// reine Zeichenketten, `PhoneAlbumSections` und `PhoneOfflineModel` fassen die
// Uhr nicht an). Wer hier einen datumsabhängigen iOS-Test hinzufügt, bekommt
// sporadische Fehlschläge, deren Ursache niemand vermutet.

private func asset(
    _ id: String,
    _ fileCreatedAt: String,
    ortszeit: String? = nil,
    archiviert: Bool = false,
    geloescht: Bool = false,
    typ: AssetType = .image,
    dauer: String? = nil,
    sichtbarkeit: AssetVisibility? = nil
) -> Asset {
    Asset(
        id: id,
        type: typ,
        originalFileName: "\(id).jpg",
        fileCreatedAt: fileCreatedAt,
        fileModifiedAt: fileCreatedAt,
        localDateTime: ortszeit,
        isFavorite: false,
        isArchived: archiviert,
        duration: dauer,
        isTrashed: geloescht,
        visibility: sichtbarkeit
    )
}

@Suite("PhotoFeedGrouping", .serialized)
struct PhotoFeedGroupingTests {

    /// Führt `block` mit einer vorgegebenen Gerätezeitzone aus und stellt die
    /// vorherige danach wieder her.
    private func mitGeraetezeitzone<T>(_ id: String, _ block: () -> T) -> T {
        let vorher = NSTimeZone.default
        NSTimeZone.default = TimeZone(identifier: id)!
        defer { NSTimeZone.default = vorher }
        return block()
    }

    @Test("Zwei Assets desselben Tages landen in einem Abschnitt")
    func gleicherTagEinAbschnitt() {
        let tage = PhotoFeedGrouping.build(assets: [
            asset("a", "2026-09-05T16:00:00.000Z", ortszeit: "2026-09-05T18:00:00.000Z"),
            asset("b", "2026-09-05T06:30:00.000Z", ortszeit: "2026-09-05T08:30:00.000Z"),
        ])

        #expect(tage.count == 1)
        #expect(tage[0].id == "2026-09-05")
        #expect(tage[0].assets.map(\.id) == ["a", "b"])
    }

    @Test("Zwei Assets verschiedener Tage landen in zwei Abschnitten")
    func verschiedeneTageZweiAbschnitte() {
        let tage = PhotoFeedGrouping.build(assets: [
            asset("a", "2026-09-05T16:00:00.000Z", ortszeit: "2026-09-05T18:00:00.000Z"),
            asset("b", "2026-09-04T16:00:00.000Z", ortszeit: "2026-09-04T18:00:00.000Z"),
        ])

        #expect(tage.map(\.id) == ["2026-09-05", "2026-09-04"])
        #expect(tage.map { $0.assets.map(\.id) } == [["a"], ["b"]])
    }

    @Test("Abschnitte bleiben absteigend, innerhalb eines Abschnitts bleibt die Eingabereihenfolge")
    func reihenfolge() {
        // Innerhalb des 5. September bewusst *nicht* nach Zeit sortiert: die
        // Funktion soll die Eingabereihenfolge durchreichen, nicht neu ordnen.
        let tage = PhotoFeedGrouping.build(assets: [
            asset("a", "2026-09-05T09:00:00.000Z", ortszeit: "2026-09-05T11:00:00.000Z"),
            asset("b", "2026-09-05T17:00:00.000Z", ortszeit: "2026-09-05T19:00:00.000Z"),
            asset("c", "2026-09-05T12:00:00.000Z", ortszeit: "2026-09-05T14:00:00.000Z"),
            asset("d", "2026-08-30T12:00:00.000Z", ortszeit: "2026-08-30T14:00:00.000Z"),
            asset("e", "2025-12-31T12:00:00.000Z", ortszeit: "2025-12-31T13:00:00.000Z"),
        ])

        #expect(tage.map(\.id) == ["2026-09-05", "2026-08-30", "2025-12-31"])
        #expect(tage[0].assets.map(\.id) == ["a", "b", "c"])
        #expect(tage[1].assets.map(\.id) == ["d"])
        #expect(tage[2].assets.map(\.id) == ["e"])
    }

    @Test("Ein leeres Feld ergibt keine Abschnitte, nicht einen leeren")
    func leeresFeld() {
        #expect(PhotoFeedGrouping.build(assets: []).isEmpty)
    }

    @Test("Nur archivierte und gelöschte Assets ergeben ebenfalls keinen Abschnitt")
    func nurAussortierteErgebenKeinenAbschnitt() {
        let tage = PhotoFeedGrouping.build(assets: [
            asset("a", "2026-09-05T16:00:00.000Z", ortszeit: "2026-09-05T18:00:00.000Z", archiviert: true),
            asset("b", "2026-09-05T06:00:00.000Z", ortszeit: "2026-09-05T08:00:00.000Z", geloescht: true),
        ])

        #expect(tage.isEmpty)
    }

    @Test("Archivierte und gelöschte Assets kommen nicht vor")
    func archiviertUndGeloeschtFallenRaus() {
        let tage = PhotoFeedGrouping.build(assets: [
            asset("sichtbar", "2026-09-05T18:00:00.000Z", ortszeit: "2026-09-05T20:00:00.000Z"),
            asset("archiviert", "2026-09-05T17:00:00.000Z", ortszeit: "2026-09-05T19:00:00.000Z", archiviert: true),
            asset("geloescht", "2026-09-05T16:00:00.000Z", ortszeit: "2026-09-05T18:00:00.000Z", geloescht: true),
            asset("beides", "2026-09-05T15:00:00.000Z", ortszeit: "2026-09-05T17:00:00.000Z", archiviert: true, geloescht: true),
        ])

        #expect(tage.count == 1)
        #expect(tage[0].assets.map(\.id) == ["sichtbar"])
    }

    // MARK: - Bewegtbild-Anteile von Live Photos
    //
    // Immich legt das rund eine Sekunde lange Video eines Live Photos als
    // eigenes Asset vom Typ VIDEO an und setzt seine `visibility` auf
    // "hidden". `POST /api/search/metadata` liefert es trotzdem mit, also muß
    // `build` es wegnehmen — sonst besteht der Umschalter „Videos" zur Mehrheit
    // aus Ein-Sekunden-Fetzen (im Bestand dieses Nutzers: 6 223 solcher Anteile
    // gegenüber 4 522 echten Videos).
    //
    // Die drei Prüfungen unten hängen zusammen: Die erste zeigt, daß der Anteil
    // fällt, die zweite und dritte, daß der Filter dafür **nicht** an der
    // Laufzeit hängt — ein echtes Ein-Sekunden-Video bleibt, ein verstecktes
    // langes Video fällt.

    @Test("Der versteckte Bewegtbild-Anteil eines Live Photos kommt nicht vor")
    func versteckterBewegtbildAnteilFaelltRaus() {
        let tage = PhotoFeedGrouping.build(assets: [
            asset("echtesVideo", "2026-09-05T18:00:00.000Z", ortszeit: "2026-09-05T20:00:00.000Z",
                  typ: .video, dauer: "00:00:42.000", sichtbarkeit: .timeline),
            asset("standbild", "2026-09-05T17:00:00.000Z", ortszeit: "2026-09-05T19:00:00.000Z",
                  sichtbarkeit: .timeline),
            asset("bewegtbildAnteil", "2026-09-05T17:00:00.000Z", ortszeit: "2026-09-05T19:00:00.000Z",
                  typ: .video, dauer: "00:00:01.020", sichtbarkeit: .hidden),
        ])

        #expect(tage.count == 1)
        #expect(tage[0].assets.map(\.id) == ["echtesVideo", "standbild"])
    }

    @Test("Ein echtes Video von einer Sekunde bleibt stehen")
    func kurzesEchtesVideoBleibt() {
        // Der Preis einer Laufzeitschwelle, festgenagelt: Genau dieses Asset
        // würfe „kürzer als zwei Sekunden" weg. Im Rasterindex dieses Servers
        // stehen 280 Videos mit einer und 340 mit zwei Sekunden Laufzeit.
        let tage = PhotoFeedGrouping.build(assets: [
            asset("einSekundenVideo", "2026-09-05T18:00:00.000Z", ortszeit: "2026-09-05T20:00:00.000Z",
                  typ: .video, dauer: "00:00:01.000", sichtbarkeit: .timeline),
        ])

        #expect(tage.count == 1)
        #expect(tage[0].assets.map(\.id) == ["einSekundenVideo"])
    }

    @Test("Ein verstecktes Asset fällt unabhängig von seiner Laufzeit")
    func verstecktFaelltUnabhaengigVonDauer() {
        let tage = PhotoFeedGrouping.build(assets: [
            asset("verstecktUndLang", "2026-09-05T18:00:00.000Z", ortszeit: "2026-09-05T20:00:00.000Z",
                  typ: .video, dauer: "00:03:00.000", sichtbarkeit: .hidden),
        ])

        #expect(tage.isEmpty)
    }

    @Test("Ohne Sichtbarkeitsangabe bleibt ein Asset sichtbar")
    func ohneSichtbarkeitSichtbar() {
        // `visibility` ist `nil`, wo der Server das Feld nicht liefert oder der
        // Decoder einen unbekannten neuen Wert vorfindet. Das darf nie als
        // „versteckt" durchgehen — sonst leerte sich das Raster wortlos.
        let tage = PhotoFeedGrouping.build(assets: [
            asset("ohneAngabe", "2026-09-05T18:00:00.000Z", ortszeit: "2026-09-05T20:00:00.000Z"),
        ])

        #expect(tage.count == 1)
        #expect(tage[0].assets.map(\.id) == ["ohneAngabe"])
    }

    // MARK: - Die Tagesgrenze liegt an der Ortszeit des Fotos

    @Test("Die Tagesgrenze liegt an der Ortszeit, nicht an UTC")
    func ortszeitTrenntUmMitternacht() {
        // Beide Aufnahmen in Tokio (+9), beide mit demselben **UTC-Datum**:
        // Läge die Grenze auf UTC, stünden sie in einem Abschnitt.
        let tage = PhotoFeedGrouping.build(assets: [
            asset("nachher", "2026-09-04T15:00:01.000Z", ortszeit: "2026-09-05T00:00:01.000Z"),
            asset("vorher", "2026-09-04T14:59:59.000Z", ortszeit: "2026-09-04T23:59:59.000Z"),
        ])

        #expect(tage.map(\.id) == ["2026-09-05", "2026-09-04"])
        #expect(tage[0].assets.map(\.id) == ["nachher"])
        #expect(tage[1].assets.map(\.id) == ["vorher"])
    }

    @Test("Gleiche UTC-Zeit, verschiedene Ortszeit: verschiedene Abschnitte")
    func gleicheUtcZeitVerschiedeneOrtszeit() {
        // Derselbe Augenblick, zweimal fotografiert: in Tokio ist es schon der
        // 5. September, in Berlin noch der 4. Ein Client, der aus `fileCreatedAt`
        // rechnet, kann die beiden gar nicht trennen — egal in welcher Zone.
        let tage = PhotoFeedGrouping.build(assets: [
            asset("tokio", "2026-09-04T16:00:00.000Z", ortszeit: "2026-09-05T01:00:00.000Z"),
            asset("berlin", "2026-09-04T16:00:00.000Z", ortszeit: "2026-09-04T18:00:00.000Z"),
        ])

        #expect(tage.map(\.id) == ["2026-09-05", "2026-09-04"])
        #expect(tage[0].assets.map(\.id) == ["tokio"])
        #expect(tage[1].assets.map(\.id) == ["berlin"])
    }

    @Test("Ortszeit gegen UTC-Reihenfolge: jeder Tag genau einmal, Abschnitte absteigend")
    func ortszeitUeberholtDieUtcReihenfolge() {
        // Der Server sortiert absteigend nach UTC; die Abschnitte entstehen nach
        // Ortszeit. Beides kann auseinanderfallen, und zwar um bis zu 26 Stunden
        // (Kiritimati +14 gegen Baker Island −12): Hier steht das Foto aus Hawaii
        // (−10) in der Liste **vor** dem aus Tokio (+9), obwohl sein Tagesschlüssel
        // der frühere ist. Ein Verfahren, das nur benachbarte Assets zu Läufen
        // zusammenfaßt, ergäbe hier drei Abschnitte, davon den 4. September zweimal.
        let tage = PhotoFeedGrouping.build(assets: [
            asset("hawaii-spaet", "2026-09-04T20:00:00.000Z", ortszeit: "2026-09-04T10:00:00.000Z"),
            asset("tokio", "2026-09-04T16:00:00.000Z", ortszeit: "2026-09-05T01:00:00.000Z"),
            asset("hawaii-frueh", "2026-09-04T15:00:00.000Z", ortszeit: "2026-09-04T05:00:00.000Z"),
        ])

        #expect(tage.map(\.id) == ["2026-09-05", "2026-09-04"])
        #expect(tage.map(\.id) == tage.map(\.id).sorted(by: >))
        #expect(Set(tage.map(\.id)).count == tage.count)
        #expect(tage[0].assets.map(\.id) == ["tokio"])
        // Innerhalb des Abschnitts bleibt die Eingabereihenfolge (UTC-absteigend),
        // auch wenn das hier zufällig der Ortszeit-Reihenfolge entspricht.
        #expect(tage[1].assets.map(\.id) == ["hawaii-spaet", "hawaii-frueh"])
    }

    // MARK: - Rückfall ohne Ortszeit

    @Test("Ohne Ortszeit fällt der Tag auf das UTC-Datum zurück")
    func ohneOrtszeitUtcDatum() {
        // Ältere Server liefern `localDateTime` nicht, und `CachedAsset.toAsset()`
        // führt das Feld gar nicht. Solche Fotos dürfen nicht verschwinden: Sie
        // landen unter dem UTC-Präfix — dieselbe Wahl, die `Asset.monthKey` und
        // `yearKey` treffen.
        let tage = PhotoFeedGrouping.build(assets: [
            asset("mit", "2026-09-04T16:00:00.000Z", ortszeit: "2026-09-05T01:00:00.000Z"),
            asset("ohne", "2026-09-04T16:00:00.000Z"),
        ])

        #expect(tage.map(\.id) == ["2026-09-05", "2026-09-04"])
        #expect(tage[0].assets.map(\.id) == ["mit"])
        #expect(tage[1].assets.map(\.id) == ["ohne"])
        #expect(tage.flatMap { $0.assets.map(\.id) }.sorted() == ["mit", "ohne"])
    }

    @Test("Eine zu kurze Ortszeit fällt ebenfalls auf das UTC-Datum zurück")
    func verstuemmelteOrtszeitUtcDatum() {
        // Sonst ergäbe `prefix(10)` einen Abschnitt mit leerer oder abgeschnittener
        // Überschrift, der ans Ende der Liste rutscht.
        let tage = PhotoFeedGrouping.build(assets: [
            asset("gut", "2026-09-05T12:00:00.000Z", ortszeit: "2026-09-05T14:00:00.000Z"),
            asset("leer", "2026-09-05T12:00:00.000Z", ortszeit: ""),
            asset("kurz", "2026-09-05T12:00:00.000Z", ortszeit: "2026-09"),
        ])

        #expect(tage.count == 1)
        #expect(tage[0].id == "2026-09-05")
        #expect(tage[0].assets.map(\.id) == ["gut", "leer", "kurz"])
    }

    @Test("Ein unlesbarer Zeitstempel fällt nicht unter den Tisch")
    func unlesbarerZeitstempel() {
        // Lieber ein Foto unter einem krummen Schlüssel als ein stillschweigend
        // verschwundenes. Die Überschrift steht dann als der Schlüssel selbst.
        let tage = PhotoFeedGrouping.build(assets: [
            asset("gut", "2026-09-05T12:00:00.000Z", ortszeit: "2026-09-05T14:00:00.000Z"),
            asset("krumm", "kein-datum-hier", ortszeit: nil),
        ])

        #expect(tage.count == 2)
        #expect(tage.flatMap { $0.assets.map(\.id) }.sorted() == ["gut", "krumm"])
        // "k" sortiert absteigend vor "2", der krumme Abschnitt steht also vorn.
        #expect(tage.map(\.id) == ["kein-datum", "2026-09-05"])
        #expect(tage[0].title == "kein-datum")
    }

    // MARK: - Unabhängigkeit von der Gerätezeitzone

    @Test("Dieselbe Eingabe ergibt in zwei Gerätezeitzonen dasselbe Ergebnis")
    func zeitzonenfest() {
        // Zwei Zeitzonen, die 25 Stunden auseinanderliegen: Kiritimati (+14) und
        // Midway (−11). Läge die Tagesgrenze an der Gerätezeitzone, verschöbe sich
        // hier jeder Abschnitt. Die Aussage gilt jetzt aus einem stärkeren Grund
        // als vorher: Die Gruppierung liest gar keine Zone mehr, weder die des
        // Geräts noch eine fest verdrahtete.
        let eingabe = [
            asset("a", "2026-09-04T15:00:01.000Z", ortszeit: "2026-09-05T00:00:01.000Z"),
            asset("b", "2026-09-04T14:59:59.000Z", ortszeit: "2026-09-04T23:59:59.000Z"),
            asset("c", "2026-09-04T06:00:00.000Z", ortszeit: "2026-09-04T15:00:00.000Z"),
            asset("d", "2026-01-14T23:30:00.000Z", ortszeit: "2026-01-15T08:30:00.000Z"),
            asset("e", "2026-01-14T23:30:00.000Z"),   // ohne Ortszeit: UTC-Rückfall
        ]

        let vorne = mitGeraetezeitzone("Pacific/Kiritimati") { PhotoFeedGrouping.build(assets: eingabe) }
        let hinten = mitGeraetezeitzone("Pacific/Midway") { PhotoFeedGrouping.build(assets: eingabe) }

        // Nicht nur gleich, sondern gleich *und* richtig — sonst wäre der Test auch
        // mit einer durchweg falschen Zuordnung zufrieden.
        #expect(vorne.map(\.id) == ["2026-09-05", "2026-09-04", "2026-01-15", "2026-01-14"])
        #expect(vorne.map(\.id) == hinten.map(\.id))
        #expect(vorne.map(\.title) == hinten.map(\.title))
        #expect(vorne.map { $0.assets.map(\.id) } == hinten.map { $0.assets.map(\.id) })
        #expect(vorne == hinten)
    }

    @Test("Auch die Überschriften hängen nicht an der Gerätezeitzone")
    func ueberschrift() {
        let tage = mitGeraetezeitzone("Pacific/Kiritimati") {
            PhotoFeedGrouping.build(assets: [
                asset("a", "2026-09-05T10:00:00.000Z", ortszeit: "2026-09-05T12:00:00.000Z")
            ])
        }

        // Der Testlauf ist auf Englisch gestellt (Scheme `ImmichPhoneTests`).
        #expect(tage.map(\.title) == ["Saturday, September 5, 2026"])
    }

    // MARK: - Überschriften

    private static let de = Locale(identifier: "de_DE")
    private static let en = Locale(identifier: "en_US")

    @Test("Der Wochentag stimmt über Jahres-, Schalt- und Jahrhundertgrenzen")
    func wochentage() {
        // Stichproben an den Stellen, an denen Datumsrechnung typischerweise
        // danebengreift: Januar, der 29. Februar eines Schaltjahres, ein
        // Nicht-Schaltjahr zum Jahrhundertwechsel (1900) und eines, das doch eins ist (2000).
        let de = Self.de
        #expect(PhotoFeedGrouping.titel(fuerTagesschluessel: "2026-09-05", sprache: de) == "Samstag, 5. September 2026")
        #expect(PhotoFeedGrouping.titel(fuerTagesschluessel: "2026-01-15", sprache: de) == "Donnerstag, 15. Januar 2026")
        #expect(PhotoFeedGrouping.titel(fuerTagesschluessel: "2026-02-28", sprache: de) == "Samstag, 28. Februar 2026")
        #expect(PhotoFeedGrouping.titel(fuerTagesschluessel: "2024-02-29", sprache: de) == "Donnerstag, 29. Februar 2024")
        #expect(PhotoFeedGrouping.titel(fuerTagesschluessel: "2000-02-29", sprache: de) == "Dienstag, 29. Februar 2000")
        #expect(PhotoFeedGrouping.titel(fuerTagesschluessel: "1900-03-01", sprache: de) == "Donnerstag, 1. März 1900")
        #expect(PhotoFeedGrouping.titel(fuerTagesschluessel: "1969-07-20", sprache: de) == "Sonntag, 20. Juli 1969")
        #expect(PhotoFeedGrouping.titel(fuerTagesschluessel: "2025-12-31", sprache: de) == "Mittwoch, 31. Dezember 2025")
    }

    @Test("Die Überschrift folgt der Sprache: Reihenfolge und Namen")
    func spracheDerUeberschrift() {
        #expect(PhotoFeedGrouping.titel(fuerTagesschluessel: "2026-09-05", sprache: Self.en) == "Saturday, September 5, 2026")
        #expect(PhotoFeedGrouping.titel(fuerTagesschluessel: "1969-07-20", sprache: Self.en) == "Sunday, July 20, 1969")
    }

    @Test("Die Überschrift hängt auch mit Kalender nicht an der Gerätezeitzone")
    func ueberschriftZonenfest() {
        // Formatiert wird in UTC: Um Mitternacht UTC wäre in Honolulu noch der Vortag.
        let titel = mitGeraetezeitzone("Pacific/Honolulu") {
            PhotoFeedGrouping.titel(fuerTagesschluessel: "2026-01-01", sprache: Self.de)
        }
        #expect(titel == "Donnerstag, 1. Januar 2026")
    }

    @Test("Ein Schlüssel, der kein Datum ist, steht als er selbst")
    func unlesbarerSchluessel() {
        #expect(PhotoFeedGrouping.titel(fuerTagesschluessel: "") == "")
        #expect(PhotoFeedGrouping.titel(fuerTagesschluessel: "kein Datum") == "kein Datum")
        #expect(PhotoFeedGrouping.titel(fuerTagesschluessel: "2026-13-01") == "2026-13-01")
        #expect(PhotoFeedGrouping.titel(fuerTagesschluessel: "2026-00-01") == "2026-00-01")
        #expect(PhotoFeedGrouping.titel(fuerTagesschluessel: "2026-09-00") == "2026-09-00")
        #expect(PhotoFeedGrouping.titel(fuerTagesschluessel: "2026-09-32") == "2026-09-32")
        // Unmögliche Tage dürfen nicht still in den Folgemonat rutschen.
        #expect(PhotoFeedGrouping.titel(fuerTagesschluessel: "2026-02-30") == "2026-02-30")
    }
}
