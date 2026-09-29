import Foundation
import Testing
@testable import ImmichPhone

/// Nagelt Abbruchbedingung und Suchkörper des Fotos-Reiters fest.
///
/// Seit Server v3.2.0 blättert der Reiter über die strukturierte Suche und deren
/// opaken `nextCursor`; `nextPage` bleibt dort `null`. Ende ist `nil` **oder**
/// leer, wie bei jeder Blätter-Schleife dieser App.
@Suite("PhonePhotoFeed")
@MainActor
struct PhonePhotoFeedTests {

    @Test("Fehlender Cursor beendet das Blättern")
    func fehlenderCursorIstEnde() {
        #expect(PhonePhotoFeed.istEnde(nil))
    }

    @Test("Leerer Cursor beendet das Blättern ebenfalls")
    func leererCursorIstEnde() {
        #expect(PhonePhotoFeed.istEnde(""))
    }

    @Test("Ein gesetzter Cursor bedeutet: es kommt noch etwas")
    func gesetzterCursorIstKeinEnde() {
        #expect(!PhonePhotoFeed.istEnde("eyJvZmZzZXQiOjIwMH0"))
    }

    /// Ein vergessenes `trashedAt` holte in der neuen Form den Papierkorb in den
    /// Reiter (auf diesem Server gut 40 000 Assets), eine fehlende Sichtbarkeit die
    /// Bewegtbild-Anteile.
    @Test("Suchkörper: sichtbare Mediathek, absteigend, Seitengröße 200")
    func anfrageFuerAlle() {
        let anfrage = PhonePhotoFeed.anfrage(cursor: nil, filter: .alle)
        #expect(anfrage.filter == .visibleLibrary(type: nil))
        #expect(anfrage.orderBy == SearchOrder(field: .fileCreatedAt, direction: .desc))
        #expect(anfrage.size == PhonePhotoFeed.seitengroesse)
        #expect(anfrage.cursor == nil)
    }

    @Test("Der Umschalter landet als Typ im Filter, der Cursor wird durchgereicht")
    func anfrageFuerVideos() {
        let anfrage = PhonePhotoFeed.anfrage(cursor: "abc", filter: .videos)
        #expect(anfrage.filter == .visibleLibrary(type: .video))
        #expect(anfrage.cursor == "abc")
    }
}

/// Die Wache des Reiters beim Kontowechsel.
///
/// `ladeFallsNoetig` entschied bisher inline: neu laden, wenn die Server-URL eine
/// andere ist **oder** noch nichts geladen wurde. Bei einem Kontowechsel auf
/// *demselben* Server ist die URL dieselbe und die Liste voll — der Reiter zeigte
/// dem neuen Konto also die Fotos des alten. Die URL kann das nicht auffangen,
/// weil sie sich nicht ändert; auffangen muss es das Leeren beim Abmelden.
///
/// Als eigene Funktion prüfbar, aus demselben Grund wie ``PhonePhotoFeed/istEnde(_:)``
/// darüber: Die Entscheidung fällt im Betrieb lautlos falsch aus.
@Suite("Wache des Fotos-Reiters")
@MainActor
struct PhonePhotoFeedWacheTests {

    private let basis = URL(string: "https://immich.example/")!

    @Test("Gleicher Server mit vorhandenen Fotos lädt nicht neu")
    func gleicherServerLaedtNicht() {
        #expect(!PhonePhotoFeed.brauchtNeuladen(geladeneBasis: basis, neueBasis: basis, hatEintraege: true))
    }

    @Test("Ein anderer Server lädt neu")
    func andererServerLaedtNeu() {
        let anderer = URL(string: "https://zweit.example/")!
        #expect(PhonePhotoFeed.brauchtNeuladen(geladeneBasis: basis, neueBasis: anderer, hatEintraege: true))
    }

    // Der Fall, auf den das Leeren beim Abmelden zielt: Nach `leere()` ist die
    // Basis wieder `nil` und die Liste leer — beides für sich genügt schon, damit
    // derselbe Server neu geladen wird.
    @Test("Nach dem Leeren lädt auch derselbe Server neu")
    func nachLeerenLaedtNeu() {
        #expect(PhonePhotoFeed.brauchtNeuladen(geladeneBasis: nil, neueBasis: basis, hatEintraege: false))
        #expect(PhonePhotoFeed.brauchtNeuladen(geladeneBasis: basis, neueBasis: basis, hatEintraege: false))
    }

    @Test("leere() setzt beide Hälften der Wache zurück")
    func leerenSetztBeideZurueck() {
        let feed = PhonePhotoFeed()
        feed.leere()
        #expect(feed.geladeneBasis == nil)
        #expect(feed.eintraege.isEmpty)
        #expect(feed.abschnitte.isEmpty)
        #expect(feed.hatJeGeladen == false)
    }
}

/// Das Zurücksetzen beim Filterwechsel.
///
/// `setzeFilter` selbst lässt sich hier nicht laufen lassen — es geht ans Netz.
/// Prüfbar ist der Teil, auf den es ankommt und der ohne Netz auskommt:
/// ``PhonePhotoFeed/verwirfBestand(basis:)``, das `setzeFilter` über
/// ``PhonePhotoFeed/ladeVonVorne(apiClient:)`` aufruft. Bliebe dort ein Feld
/// stehen, fiele es im Betrieb erst spät auf: ein stehengebliebenes `gesehen`
/// ließe den Reiter „Videos" leer, wenn dieselben Videos schon unter „Alle"
/// gesehen wurden, ein stehengebliebener `naechsterCursor` fragte den neuen
/// Bestand mitten im Feld weiter.
@Suite("Filterwechsel des Fotos-Reiters")
@MainActor
struct PhonePhotoFeedFilterTests {

    private let basis = URL(string: "https://immich.example/")!

    @Test("Frisch steht der Reiter auf „Alle“")
    func startwertIstAlle() {
        #expect(PhonePhotoFeed().filter == .alle)
    }

    @Test("verwirfBestand räumt Liste, Fehler und Seitenzähler")
    func verwirfBestandRaeumtAlles() {
        let feed = PhonePhotoFeed()
        feed.verwirfBestand(basis: basis)
        #expect(feed.eintraege.isEmpty)
        #expect(feed.abschnitte.isEmpty)
        #expect(feed.fehler == nil)
        #expect(feed.laedt == false)
        // Wieder wahr, sonst holte der neue Bestand keine einzige Seite.
        #expect(feed.hatMehr)
        #expect(feed.geladeneBasis == basis)
    }

    // Der Filter überlebt das Verwerfen: `setzeFilter` setzt ihn **vor** dem
    // Neuladen, ein Zurücksetzen im Verwerfen machte den Wechsel wirkungslos.
    @Test("Das Verwerfen rührt den Filter nicht an")
    func verwerfenLaesstFilterStehen() {
        let feed = PhonePhotoFeed()
        feed.verwirfBestand(basis: basis)
        #expect(feed.filter == .alle)
    }

    /// Ein Client auf eine Adresse, die es nach RFC 2606 nie geben kann — die
    /// Namensauflösung scheitert sofort, kein Zeitlimit, kein Netz. Dasselbe
    /// Mittel wie in `Tests/ImmichMacTests/AlbumCacheOrderTests.swift:39`.
    private func unerreichbarerClient() -> ImmichAPIClient {
        let konfiguration = URLSessionConfiguration.ephemeral
        konfiguration.timeoutIntervalForRequest = 5
        konfiguration.timeoutIntervalForResource = 5
        return ImmichAPIClient(
            baseURL: URL(string: "https://immich.invalid")!,
            apiKey: "test",
            sessionConfiguration: konfiguration
        )
    }

    // Der Wechsel muss ankommen, auch wenn der Abruf danach scheitert: Sonst
    // stünde der Umschalter auf „Videos" und der Reiter holte weiter alles.
    @Test("setzeFilter übernimmt den neuen Filter und setzt den Bestand zurück")
    func setzeFilterUebernimmtUndSetztZurueck() async {
        let feed = PhonePhotoFeed()
        let client = unerreichbarerClient()
        await feed.setzeFilter(.videos, apiClient: client)
        #expect(feed.filter == .videos)
        #expect(feed.eintraege.isEmpty)
        #expect(feed.abschnitte.isEmpty)
        #expect(feed.geladeneBasis == client.baseURL)
        // Der gescheiterte Abruf ist hier nicht die Aussage, aber er belegt,
        // dass wirklich neu geladen und nicht bloß umgeschaltet wurde.
        #expect(feed.fehler != nil)
    }

    // Derselbe Filter zweimal ist kein Wechsel — ein Neuladen wäre nur ein
    // wegwerfbarer Netzweg, und beim Tippen auf das schon gewählte Feld eines
    // Segmentumschalters passiert das leicht.
    @Test("Derselbe Filter löst kein Neuladen aus")
    func gleicherFilterLaedtNicht() async {
        let feed = PhonePhotoFeed()
        await feed.setzeFilter(.alle, apiClient: unerreichbarerClient())
        #expect(feed.filter == .alle)
        // Nichts angefasst: kein Abruf, also auch kein Fehler und keine Basis.
        #expect(feed.fehler == nil)
        #expect(feed.geladeneBasis == nil)
    }

    // Abmelden ist etwas anderes als ein Filterwechsel: Danach soll das nächste
    // Konto seine Mediathek ganz sehen.
    @Test("leere() stellt „Alle“ wieder her")
    func leerenSetztFilterZurueck() async {
        let feed = PhonePhotoFeed()
        await feed.setzeFilter(.videos, apiClient: unerreichbarerClient())
        #expect(feed.filter == .videos)

        feed.leere()
        #expect(feed.filter == .alle)
        #expect(feed.hatJeGeladen == false)
        #expect(feed.geladeneBasis == nil)
        #expect(feed.fehler == nil)
    }
}

/// Die Verallgemeinerung für den Orte-Reiter. Der wichtigste Test hier ist der
/// erste: Ohne Auswahl muss der Suchkörper **exakt** der von vorher sein — sonst
/// hätte die Umstellung den Fotos-Reiter still verändert.
@Suite("Ortsauswahl im Feed")
@MainActor
struct PhonePhotoFeedAuswahlTests {

    private func unerreichbarerClient() -> ImmichAPIClient {
        let konfiguration = URLSessionConfiguration.ephemeral
        konfiguration.timeoutIntervalForRequest = 5
        konfiguration.timeoutIntervalForResource = 5
        return ImmichAPIClient(
            baseURL: URL(string: "https://immich.invalid")!,
            apiKey: "test",
            sessionConfiguration: konfiguration
        )
    }

    @Test("Ohne Auswahl baut der Feed exakt den Suchkörper des Fotos-Reiters")
    func leereAuswahlIstFotosReiter() {
        for filter in PhoneFeedFilter.allCases {
            let mitAuswahl = PhonePhotoFeed.anfrage(cursor: "c", filter: filter, auswahl: .leer)
            #expect(mitAuswahl == PhonePhotoFeed.anfrage(cursor: "c", filter: filter))
            #expect(mitAuswahl.filter == .visibleLibrary(type: filter.assetType))
        }
    }

    @Test("Die Auswahl landet im Suchkörper, Typ und Sortierung bleiben")
    func auswahlImSuchkoerper() {
        let anfrage = PhonePhotoFeed.anfrage(
            cursor: nil, filter: .videos, auswahl: .stadt("Tokyo", in: "Japan")
        )
        #expect(anfrage.filter.country == .equals("Japan"))
        #expect(anfrage.filter.city == .equals("Tokyo"))
        #expect(anfrage.filter.type == .equals(.video))
        #expect(anfrage.orderBy == SearchOrder(field: .fileCreatedAt, direction: .desc))
    }

    @Test("Frisch ist keine Auswahl gesetzt")
    func startwert() {
        #expect(PhonePhotoFeed().auswahl == .leer)
    }

    @Test("setzeAuswahl übernimmt und lädt von vorne")
    func setzeAuswahlLaedt() async {
        let feed = PhonePhotoFeed()
        let client = unerreichbarerClient()
        await feed.setzeAuswahl(.land("Japan"), apiClient: client)
        #expect(feed.auswahl == .land("Japan"))
        #expect(feed.geladeneBasis == client.baseURL)
        // Der gescheiterte Abruf belegt, dass wirklich neu geladen wurde.
        #expect(feed.fehler != nil)
    }

    @Test("Dieselbe Auswahl lädt nicht neu")
    func gleicheAuswahlLaedtNicht() async {
        let feed = PhonePhotoFeed()
        await feed.setzeAuswahl(.leer, apiClient: unerreichbarerClient())
        #expect(feed.fehler == nil)
        #expect(feed.geladeneBasis == nil)
    }

    @Test("leere() setzt die Auswahl zurück")
    func leereSetztAuswahlZurueck() async {
        let feed = PhonePhotoFeed()
        await feed.setzeAuswahl(.land("Japan"), apiClient: unerreichbarerClient())
        feed.leere()
        #expect(feed.auswahl == .leer)
    }
}

@Suite("PhonePhotoFeed: Bildsuche", .serialized)
@MainActor
struct PhonePhotoFeedBildsucheTests {
    private static let host = "feed-bildsuche.test"

    @Test("Freitext fragt /search/smart mit Filter und Typ, ohne Blättern")
    func bildsuche() async throws {
        let mitschnitt = OrteMitschnitt()
        OrteMockURLProtocol.registriere(host: Self.host) { r, k in
            mitschnitt.merke(r, k)
            return (200, OrteMockURLProtocol.seiteJSON([OrteMockURLProtocol.assetJSON(id: "s1", localDateTime: "2026-07-01T10:00:00.000Z")]))
        }
        defer { OrteMockURLProtocol.entferne(host: Self.host) }
        let feed = PhonePhotoFeed()
        let client = OrteMockURLProtocol.client(host: Self.host)
        await feed.setzeFilter(.videos, apiClient: client)
        await feed.setzeAuswahl(PhoneSuchAuswahl.person("p1").mitFreitext("Strand"), apiClient: client)

        let smart = try #require(mitschnitt.alle.last)
        #expect(smart.request.url?.path == "/api/search/smart")
        let koerper = OrteMockURLProtocol.json(smart.koerper)
        #expect(koerper["query"] as? String == "Strand")
        #expect(koerper["size"] as? Int == PhonePhotoFeed.bildsucheGrenze)
        let filter = try #require(koerper["filter"] as? [String: Any])
        #expect((filter["type"] as? [String: Any])?["eq"] as? String == "VIDEO")
        #expect(filter["personIds"] != nil)
        #expect(!feed.hatMehr)
        #expect(feed.eintraege.map(\.id) == ["s1"])
        #expect(!feed.bildsucheAmLimit)
    }
}

@Suite("PhonePhotoFeed: Bildsuche in Relevanz-Reihenfolge", .serialized)
@MainActor
struct PhonePhotoFeedRelevanzTests {
    private static let host = "feed-relevanz.test"

    @Test("Treffer der Bildsuche bleiben in der Reihenfolge des Servers, in einem Abschnitt")
    func reihenfolge() async {
        OrteMockURLProtocol.registriere(host: Self.host) { _, _ in
            (200, OrteMockURLProtocol.seiteJSON([
                OrteMockURLProtocol.assetJSON(id: "alt", localDateTime: "2019-01-01T10:00:00.000Z"),
                OrteMockURLProtocol.assetJSON(id: "neu", localDateTime: "2026-01-01T10:00:00.000Z"),
            ]))
        }
        defer { OrteMockURLProtocol.entferne(host: Self.host) }
        let feed = PhonePhotoFeed()
        await feed.setzeAuswahl(PhoneSuchAuswahl.leer.mitFreitext("Strand"), apiClient: OrteMockURLProtocol.client(host: Self.host))
        #expect(feed.abschnitte.count == 1)
        #expect(feed.eintraege.map(\.id) == ["alt", "neu"])
    }
}
