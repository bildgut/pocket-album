import Foundation

/// Ein Tagesabschnitt des Fotos-Reiters.
///
/// Bewusst ein eigener Typ statt `AssetGroup` (`Sources/Shared/Models/Asset.swift`):
/// `AssetGroup` trägt die adaptiven Section-Ids der Mac-Zeitleiste (Tag, Woche,
/// Monat, Jahr) und ist weder `Equatable` noch `Sendable`. Hier ist ein Abschnitt
/// immer genau ein Tag, und die Prüfungen vergleichen ganze Abschnitte.
struct PhotoFeedDay: Identifiable, Hashable, Sendable {
    /// "2026-09-05" — der Tag, an dem **dort** fotografiert wurde
    /// (`Asset.localDateTime`, siehe `PhotoFeedGrouping`).
    /// Absteigend lexikografisch sortiert entspricht das der Datumsordnung.
    let id: String
    /// "Samstag, 5. September 2026"
    let title: String
    /// In Eingabereihenfolge, also so, wie der Server sie geliefert hat.
    let assets: [Asset]
}

/// Gruppiert die Fotos des Reiters „Fotos" nach Tagen.
///
/// Reine Funktion: kein SwiftUI, kein Netz, keine Uhr. `build` hängt weder an
/// „jetzt" noch an irgendeiner Zeitzone — weder an der des Geräts noch an einer
/// im Quelltext festgenagelten.
///
/// ## Der Tag kommt vom Foto, nicht aus einer Rechnung
///
/// Der Tagesschlüssel sind schlicht die ersten zehn Zeichen von
/// `Asset.localDateTime` — der Ortszeit, die Immich beim Import aus den
/// EXIF-Daten ableitet und laut Spezifikation genau für „timeline grouping by
/// 'local' days" vorhält. Ein Foto, das um 1 Uhr morgens in Tokio entstand,
/// steht damit unter dem japanischen Datum, und zwar auch dann, wenn das
/// Telefon in Berlin liegt.
///
/// Deshalb kommt hier **keine Gerätezone und keine Sommerzeit-Erwägung** mehr
/// vor: Die Zeichenkette trägt die Ortszeit bereits, jedes Umrechnen würde sie
/// nur wieder wegwerfen. (Einzige Ausnahme ist die Überschrift: Sie formatiert
/// über einen `Calendar`, aber fest in UTC auf beiden Seiten — siehe
/// `formatiere`.) (Immich hängt an den Wert ein
/// `Z`; das ist Schreibweise, keine Zonenangabe.) Der Mac gruppiert weiter über
/// `fileCreatedAt` mit `Calendar.current` — zuhause dasselbe Ergebnis, im
/// Ausland aufgenommene Fotos ordnet das Telefon jetzt richtiger ein als er.
///
/// ## Warum ein Wörterbuch und kein Durchlaufen benachbarter Assets
///
/// Der Server liefert absteigend nach UTC (`order: "desc"` in
/// `ImmichAPIClient.searchAssets`), die Abschnitte entstehen nach Ortszeit —
/// und **beides kann auseinanderfallen**. Die Zonen der Welt spannen 26 Stunden
/// (Kiritimati +14 bis Baker Island −12), also kann ein in der Liste *späteres*
/// Foto durchaus einen *späteren* Tagesschlüssel haben: Eine Aufnahme aus Hawaii
/// (−10) um 20:00 UTC steht vor einer aus Tokio (+9) um 16:00 UTC, trägt aber
/// den 4. September, während die aus Tokio schon den 5. trägt.
///
/// Ein Verfahren, das nur Läufe benachbarter Assets zusammenfaßt, ergäbe dann
/// denselben Tag mehrfach und eine Abschnittsfolge, die nicht mehr absteigt.
/// Deshalb sammelt `build` in ein Wörterbuch und sortiert die Schlüssel am Ende
/// **global**: Jeder Tag erscheint genau einmal, die Abschnitte stehen streng
/// absteigend. Innerhalb eines Abschnitts bleibt die Eingabereihenfolge stehen;
/// bei gemischten Zonen an einem Tag ist das die UTC- und nicht die
/// Ortszeitreihenfolge — die Sortierung ist Sache des Servers, nicht dieser
/// Funktion.
///
/// ## Rückfall ohne Ortszeit
///
/// `localDateTime` ist `nil`, wenn der Server es nicht liefert (ältere Stände)
/// oder das Asset nicht direkt aus einer API-Antwort stammt — `CachedAsset.toAsset()`
/// führt das Feld nicht. Dann gilt das **UTC-Datum** aus `fileCreatedAt.prefix(10)`:
/// dieselbe Wahl, die `Asset.monthKey` und `yearKey` treffen, und die einzige,
/// die ohne Zone auskommt. Sie kann um einen Tag danebenliegen; das ist immer
/// noch besser als ein Foto, das stillschweigend aus dem Reiter verschwindet.
enum PhotoFeedGrouping {

    /// Erwartet die Assets absteigend sortiert (so liefert sie
    /// `ImmichAPIClient.searchAssets`) und gibt die Tagesabschnitte absteigend
    /// zurück — auch dort, wo Orts- und UTC-Reihenfolge auseinanderfallen (siehe
    /// oben). Innerhalb eines Abschnitts bleibt die Eingabereihenfolge unangetastet.
    ///
    /// Archivierte und gelöschte Assets fallen heraus: `searchAssets` schickt
    /// `withArchived: true` mit, der Reiter zeigt aber die laufende Mediathek.
    ///
    /// ## Und die Bewegtbild-Anteile von Live Photos
    ///
    /// Dritte Bedingung: ``Asset/istVersteckterBewegtbildAnteil``, also
    /// `visibility == "hidden"`. Immich legt das rund eine Sekunde lange Video
    /// eines Live Photos als eigenes Asset vom Typ `VIDEO` an und markiert es
    /// serverseitig als versteckt. `POST /api/search/metadata` — der einzige
    /// Weg dieses Reiters — liefert es ohne ausdrücklichen Filter trotzdem mit,
    /// und im Umschalter „Videos" stellte es die echten Videos zahlenmäßig in
    /// den Schatten. Der Mac zeigt es nie, weil sein Bestand aus dem
    /// Sync-Stream kommt und der es gar nicht erst schickt.
    ///
    /// **Nicht** an der Laufzeit erkannt: Eine Schwelle „kürzer als zwei
    /// Sekunden" würfe auch echte kurze Videos weg, und davon hat diese
    /// Mediathek reichlich (im Rasterindex: 280 Videos mit einer Sekunde,
    /// 340 mit zweien). `visibility` benennt die Sache, statt sie zu schätzen.
    ///
    /// **Der Preis, ehrlich benannt:** Wo ein Bewegtbild-Anteil serverseitig
    /// nicht versteckt ist, bleibt er stehen. Im Bestand dieses Nutzers sind das
    /// 15 von 6 223 — Dateien der Form `…_L0_001-IMG_1234.MOV`, die einzeln
    /// hochgeladen und erst nachträglich gepaart wurden und deshalb
    /// `visibility == "timeline"` tragen. Sie stehen aus demselben Grund auch
    /// in der Mac-Zeitleiste. Umgekehrt fällt **kein** echtes Video weg:
    /// Ein Video, das der Nutzer selbst sehen will, ist nicht versteckt.
    /// Bildsuche: **ein** Abschnitt in der Reihenfolge des Servers. Die Treffer sind
    /// nach Relevanz sortiert; nach Tagen gruppiert stünden die besten verstreut
    /// zwischen schwachen, denn CLIP liefert ohne Schwelle fast immer die volle Menge.
    /// Ausgefiltert wird wie in ``build(assets:)``.
    ///
    /// **Keine Schwelle möglich (geprüft 29.09.2026):** `POST /api/search/smart`
    /// liefert `SearchResponseDto.assets.items` als nackte `AssetResponseDto`s —
    /// ohne Score und ohne Distanz; der Server sortiert nach der Embedding-Distanz,
    /// gibt sie aber nicht heraus. Unsinn wie „xqzv" ergibt deshalb die ganze
    /// Mediathek als „Best Matches", und die App kann schwache Treffer nicht
    /// erkennen, ohne zu raten.
    static func inReihenfolge(assets: [Asset], titel: String) -> [PhotoFeedDay] {
        let sichtbar = assets.filter {
            !$0.isArchived && !$0.isTrashed && !$0.istVersteckterBewegtbildAnteil
        }
        guard !sichtbar.isEmpty else { return [] }
        return [PhotoFeedDay(id: "bildsuche", title: titel, assets: sichtbar)]
    }

    static func build(assets: [Asset]) -> [PhotoFeedDay] {
        var nachTag: [String: [Asset]] = [:]

        for asset in assets
        where !asset.isArchived && !asset.isTrashed && !asset.istVersteckterBewegtbildAnteil {
            nachTag[tagesschluessel(fuer: asset), default: []].append(asset)
        }

        return nachTag.keys.sorted(by: >).map { schluessel in
            PhotoFeedDay(id: schluessel, title: titel(fuerTagesschluessel: schluessel), assets: nachTag[schluessel]!)
        }
    }

    /// "2026-09-05" aus der Ortszeit des Fotos, ersatzweise aus seinem
    /// UTC-Zeitstempel.
    ///
    /// Die Längenprüfung fängt nicht nur `nil`, sondern auch einen leeren oder
    /// abgeschnittenen Wert ab: `prefix(10)` ergäbe daraus einen Abschnitt mit
    /// verstümmelter Überschrift, der ans Ende der Liste rutschte. Derselbe
    /// Schutz gilt für den Rückfall — sonst hielte die Zusage nur für die eine
    /// Hälfte. Ein leeres `fileCreatedAt` ist zwar nicht erreichbar (der
    /// Decoder liest es als Pflichtfeld), aber ein Versprechen, das nur meistens
    /// gilt, ist keins: Der Schlüssel `""` ergäbe einen Abschnitt mit
    /// **unsichtbarer** Überschrift ganz unten in der Liste.
    private static func tagesschluessel(fuer asset: Asset) -> String {
        if let ortszeit = asset.localDateTime, ortszeit.count >= 10 {
            return String(ortszeit.prefix(10))
        }
        if !asset.fileCreatedAt.isEmpty {
            return String(asset.fileCreatedAt.prefix(10))
        }
        return "0000-00-00"
    }

    /// "2026-09-05" → "Saturday, September 5, 2026" (Deutsch: "Samstag, 5. September
    /// 2026"). Ein Schlüssel, der sich nicht als Datum lesen lässt (nur aus dem
    /// Rückfall oben möglich), steht als er selbst.
    static func titel(fuerTagesschluessel schluessel: String, sprache: Locale = .current) -> String {
        let teile = schluessel.split(separator: "-")
        guard teile.count == 3,
              let jahr = Int(teile[0]), let monat = Int(teile[1]), let tag = Int(teile[2])
        else { return schluessel }

        let cacheSchluessel = "\(sprache.identifier)|\(schluessel)"
        if let fertig = zwischenspeicher.titel(cacheSchluessel) { return fertig }
        let titel = formatiere(jahr: jahr, monat: monat, tag: tag, vorlage: "EEEEdMMMMy", sprache: sprache)
            ?? schluessel
        zwischenspeicher.merkeTitel(titel, fuer: cacheSchluessel)
        return titel
    }

    /// Formatierer und fertige Tagestitel. Gemessen: 25 ms je Gruppierung schon bei
    /// 133 Fotos, fast alles im Anlegen eines `DateFormatter` je Tag — und der Feed
    /// gruppiert bei jeder Seite alles neu.
    private static let zwischenspeicher = FormatZwischenspeicher()

    /// Formatiert ein Kalenderdatum aus drei Zahlen in der Reihenfolge und den
    /// Namen der Sprache (`vorlage` ist eine `DateFormatter`-Schablone).
    ///
    /// **Alles in UTC**, Kalender wie Formatierer: Die Zahlen sind schon die
    /// Ortszeit des Fotos. Eine Gerätezone käme nur dazwischen — ein Datum, das um
    /// Mitternacht UTC entsteht und in Kalifornien formatiert wird, stünde einen
    /// Tag früher. Mit derselben Zone auf beiden Seiten gibt es keine Verschiebung.
    ///
    /// `nil` für Unmögliches wie den 30. Februar: `Calendar` würde ihn still auf
    /// den 2. März schieben, deshalb der Rückvergleich.
    static func formatiere(jahr: Int, monat: Int, tag: Int, vorlage: String, sprache: Locale) -> String? {
        guard jahr >= 1, (1...12).contains(monat), (1...31).contains(tag) else { return nil }
        var kalender = Calendar(identifier: .gregorian)
        kalender.timeZone = .gmt
        let teile = DateComponents(year: jahr, month: monat, day: tag, hour: 12)
        guard let datum = kalender.date(from: teile) else { return nil }
        let zurueck = kalender.dateComponents([.year, .month, .day], from: datum)
        guard zurueck.year == jahr, zurueck.month == monat, zurueck.day == tag else { return nil }

        return zwischenspeicher.formatierer(vorlage: vorlage, sprache: sprache, kalender: kalender)
            .string(from: datum)
    }
}

/// Threadsicherer Zwischenspeicher für ``PhotoFeedGrouping`` — die Gruppierung
/// läuft abseits des Hauptthreads. `DateFormatter.string(from:)` ist seit iOS 7
/// threadsicher; geschützt werden nur die Wörterbücher.
final class FormatZwischenspeicher: @unchecked Sendable {
    private let lock = NSLock()
    private var formatierer: [String: DateFormatter] = [:]
    private var titel: [String: String] = [:]

    func formatierer(vorlage: String, sprache: Locale, kalender: Calendar) -> DateFormatter {
        let schluessel = "\(sprache.identifier)|\(vorlage)"
        lock.lock(); defer { lock.unlock() }
        if let vorhanden = formatierer[schluessel] { return vorhanden }
        let neu = DateFormatter()
        neu.calendar = kalender
        neu.timeZone = .gmt
        neu.locale = sprache
        neu.setLocalizedDateFormatFromTemplate(vorlage)
        formatierer[schluessel] = neu
        return neu
    }

    func titel(_ schluessel: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return titel[schluessel]
    }

    func merkeTitel(_ wert: String, fuer schluessel: String) {
        lock.lock(); defer { lock.unlock() }
        titel[schluessel] = wert
    }
}
