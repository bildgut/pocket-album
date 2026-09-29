import Foundation
import Observation
import os

/// Eine Kachel im Fotos-Reiter: der Eintrag selbst plus seine Position in der
/// **flachen** Liste über alle Tagesabschnitte hinweg.
///
/// Der flache Index ist kein Beiwerk: `PhoneAssetView` nimmt `[PhoneAlbumGridEintrag]`
/// und einen Startindex (`Sources/ImmichPhone/Views/PhoneAssetView.swift:24-25`).
/// Das Raster zeigt die Einträge aber nach Tagen gruppiert — ohne diesen
/// mitgeführten Index müsste die Ansicht ihn bei jedem Tippen aus
/// Abschnittslängen zusammenrechnen, und ein Abschnitt, der sich beim Nachladen
/// verlängert (der jüngste Tag einer Seite reicht regelmäßig in die nächste
/// hinein), ließe die Rechnung schief laufen.
///
/// **Die Kennung ist aber das Foto, nicht die Position.** Früher war `id` der
/// `flachIndex`. Nach einem Neuladen mit anderem Filter (Orte-Reiter: Japan → Osaka)
/// trugen andere Fotos wieder die Kennungen 0, 1, 2 …, und das `LazyVGrid` behielt die
/// vorhandenen Zellen: Überschrift und Trefferzahl wechselten, die Kacheln zeigten
/// weiter die alten Fotos samt Videolänge (Gerätebefund 13.09.2026). Die Asset-ID ist
/// im Feed eindeutig — ``PhonePhotoFeed`` entdoppelt über `gesehen`.
struct PhoneFeedKachel: Identifiable, Hashable {
    let flachIndex: Int
    let eintrag: PhoneAlbumGridEintrag
    var id: String { eintrag.id }
}

/// Ein Tagesabschnitt, wie das Raster ihn zeichnet — `PhotoFeedDay` (reiner
/// Wertetyp, Task 1) plus die fertigen Kacheln mit ihren flachen Indizes.
struct PhoneFeedAbschnitt: Identifiable {
    /// "2026-09-05", direkt aus `PhotoFeedDay.id`.
    let id: String
    /// "Samstag, 5. September 2026"
    let titel: String
    /// `var`, seit das Einzelbild den Stern umschalten kann: Eine einzelne
    /// Kachel tauscht dann ihren Eintrag aus, ohne dass die ganze Mediathek
    /// neu gruppiert werden müsste (siehe ``PhonePhotoFeed/setzeFavorit(assetId:ist:)``).
    var kacheln: [PhoneFeedKachel]
}

/// Der Zustand hinter dem Reiter „Fotos": seitenweiser Abruf der sichtbaren
/// Mediathek über die strukturierte Suche (`ImmichAPIClient.searchAssets(query:)`,
/// ab Server v3.2.0) mit dem Filter aus ``anfrage(cursor:filter:)`` — der Server
/// lässt Archiv, Papierkorb und Bewegtbild-Anteile schon weg, der Umschalter
/// ``PhoneFeedFilter`` schränkt den Typ ein —, nach Tagen gruppiert von
/// `PhotoFeedGrouping` (Task 1).
///
/// Lebt als `@State` in `PhoneRootView`, damit ein Reiterwechsel weder die
/// geladenen Seiten noch die Scrollposition verliert.
///
/// ## Abbruchbedingung: `nextCursor`, nicht `total`/`count`
///
/// `total` und `count` sind in `AssetPage` optional und taugen ohnehin nicht:
/// `total` ist in der strukturierten Suche nur noch die Größe der Seite (seit
/// v3.0.0 veraltet), `count` ebenso. Die strukturierte Form blättert über den
/// opaken `nextCursor` — `nextPage` bleibt dort stets `null`. Ende ist, wie bei
/// allen Blätter-Schleifen dieser App, **`nil` ODER leer** (``istEnde(_:)``).
///
/// Der Cursor ist ein verpackter Offset. Wer ihn mit einem anderen Filter
/// weiterverwendet, bekommt keinen Fehler, sondern einen beliebigen Ausschnitt —
/// deshalb setzt jeder Filterwechsel ihn zurück (``verwirfBestand(basis:)``).
///
/// Zusätzlich bricht eine leere Seite ab. Ein Server, der eine leere Seite mit
/// gesetztem Cursor liefert, ließe die Schleife unten sonst endlos weiterlaufen.
@Observable @MainActor
final class PhonePhotoFeed {

    /// Alle bisher geladenen, sichtbaren Einträge in Serverreihenfolge
    /// (absteigend). Genau die Liste, die `PhoneAssetView` als `eintraege`
    /// bekommt — der `flachIndex` einer Kachel indiziert hier hinein.
    /// Beobachtet ``PhoneFavoritMeldung`` — Sternänderungen aus **jedem**
    /// Einzelbild, nicht nur aus dem eigenen Raster. Vorher erreichte der
    /// Rückruf des Einzelbilds nur den Feed, aus dem es geöffnet war: Ein Stern
    /// in den Favoriten fehlte im Fotos-Reiter und umgekehrt.
    @ObservationIgnored nonisolated(unsafe) private var favoritBeobachter: NSObjectProtocol?

    init() {
        favoritBeobachter = NotificationCenter.default.addObserver(
            forName: PhoneFavoritMeldung.name, object: nil, queue: .main
        ) { [weak self] meldung in
            guard let (id, ist) = PhoneFavoritMeldung.lies(meldung) else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.wendeFavoritAn(assetId: id, ist: ist) }
            }
        }
    }

    deinit {
        if let favoritBeobachter { NotificationCenter.default.removeObserver(favoritBeobachter) }
    }

    /// Nur für Tests: läuft in ``neuGruppieren(meinLauf:)`` nach der Rechnung und
    /// **vor** der Übernahme — so lässt sich das Rennen zweier Gruppierungen
    /// ohne Zeitglück nachstellen.
    @ObservationIgnored var vorUebernahmeHaken: (@MainActor () async -> Void)?

    /// Zählt jede Gruppierung. `generation` allein genügt nicht: `entferne` und
    /// `ladeWeitere` gruppieren **innerhalb** derselben Generation, und kam die
    /// ältere Rechnung (noch mit dem gelöschten Foto) zuletzt an, stand das Foto
    /// wieder da. Übernommen wird nur das Ergebnis der jüngsten Gruppierung — sie
    /// rechnet über den neuesten Stand von `assets`, enthält also alles Spätere.
    @ObservationIgnored private var gruppierNummer: UInt64 = 0

    private(set) var eintraege: [PhoneAlbumGridEintrag] = []

    /// Dasselbe, nach Tagen gruppiert — was das Raster zeichnet.
    private(set) var abschnitte: [PhoneFeedAbschnitt] = []

    /// Läuft gerade ein Abruf? Trägt sowohl die Sperre gegen Mehrfachläufe als
    /// auch den Spinner am Rasterfuß.
    private(set) var laedt = false

    /// Zählt jedes `ladeVonVorne` hoch. Ein Abruf, der nach seinem `await` eine
    /// andere Zahl vorfindet als beim Start, gehört zu einem überholten Lauf
    /// (Serverwechsel oder Aktualisieren-Zug) und verwirft sein Ergebnis.
    private var generation: UInt64 = 0

    /// Der Server hat laut `nextCursor` noch mehr. Startwert `true`, damit der
    /// erste Abruf überhaupt losgeht.
    private(set) var hatMehr = true

    /// Letzter Netzfehler, unverschluckt. Die Ansicht zeigt ihn als
    /// Vollflächen-Zustand (noch nichts geladen) oder als Fußzeile mit
    /// „Erneut versuchen" (schon etwas geladen) — siehe `PhonePhotoFeedView`.
    private(set) var fehler: String?

    /// Wahr, sobald der erste Abruf **zurückgekehrt** ist (mit Ergebnis oder
    /// Fehler). Unterscheidet „lädt noch" von „der Server kennt keine Fotos" —
    /// dieselbe Rolle wie `hasLoadedOnce` in `PhoneRootView` für die Alben.
    private(set) var hatJeGeladen = false

    /// Die zuletzt geladenen Rohassets. Nötig, weil `PhotoFeedGrouping.build`
    /// eine reine Funktion über die **gesamte** Liste ist: Der jüngste Tag einer
    /// Seite reicht fast immer in die nächste hinein, ein abschnittsweises
    /// Anhängen ergäbe denselben Tag also zweimal.
    private var assets: [Asset] = []

    /// Gegen doppelte Assets, wenn sich die Mediathek zwischen zwei Seiten
    /// ändert: Ein neu hochgeladenes Foto schiebt bei absteigender Sortierung
    /// alles um eine Position nach hinten, das Grenzasset der vorigen Seite
    /// käme dann ein zweites Mal. `AssetRepository` lebt damit; hier ist es
    /// billig zu vermeiden und erspart doppelte Kacheln.
    private var gesehen = Set<String>()

    /// Für welchen Server die Liste oben gilt. Ein Wechsel der Basis-URL
    /// (anderer Server, erneutes Einrichten) verwirft alles — dieselbe
    /// Überlegung wie beim frischen `AlbumManager` in
    /// `PhoneRootView.setUpAlbumManagerIfNeeded()`.
    private(set) var geladeneBasis: URL?

    /// Sternzustände, die das Einzelbild geändert hat, seit die Seite geladen
    /// wurde.
    ///
    /// Nötig, weil `Asset` ein Wertetyp mit `let isFavorite` ist: Die
    /// Rohliste `assets` lässt sich nicht nachträglich umschreiben, ohne jedes
    /// Asset neu zu bauen. Statt das zu tun, merkt sich diese Abbildung die
    /// Abweichung und ``neuGruppieren(meinLauf:)`` legt sie über die frisch
    /// gebauten Einträge — sonst fiele ein gesetzter Stern beim nächsten
    /// Nachladen wieder heraus.
    private var favoritenAenderungen: [String: Bool] = [:]

    /// Fortsetzung der laufenden Suche; `nil` heißt „von vorne".
    private var naechsterCursor: String?

    /// Wie viele Seiten dieser Bestand schon geholt hat — nur fürs Protokoll, der
    /// Cursor selbst ist opak.
    private var geholteSeiten = 0

    /// Alle / Fotos / Videos. Siehe ``setzeFilter(_:apiClient:)`` dazu, warum
    /// die Wahl hier liegt und nicht in `UserDefaults`.
    private(set) var filter: PhoneFeedFilter = .alle

    /// Welcher Ort, welches Jahr, welche Personen. Im Fotos-Reiter immer
    /// ``PhoneSuchAuswahl/leer`` — dann baut ``anfrage(cursor:filter:auswahl:)``
    /// genau den Suchkörper von vorher. Der Orte-Reiter hält einen eigenen Feed
    /// und setzt sie über ``setzeAuswahl(_:apiClient:)``.
    private(set) var auswahl: PhoneSuchAuswahl = .leer

    /// Seitengröße. 200 wie der Vorgabewert von `searchAssets(page:size:)` und
    /// wie `AssetRepository` (`:215`, `:230`) — die 1000 der `SyncEngine` sind
    /// für einen Hintergrundlauf gedacht, nicht für ein Raster, das die erste
    /// Seite so schnell wie möglich zeigen soll.
    static let seitengroesse = 200

    /// Höchstzahl der Bildsuche (`smartSearch`): Der Server blättert dort nicht.
    static let bildsucheGrenze = 1000

    /// Die Bildsuche hat die Grenze erreicht — die Ansicht sagt dann, dass es nur
    /// die besten Treffer sind.
    private(set) var bildsucheAmLimit = false

    /// Wie viele Seiten ein einzelner `ladeWeitere`-Aufruf höchstens am Stück
    /// holt. Siehe die Begründung an der Schleife.
    static let maxSeitenJeLauf = 20

    /// Wie viele Kacheln vor dem Ende das Nachladen anstößt. Etwas weniger als
    /// eine halbe Seite: früh genug, dass die nächste Seite meist da ist, bevor
    /// der Nutzer unten ankommt, und spät genug, dass ein kurzes Antippen des
    /// Reiters nicht sofort zwei Seiten zieht.
    static let nachladeSchwelle = 60

    // MARK: - Laden

    /// Aufruf aus `.task(id:)` der Ansicht. Lädt nur, wenn für diesen Server
    /// noch nichts vorliegt — ein Reiterwechsel soll nicht jedes Mal neu laden.
    /// Ein gescheiterter Erstabruf (nichts geladen) wird dagegen beim nächsten
    /// Erscheinen erneut versucht; das ist der billigste Wiederholungsweg, den
    /// der Nutzer ohnehin von sich aus geht.
    func ladeFallsNoetig(apiClient: ImmichAPIClient) async {
        guard Self.brauchtNeuladen(
            geladeneBasis: geladeneBasis,
            neueBasis: apiClient.baseURL,
            hatEintraege: !eintraege.isEmpty
        ) else { return }
        await ladeVonVorne(apiClient: apiClient)
    }

    /// Die Wache von ``ladeFallsNoetig(apiClient:)``, als eigene Funktion prüfbar.
    ///
    /// Die Server-URL allein trägt diese Entscheidung **nicht**: Bei einem
    /// Kontowechsel auf demselben Server ist sie unverändert, und der Reiter
    /// zeigte dem neuen Konto die Fotos des alten. Das kann diese Funktion nicht
    /// heilen — der API-Schlüssel steht ihr nicht zur Verfügung, und ihn hier
    /// hereinzureichen hieße, ihn durch die halbe Ansicht zu fädeln. Es heilt
    /// ``leere()``, das ``AccountDataPurge`` beim Abmelden aufruft.
    static func brauchtNeuladen(geladeneBasis: URL?, neueBasis: URL, hatEintraege: Bool) -> Bool {
        geladeneBasis != neueBasis || !hatEintraege
    }

    /// Verwirft alles und stellt den Zustand vor dem ersten Laden her.
    ///
    /// Ruft ``AccountDataPurge`` beim Abmelden auf. Nötig, weil der Reiter als
    /// `@State` an `PhoneRootView` hängt und den Wechsel zurück auf die
    /// Einrichtung überlebt — ohne dies stünde nach dem Neuanmelden auf
    /// demselben Server die volle Liste des Vorkontos in `eintraege`, und die
    /// Wache oben ließe sie stehen.
    ///
    /// Zählt wie ``ladeVonVorne(apiClient:)`` die `generation` hoch, damit ein
    /// noch laufender Abruf sein Ergebnis nach dem `await` wegwirft, statt die
    /// gerade geleerte Liste wieder zu füllen.
    func leere() {
        verwirfBestand(basis: nil)
        hatJeGeladen = false
        // Der Filter gehört nicht zum Bestand, sondern zur Ansicht — deshalb
        // steht er hier und nicht in ``verwirfBestand(basis:)``, das der
        // Filterwechsel selbst aufruft und das ihn dort gerade zurücksetzen
        // würde. Beim Abmelden fällt er trotzdem auf „Alle" zurück: Diese
        // Funktion stellt den Zustand vor dem ersten Laden her, und ein neu
        // angemeldetes Konto soll seine Mediathek ganz sehen, nicht durch die
        // Brille des Vorkontos.
        filter = .alle
        auswahl = .leer
    }

    /// Der Zurücksetz-Teil, den sich ``leere()``, ``ladeVonVorne(apiClient:)``
    /// und ``setzeFilter(_:apiClient:)`` teilen.
    ///
    /// Als eine Funktion statt dreimal aufgeschrieben, weil hier jedes Feld
    /// vorkommen muss: Ein vergessenes `gesehen` ließe die neue Liste an der
    /// Entdopplung der alten hängen (der Reiter „Videos" bliebe leer, wenn die
    /// Videos schon unter „Alle" gesehen wurden), ein vergessenes
    /// `naechsterCursor` fragte mitten im Feld weiter.
    ///
    /// Bewusst **keine** `laedt`-Sperre: Ein Neuladen, das wirkungslos
    /// zurückkehrt, während noch ein Nachladen läuft, wäre bei einem
    /// Serverwechsel ein Fehler — der Reiter zeigte weiter die Fotos des alten
    /// Servers, bis ihn jemand neu betritt. Stattdessen zählt `generation`
    /// hoch; der noch laufende Abruf erkennt daran nach seinem `await`, dass er
    /// veraltet ist, und wirft sein Ergebnis weg.
    func verwirfBestand(basis: URL?) {
        generation &+= 1
        // Die Sperre des überholten Laufs gilt nicht mehr — sonst kehrte ein
        // anschließendes `ladeWeitere` sofort an seiner eigenen `laedt`-Wache
        // zurück und der Reiter bliebe leer zurück.
        laedt = false
        assets = []
        gesehen = []
        eintraege = []
        abschnitte = []
        // Die Abweichungen gehören zu den weggeworfenen Assets: Was der Server
        // jetzt liefert, trägt den aktuellen Stern selbst. Sie stehen zu
        // lassen, hieße einen inzwischen anderswo entfernten Stern hier
        // dauerhaft weiterzuzeigen.
        favoritenAenderungen = [:]
        naechsterCursor = nil
        geholteSeiten = 0
        hatMehr = true
        fehler = nil
        geladeneBasis = basis
        bildsucheAmLimit = false
    }

    /// Verwirft alles und holt Seite 1 — der Aktualisieren-Zug und der
    /// Serverwechsel.
    func ladeVonVorne(apiClient: ImmichAPIClient) async {
        verwirfBestand(basis: apiClient.baseURL)
        await ladeWeitere(apiClient: apiClient)
    }

    /// Schaltet zwischen Alle / Fotos / Videos um und lädt den neuen Bestand
    /// von Seite 1.
    ///
    /// **Warum das Zurücksetzen unvermeidlich ist:** `naechsterCursor` gehört zu
    /// *einer* Suchanfrage — er verpackt einen Offset, und Offset 1000 der
    /// Videosuche hat mit Offset 1000 der Gesamtsuche nichts zu tun; einfach
    /// weiterzublättern ergäbe einen beliebigen Ausschnitt. Also derselbe Weg wie beim Aktualisieren-Zug —
    /// ``ladeVonVorne(apiClient:)``, mitsamt dem Generationszähler, der einen
    /// noch laufenden Abruf des alten Filters sein Ergebnis wegwerfen lässt.
    /// Ohne den träfe die Antwort auf die letzte „Alle"-Seite auf den
    /// inzwischen leeren Videobestand und mischte Standbilder hinein.
    ///
    /// **Warum die Wahl nirgends auf der Platte landet:** Sie hängt am
    /// ``PhonePhotoFeed``, den `PhoneRootView` als `@State` hält — ein
    /// Reiterwechsel und selbst ein Serverwechsel lassen sie also stehen, ein
    /// Neustart nicht. Das ist Absicht: Ein gespeicherter Videofilter hieße,
    /// dass die App beim nächsten Start im Reiter „Fotos" keine Fotos zeigt,
    /// ohne dass der Nutzer sich an die Ursache erinnert — der teuerste
    /// Leerzustand von allen ist der, den man sich selbst gestellt hat und
    /// nicht wiedererkennt. `AppEnvironment.defaults` bliebe dafür bereit
    /// (`ImmichPhoneApp` setzt sie als `.defaultAppStorage`); gebraucht wird
    /// sie hier nicht.
    func setzeFilter(_ neu: PhoneFeedFilter, apiClient: ImmichAPIClient) async {
        guard neu != filter else { return }
        filter = neu
        await ladeVonVorne(apiClient: apiClient)
    }

    /// Wie ``setzeFilter(_:apiClient:)``, nur für die Ortsauswahl — und aus
    /// demselben Grund immer von vorne: Der Cursor gehört zu *einer* Suchanfrage,
    /// Offset 200 von „Japan" hat mit Offset 200 von „Tokyo" nichts zu tun.
    func setzeAuswahl(_ neu: PhoneSuchAuswahl, apiClient: ImmichAPIClient) async {
        guard neu != auswahl else { return }
        auswahl = neu
        await ladeVonVorne(apiClient: apiClient)
    }

    /// Nachladen beim Scrollen. Ein `.onAppear` je Kachel feuert leicht mehrfach
    /// (mehrere Kacheln einer Zeile erscheinen gleichzeitig, und beim Zurück-
    /// scrollen erneut) — deshalb die `laedt`-Sperre gleich in der ersten Zeile,
    /// nicht erst beim Anfordern.
    func ladeWeitere(apiClient: ImmichAPIClient) async {
        guard !laedt, hatMehr else { return }
        let meineGeneration = generation
        laedt = true
        let signpostID = OSSignpostID(log: AppLogger.dataPerf)
        os_signpost(.begin, log: AppLogger.dataPerf, name: "PhoneFeedLadeWeitere", signpostID: signpostID)
        defer { os_signpost(.end, log: AppLogger.dataPerf, name: "PhoneFeedLadeWeitere", signpostID: signpostID) }
        fehler = nil
        // Nur der *aktuelle* Lauf gibt die Sperre wieder frei. Täte das auch ein
        // überholter, hübe er sie mitten im Nachfolgelauf auf, und ein dritter
        // Abruf könnte parallel anlaufen.
        defer {
            if meineGeneration == generation {
                laedt = false
                hatJeGeladen = true
            }
        }

        // Schleife statt eines einzelnen Abrufs: Eine Seite kann ausschließlich
        // archivierte oder gelöschte Assets enthalten und nach dem Filtern in
        // `PhotoFeedGrouping.build` **keine** neue Kachel ergeben. Dann erscheint
        // auch keine neue Kachel, deren `.onAppear` den nächsten Abruf anstoßen
        // könnte — der Reiter bliebe stehen, obwohl der Server noch Fotos hat.
        // Die Schleife läuft deshalb weiter, bis mindestens eine sichtbare
        // Kachel dazugekommen oder das Ende erreicht ist. Sie terminiert
        // zwangsläufig: `seitenDiesenLauf` wächst bei jedem Durchgang, und jede
        // Abbruchbedingung unten setzt `hatMehr = false`.
        //
        // Der Deckel `maxSeitenJeLauf` begrenzt, wie viele Seiten ein einzelner
        // Aufruf am Stück holt. Er schließt zwei Fälle: einen zusammenhängenden
        // Block archivierter Assets über viele Seiten (der Nutzer sähe sonst nur
        // einen Spinner ohne Fortschritt und ohne Abbruch), und einen Server,
        // der dieselbe Seite mit gesetztem Cursor wiederholt — dessen
        // Elemente stünden alle schon in `gesehen`, die Schleife liefe über den
        // `continue` unten also ohne Zuwachs und ohne Abbruch weiter. Wird der
        // Deckel erreicht, bleibt `hatMehr` wahr: Das nächste `.onAppear` macht
        // einfach weiter.
        let vorher = eintraege.count
        var seitenDiesenLauf = 0
        while hatMehr && eintraege.count == vorher && seitenDiesenLauf < Self.maxSeitenJeLauf {
            // Vor dem `do`, damit der `catch`-Zweig sie noch sieht: Nach einem
            // dazwischengekommenen Neuladen wären Cursor und Zähler die des
            // *neuen* Laufs und damit die falschen Werte.
            let seitenNummer = geholteSeiten + 1
            let meinCursor = naechsterCursor
            let meinFilter = filter
            let meineAuswahl = auswahl
            do {
                let neue: [Asset]
                let cursor: String?
                if !meineAuswahl.freitext.isEmpty {
                    // Bildsuche (CLIP): ohne Blättern, höchstens `bildsucheGrenze` Treffer.
                    neue = try await apiClient.smartSearch(
                        query: meineAuswahl.freitext,
                        filter: meineAuswahl.searchFilter(type: meinFilter.assetType),
                        size: Self.bildsucheGrenze
                    )
                    cursor = nil
                } else {
                    let seite = try await apiClient.searchAssets(
                        query: Self.anfrage(cursor: meinCursor, filter: meinFilter, auswahl: meineAuswahl)
                    )
                    neue = seite.items ?? []
                    cursor = seite.nextCursor
                }
                guard meineGeneration == generation else { return }
                if !meineAuswahl.freitext.isEmpty { bildsucheAmLimit = neue.count >= Self.bildsucheGrenze }
                naechsterCursor = cursor
                geholteSeiten += 1
                seitenDiesenLauf += 1

                if neue.isEmpty || Self.istEnde(cursor) {
                    hatMehr = false
                }

                let ungesehene = neue.filter { gesehen.insert($0.id).inserted }
                // Ohne diese Zeile hinterlässt der ganze Reiter keine Spur im
                // Protokoll — beim Nachgehen eines Nachladeproblems stünde man
                // ohne alles da. Die drei Zahlen sind genau die, die man dann
                // braucht: wie viele der Server lieferte, wie viele davon neu
                // waren (Entdopplung an der Seitengrenze), und ob es weitergeht.
                AppLogger.library.info(
                    "Fotos-Reiter [\(meinFilter.protokollName, privacy: .public)]: Seite \(seitenNummer, privacy: .public) — \(neue.count, privacy: .public) geliefert, \(ungesehene.count, privacy: .public) neu, weiter: \(self.hatMehr, privacy: .public)"
                )
                guard !ungesehene.isEmpty else { continue }

                assets.append(contentsOf: ungesehene)
                await neuGruppieren(meinLauf: meineGeneration)
            } catch {
                // Nicht verschlucken: Die Ansicht zeigt `fehler` als
                // Vollflächen-Zustand (noch nichts geladen) oder als Fußzeile
                // mit „Erneut versuchen" — dieselbe Haltung wie
                // `PhoneUnreachableView` an der Wurzel und der `.fehler`-Zweig
                // in `PhoneAlbumDetailView`.
                // Dieselbe Wache wie im Erfolgsfall, und aus demselben Grund:
                // Ein überholter Lauf (Serverwechsel, Aktualisieren-Zug) darf
                // seinen Fehler nicht in den gemeinsamen Zustand schreiben. Der
                // aktuelle Lauf hat `fehler` gerade auf `nil` gesetzt; ohne die
                // Wache stünde „Erneut versuchen" für einen Lauf da, der gar
                // nicht gescheitert ist. Die Protokollzeile nennt bewusst
                // die beim Start erfasste `seitenNummer` — die Zähler sind
                // nach einem dazwischengekommenen Neuladen die des *neuen*
                // Laufs, also die falsche Zahl.
                guard meineGeneration == generation else {
                    AppLogger.library.info("Fotos-Reiter [\(meinFilter.protokollName, privacy: .public)]: Fehler eines überholten Laufs verworfen (Seite \(seitenNummer, privacy: .public))")
                    return
                }
                fehler = error.localizedDescription
                AppLogger.library.error("Fotos-Reiter [\(meinFilter.protokollName, privacy: .public)]: Seite \(seitenNummer, privacy: .public) fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
                // Kein Zurücksetzen des Cursors nötig: Die Zuweisung oben
                // steht **hinter** dem `try await`, wird bei einem Fehler also
                // gar nicht erreicht — die gescheiterte Seite bleibt die
                // nächste. `hatMehr` bleibt aus demselben Grund stehen: Ein
                // Netzfehler ist kein Ende der Mediathek, und „Erneut
                // versuchen" soll genau diese Seite noch einmal anfordern.
                return
            }
        }
    }

    /// Der Suchkörper einer Seite. Als reine Funktion, damit Filter, Sortierung und
    /// Seitengröße ohne Netz prüfbar sind (`PhonePhotoFeedTests`).
    ///
    /// - Der Filter ``SearchFilter/visibleLibrary(type:)`` lässt Archiv, Papierkorb
    ///   und die Bewegtbild-Anteile von Live Photos schon auf dem Server weg. Unter
    ///   „Videos" blieben auf diesem Server (11.09.2026) 4 506 von 11 182 Treffern
    ///   übrig; die alte flache Suche lieferte die übrigen mit, und die Schleife
    ///   oben musste sie seitenweise überblättern. ``PhotoFeedGrouping/build(assets:)`` filtert dieselben Fälle
    ///   weiterhin — als Absicherung, nicht mehr als einzige Stelle.
    /// - Kein `withExif`: `localDateTime` (der Tagesschlüssel), `type`, `duration`
    ///   und `isFavorite` stehen **oben** im `AssetResponseDto`.
    /// - Sortierung wie bisher absteigend nach `fileCreatedAt`.
    /// - Mit ``PhoneSuchAuswahl/leer`` ist das ``SearchFilter/visibleLibrary(type:)``;
    ///   der Orte-Reiter setzt Land, Stadt, Jahr und Personen dazu.
    static func anfrage(cursor: String?, filter: PhoneFeedFilter, auswahl: PhoneSuchAuswahl = .leer) -> AssetSearchQuery {
        AssetSearchQuery(
            filter: auswahl.searchFilter(type: filter.assetType),
            orderBy: SearchOrder(field: .fileCreatedAt, direction: .desc),
            cursor: cursor,
            size: seitengroesse
        )
    }

    /// `nil` **oder** leer — dieselbe Bedingung wie in `AssetRepository` und
    /// `SyncEngine` für `nextPage`. Als benannte Funktion, damit die beiden
    /// Aufrufstellen oben sie nicht auseinanderentwickeln können.
    static func istEnde(_ nextCursor: String?) -> Bool {
        nextCursor == nil || nextCursor?.isEmpty == true
    }

    /// Baut Abschnitte und flache Liste aus **allen** Rohassets neu. Über die
    /// gesamte Liste statt nur über die neue Seite, siehe Kommentar an `assets`.
    ///
    /// **Bekannte Grenze:** Das ist O(n) je Seite, über die Mediathek also
    /// O(n²) — und es läuft auf dem MainActor. Gemessen bleibt es bis etwa
    /// 10 000 Kacheln flüssig; diese Mediathek hat rund 165 000 Assets, also
    /// gut 800 Seiten, deren letzte über alles bisherige liefe. Tiefer im Feld
    /// ist mit Rucklern je Seitenwechsel zu rechnen. Der Ausweg wäre, nur den
    /// jeweils letzten Tagesabschnitt anzuhängen statt alles neu zu bauen.
    ///
    /// **Genau das geht seit der Umstellung auf die fotoeigene Ortszeit
    /// schlechter, nicht besser** — die frühere Fassung dieses Kommentars sagte
    /// das Gegenteil und wäre irreführend geworden. Mit der alten, festen Zone
    /// war der Tagesschlüssel eine monotone Funktion der UTC-Zeit: Weil der
    /// Server absteigend nach UTC liefert, konnte eine spätere Seite nur
    /// *unten* anbauen. Mit der Ortszeit gilt das nicht mehr — die Zonen der
    /// Welt spannen 26 Stunden, eine spätere Seite kann also einen Tag tragen,
    /// der **über** bereits gezeichnete Abschnitte gehört. Anhängen allein
    /// genügt dafür nicht; es bräuchte ein Einsortieren.
    ///
    /// Daraus folgt eine Verhaltensänderung, die man kennen sollte: Beim
    /// Nachladen kann ein Abschnitt oberhalb sichtbarer Abschnitte erscheinen,
    /// der Reiter also unter dem Finger springen. Kaputt geht dabei nichts —
    /// `neuGruppieren` baut alles neu, kein `flachIndex` verliert seinen Bezug.
    /// In einer überwiegend deutschen Mediathek tritt es praktisch nie auf, an
    /// einer Seitengrenze einer Reise-Mediathek schon.
    private func neuGruppieren(meinLauf: UInt64) async {
        // Die Rechnung läuft **neben** dem Hauptthread, nicht auf ihm. Sie ist
        // rein — `Asset` ist `Sendable`, die drei Kacheltypen tragen nur
        // Zeichenfolgen, Wahrheitswerte und Zahlen und sind damit implizit
        // `Sendable` —, also darf sie das.
        //
        // Warum das nötig ist: Jede Seite baut **alle** bisherigen Assets neu
        // auf, über die Mediathek also quadratisch. Bei rund 165 000 Assets
        // sind das gut 800 Seiten, deren letzte über alles Bisherige liefe;
        // auf dem Hauptthread ruckte das Raster dabei sichtbar. Die
        // Gesamtarbeit bleibt gleich, aber sie blockiert das Zeichnen nicht
        // mehr. Weniger Arbeit wäre der nächste Schritt — inkrementelles
        // Anhängen —, und der ist seit der Umstellung auf die fotoeigene
        // Ortszeit schwerer geworden: Eine spätere Seite kann einen Tag
        // tragen, der **über** bereits gezeichnete Abschnitte gehört, also
        // genügt Anhängen nicht, es bräuchte ein Einsortieren.
        gruppierNummer &+= 1
        let meineNummer = gruppierNummer
        let signpostID = OSSignpostID(log: AppLogger.dataPerf)
        os_signpost(.begin, log: AppLogger.dataPerf, name: "PhoneFeedGruppieren", signpostID: signpostID,
                    "%d Assets", assets.count)
        defer { os_signpost(.end, log: AppLogger.dataPerf, name: "PhoneFeedGruppieren", signpostID: signpostID) }
        let momentaufnahme = assets
        let sterne = favoritenAenderungen
        let bildsuche = !auswahl.freitext.isEmpty
        let bildsucheTitel = String(localized: "Best Matches")

        let ergebnis = await Task.detached(priority: .userInitiated) {
            () -> (eintraege: [PhoneAlbumGridEintrag], abschnitte: [PhoneFeedAbschnitt]) in
            let tage = bildsuche
                ? PhotoFeedGrouping.inReihenfolge(assets: momentaufnahme, titel: bildsucheTitel)
                : PhotoFeedGrouping.build(assets: momentaufnahme)

            var flach: [PhoneAlbumGridEintrag] = []
            flach.reserveCapacity(momentaufnahme.count)
            var neueAbschnitte: [PhoneFeedAbschnitt] = []
            neueAbschnitte.reserveCapacity(tage.count)

            for tag in tage {
                var kacheln: [PhoneFeedKachel] = []
                kacheln.reserveCapacity(tag.assets.count)
                for asset in tag.assets {
                    var eintrag = PhoneAlbumGridEintrag(asset: asset)
                    if let stern = sterne[asset.id] {
                        eintrag = eintrag.mitFavorit(stern)
                    }
                    kacheln.append(PhoneFeedKachel(flachIndex: flach.count, eintrag: eintrag))
                    flach.append(eintrag)
                }
                neueAbschnitte.append(PhoneFeedAbschnitt(id: tag.id, titel: tag.title, kacheln: kacheln))
            }
            return (flach, neueAbschnitte)
        }.value

        // Während der Rechnung kann ein `ladeVonVorne` dazwischengekommen sein
        // (Serverwechsel, Aktualisieren-Zug). Dann gehört dieses Ergebnis zu
        // einem Stand, den es nicht mehr gibt — dieselbe Wache wie nach dem
        // Netzabruf oben.
        if let vorUebernahmeHaken { await vorUebernahmeHaken() }
        guard meinLauf == generation, meineNummer == gruppierNummer else { return }
        eintraege = ergebnis.eintraege
        abschnitte = ergebnis.abschnitte
    }

    // MARK: - Änderungen aus dem Einzelbild

    /// Nimmt ein in den Papierkorb gelegtes Asset aus der Liste.
    ///
    /// Ruft ``PhonePhotoFeedView`` über den `onGeloescht`-Rückruf von
    /// ``PhoneAssetView`` auf. Vollständiges Neugruppieren, nicht bloß ein
    /// `remove` in `eintraege`: Jede Kachel trägt ihren `flachIndex`, und der
    /// ist nach dem Herausnehmen für alle folgenden um eins verschoben —
    /// bliebe er stehen, öffnete ein Tipp danach das falsche Bild.
    ///
    /// `gesehen` verliert die ID wieder, damit ein späteres Wiederherstellen
    /// aus dem Papierkorb (am Mac oder im Web) beim nächsten Neuladen nicht
    /// an der Entdopplung hängen bleibt.
    func entferne(assetId: String) async {
        let vorher = assets.count
        assets.removeAll { $0.id == assetId }
        guard assets.count != vorher else { return }
        gesehen.remove(assetId)
        favoritenAenderungen[assetId] = nil
        await neuGruppieren(meinLauf: generation)
    }

    /// Zieht einen im Einzelbild gesetzten oder entfernten Stern nach.
    ///
    /// Anders als ``entferne(assetId:)`` ohne Neugruppieren: Es ändert sich
    /// weder die Reihenfolge noch ein `flachIndex`, nur ein Feld einer
    /// einzelnen Kachel. Über die ganze Mediathek neu zu bauen (bei rund
    /// 165 000 Assets) wäre für ein Bit maßlos.
    /// Wendet eine Sternänderung an — der Weg der app-weiten
    /// ``PhoneFavoritMeldung``. Ein Feed, der **nur Favoriten** zeigt, nimmt die
    /// Kachel beim Entfernen des Sterns heraus (sonst blieb sie stehen); beim
    /// Setzen fügt er nichts hinzu — das Foto kommt beim nächsten Laden, denn
    /// ob es überhaupt zur Auswahl passt (Ort, Person, Zeitraum), weiß nur der Server.
    func wendeFavoritAn(assetId: String, ist: Bool) async {
        if auswahl.nurFavoriten && !ist {
            await entferne(assetId: assetId)
        } else {
            setzeFavorit(assetId: assetId, ist: ist)
        }
    }

    func setzeFavorit(assetId: String, ist: Bool) {
        favoritenAenderungen[assetId] = ist
        if let index = eintraege.firstIndex(where: { $0.id == assetId }) {
            eintraege[index] = eintraege[index].mitFavorit(ist)
        }
        for abschnittIndex in abschnitte.indices {
            guard let kachelIndex = abschnitte[abschnittIndex].kacheln
                .firstIndex(where: { $0.eintrag.id == assetId }) else { continue }
            let alt = abschnitte[abschnittIndex].kacheln[kachelIndex]
            abschnitte[abschnittIndex].kacheln[kachelIndex] = PhoneFeedKachel(
                flachIndex: alt.flachIndex,
                eintrag: alt.eintrag.mitFavorit(ist)
            )
            return
        }
    }
}

/// Die app-weite Meldung „Stern geändert". Jedes Einzelbild schickt sie, jeder
/// ``PhonePhotoFeed`` hört zu — Fotos, Favoriten und Entdecken haben je einen
/// eigenen Feed, und ein Rückruf erreichte nur den, aus dem das Bild kam.
enum PhoneFavoritMeldung {
    static let name = Notification.Name("PhoneFavoritGeaendert")

    @MainActor
    static func melde(assetId: String, ist: Bool, center: NotificationCenter = .default) {
        center.post(name: name, object: nil, userInfo: ["assetId": assetId, "ist": ist])
    }

    static func lies(_ meldung: Notification) -> (String, Bool)? {
        guard let id = meldung.userInfo?["assetId"] as? String,
              let ist = meldung.userInfo?["ist"] as? Bool else { return nil }
        return (id, ist)
    }
}
