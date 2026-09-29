import Foundation
import Nuke

/// Benennt die Ursache eines fehlgeschlagenen Thumbnail-Ladevorgangs.
///
/// **Warum es diesen Typ überhaupt gibt.** `ImagePipeline.Error` ist zwar
/// `CustomStringConvertible`, aber **nicht** `LocalizedError`. Wer
/// `localizedDescription` protokolliert, bekommt deshalb nur die Hülle, die
/// Foundation für einen unbeschrifteten Swift-Fehler baut:
///
///     The operation couldn’t be completed. (Nuke.ImagePipeline.Error error 0.)
///
/// Und diese Zahl ist eine Falle. Sie ist **nicht** der Index in der
/// Deklarationsreihenfolge, sondern das ABI-Etikett der Aufzählung: Fälle *mit*
/// Nutzlast kommen zuerst, danach die leeren. Am 06.09.2026 gegen die
/// ausgecheckte Nuke-Quelle gemessen (`swift run` gegen dasselbe Paket, das die
/// App linkt):
///
///     dataLoadingFailed → 0      dataMissingInCache → 4
///     decoderNotRegistered → 1   dataIsEmpty → 5
///     decodingFailed → 2         imageRequestMissing → 6
///     processingFailed → 3       pipelineInvalidated → 7
///
/// „error 0" heißt also **`dataLoadingFailed`** — ein Netz- oder HTTP-Fehler —
/// und gerade nicht `dataMissingInCache`, das man beim Lesen der
/// Quelldatei-Reihenfolge dort vermutet (und das ohnehin nur mit
/// `returnCacheDataDontLoad` entstehen kann, einer Option, die diese App
/// nirgends setzt). Genau diese Fehlzuordnung hat eine Untersuchung in die
/// falsche Richtung geschickt. ``ThumbnailFehlerUrsacheTests`` hält die
/// Messung fest, damit ein Nuke-Update, das die Fälle umsortiert, auffällt.
///
/// Die eigentliche Auskunft — HTTP-Status, `URLError`-Code — steckt in der
/// **eingepackten** Nutzlast und ist nur über `description` bzw. das Auspacken
/// zu bekommen. Deshalb protokolliert die Kachel ab jetzt beides: einen kurzen,
/// gruppierbaren Schlüssel und einmal je Ursache die vollen Einzelheiten.
enum ThumbnailFehlerUrsache {

    /// Kurzer, stabiler Schlüssel zum Gruppieren — „HTTP 404", „URLError -1001".
    /// Bewusst ohne Asset-ID und ohne URL: Zwei Kacheln mit derselben Ursache
    /// sollen denselben Schlüssel ergeben, sonst zählt die Drossel nichts
    /// zusammen.
    static func schluessel(_ fehler: any Error) -> String {
        guard let nuke = fehler as? ImagePipeline.Error else {
            return schluesselFuerLadefehler(fehler)
        }
        switch nuke {
        case .dataLoadingFailed(let innen): return schluesselFuerLadefehler(innen)
        case .dataMissingInCache: return "Nuke: nicht im Cache"
        case .dataIsEmpty: return "Nuke: leere Antwort"
        case .decoderNotRegistered: return "Nuke: kein Decoder"
        case .decodingFailed: return "Nuke: nicht dekodierbar"
        case .processingFailed: return "Nuke: Verarbeitung fehlgeschlagen"
        case .imageRequestMissing: return "Nuke: Anfrage ohne URL"
        case .pipelineInvalidated: return "Nuke: Pipeline verworfen"
        }
    }

    private static func schluesselFuerLadefehler(_ fehler: any Error) -> String {
        if let ladefehler = fehler as? DataLoader.Error {
            switch ladefehler {
            case .statusCodeUnacceptable(let status): return "HTTP \(status)"
            }
        }
        let ns = fehler as NSError
        if ns.domain == NSURLErrorDomain { return "URLError \(ns.code)" }
        return "\(ns.domain) \(ns.code)"
    }

    /// Die lange Fassung für die erste Meldung je Ursache. `description` (nicht
    /// `localizedDescription`!) nennt bei `dataLoadingFailed` den eingepackten
    /// Fehler mit Domäne und Code.
    static func einzelheiten(_ fehler: any Error) -> String {
        if let nuke = fehler as? ImagePipeline.Error { return nuke.description }
        return fehler.localizedDescription
    }
}

/// Entscheidet, welche Thumbnail-Fehlschläge ins Protokoll gehören.
///
/// **Der Anlass:** Auf dem Gerät des Nutzers standen in 10 Minuten **250**
/// gleichlautende Fehlerzeilen aus ``PhoneGridTile`` — 98 % aller Einträge der
/// App. Der Ringpuffer des Geräteprotokolls war damit so voll, dass andere
/// Meldungen verdrängt wurden und eine unabhängige Untersuchung daran
/// scheiterte. Der Grund für die Menge liegt in der Sache: Nuke merkt sich
/// Fehlschläge nicht, und eine Rasterkachel wird beim Scrollen laufend neu
/// gebaut — dasselbe kaputte Asset meldet sich also bei jedem Vorbeiscrollen
/// erneut.
///
/// **Was bleibt:** Der ursprüngliche Grund fürs Protokollieren gilt weiter — ein
/// Asset ohne Vorschau sieht für den Nutzer aus wie eines, das gerade lädt, und
/// das soll nicht stumm bleiben. Nur die *Menge* war das Problem. Deshalb:
///
/// - **einmal je Ursache** die volle Zeile mit Asset-ID und Einzelheiten
///   (`.error`, landet auf Platte) — sie trägt die Auskunft, die die Frage
///   „warum?" beantwortet,
/// - danach **Sammelmeldungen** (`.error`) mit Anzahl, Zahl der betroffenen
///   Assets und häufigster Ursache,
/// - alles dazwischen nur `.debug` (nicht auf Platte, aber mit
///   `log stream --level debug` weiterhin vollständig sichtbar).
///
/// Aus 250 Zeilen werden so rund ein Dutzend.
///
/// Reiner Wertetyp: keine Uhr, kein Logger, kein SwiftUI — die Zeit kommt als
/// Parameter herein, damit ``ThumbnailFehlerDrosselTests`` sie stellen kann.
struct ThumbnailFehlerDrossel {

    /// Zusammenfassung eines Abschnitts. `sekunden` ist der Abstand zum Beginn
    /// des Abschnitts, nicht zur letzten Meldung.
    struct Sammelmeldung: Equatable {
        var fehlschlaege: Int
        var assets: Int
        var haeufigsteUrsache: String
        var ursachenAnzahl: Int
        var sekunden: Int
    }

    enum Ausgabe: Equatable {
        /// Diese Ursache war noch nie da — volle Zeile, `.error`.
        case erste(ursache: String)
        /// Der Abschnitt ist voll oder abgelaufen — Zusammenfassung, `.error`.
        case sammel(Sammelmeldung)
        /// Nur `.debug`, sonst nichts.
        case unterdrueckt
    }

    /// Nach so vielen unterdrückten Fehlschlägen kommt eine Sammelmeldung …
    var sammelSchwelle: Int = 25
    /// … spätestens aber nach dieser Zeit.
    ///
    /// **Ehrlich gesagt:** Beide Grenzen prüft erst der *nächste* Fehlschlag.
    /// Hören die Fehler auf, bleibt der angebrochene Abschnitt ungemeldet
    /// liegen — bis zu 24 Fehlschläge. Das ist der Preis dafür, dass hier
    /// keine Zeitschaltung läuft, die auf einem Telefon auch dann aufwacht,
    /// wenn gerade nichts passiert. Für die Frage „gibt es hier ein Problem?"
    /// reicht es: Ein Problem, das der Rede wert ist, hört nicht nach 24
    /// Kacheln auf.
    var fensterLaenge: TimeInterval = 60
    /// Obergrenze der gemerkten Ursachen — auch das Melden neuer Ursachen ist
    /// eine Quelle von Zeilen, und der Speicher soll nicht mitwachsen.
    var ursachenGrenze: Int = 12

    private var bekannteUrsachen: Set<String> = []
    private var abschnittStart: Date?
    private var fehlschlaege = 0
    private var assets: Set<String> = []
    private var ursachen: [String: Int] = [:]
    private var seitLetzterSammelmeldung = 0

    mutating func melde(assetId: String, ursache: String, jetzt: Date) -> Ausgabe {
        let start = abschnittStart ?? jetzt
        abschnittStart = start

        fehlschlaege += 1
        assets.insert(assetId)
        ursachen[ursache, default: 0] += 1

        if bekannteUrsachen.count < ursachenGrenze, bekannteUrsachen.insert(ursache).inserted {
            return .erste(ursache: ursache)
        }

        seitLetzterSammelmeldung += 1
        let verstrichen = jetzt.timeIntervalSince(start)
        guard seitLetzterSammelmeldung >= sammelSchwelle || verstrichen >= fensterLaenge else {
            return .unterdrueckt
        }

        let meldung = Sammelmeldung(
            fehlschlaege: fehlschlaege,
            assets: assets.count,
            haeufigsteUrsache: haeufigsteUrsache() ?? ursache,
            ursachenAnzahl: ursachen.count,
            sekunden: Int(verstrichen.rounded())
        )
        abschnittStart = jetzt
        fehlschlaege = 0
        assets.removeAll()
        ursachen.removeAll()
        seitLetzterSammelmeldung = 0
        return .sammel(meldung)
    }

    /// Bei Gleichstand der Häufigkeit entscheidet der Name — sonst wechselte die
    /// gemeldete Ursache je nach Wörterbuch-Reihenfolge und wäre nicht prüfbar.
    private func haeufigsteUrsache() -> String? {
        ursachen.max { links, rechts in
            links.value != rechts.value ? links.value < rechts.value : links.key > rechts.key
        }?.key
    }
}

extension ConnectionState {
    /// Kurzform fürs Protokoll — **die Sicht der App auf sich selbst**.
    ///
    /// Steht bewusst in jeder Fehlerzeile der Kacheln: Die Kachel selbst wertet
    /// den Verbindungszustand nirgends aus (sie fragt nur, ob es einen
    /// `apiClient` gibt — den gibt es im Offlinebetrieb auch), also sähen ein
    /// Gerät ohne Netz und ein Server, der 404 liefert, im Protokoll bisher
    /// **gleich** aus. Genau diese Frage war beim Befund vom 06.09.2026 offen
    /// und nur über die Aussage des Nutzers zu klären.
    var protokollKurzform: String {
        switch self {
        case .disconnected: return "nicht verbunden"
        case .connecting: return "verbindet"
        case .connected: return "verbunden"
        case .offline: return "offline"
        case .error: return "Verbindungsfehler"
        }
    }
}

/// Die eine gemeinsame Ablage der Drossel. Ein Singleton, weil die Kacheln
/// `struct`s sind, die pro Scrollposition neu entstehen: Ein Zustand *in* der
/// Kachel würde mit ihr verworfen und könnte nichts zusammenzählen.
@MainActor
enum ThumbnailFehlerJournal {

    private static var drossel = ThumbnailFehlerDrossel()

    static func melde(
        assetId: String,
        fehler: any Error,
        zustand: ConnectionState,
        jetzt: Date = Date()
    ) {
        let ursache = ThumbnailFehlerUrsache.schluessel(fehler)
        switch drossel.melde(assetId: assetId, ursache: ursache, jetzt: jetzt) {
        case .erste:
            let einzelheiten = ThumbnailFehlerUrsache.einzelheiten(fehler)
            AppLogger.library.error(
                """
                Thumbnail fehlt \(assetId, privacy: .public) [App: \(zustand.protokollKurzform, privacy: .public)]: \
                \(ursache, privacy: .public) — \(einzelheiten, privacy: .public)
                """
            )
        case .sammel(let meldung):
            AppLogger.library.error(
                """
                Thumbnails fehlen [App: \(zustand.protokollKurzform, privacy: .public)]: \
                \(meldung.fehlschlaege, privacy: .public) Fehlschläge \
                an \(meldung.assets, privacy: .public) Assets in \(meldung.sekunden, privacy: .public) s, \
                häufigste von \(meldung.ursachenAnzahl, privacy: .public) Ursachen: \
                \(meldung.haeufigsteUrsache, privacy: .public)
                """
            )
        case .unterdrueckt:
            AppLogger.library.debug(
                "Thumbnail fehlt \(assetId, privacy: .public): \(ursache, privacy: .public)"
            )
        }
    }
}
