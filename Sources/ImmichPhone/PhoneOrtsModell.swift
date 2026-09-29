import Foundation
import Observation

/// Der Zustand des Orte-Reiters: Katalog, Auswahl, Chips und das Raster.
///
/// Lebt als `@State` in `PhoneRootView` — aus demselben Grund wie `photoFeed`:
/// Ein Reiterwechsel soll weder Katalog noch Auswahl noch geladene Seiten
/// verwerfen. Der Feed ist ein **eigener** `PhonePhotoFeed`, nicht der des
/// Fotos-Reiters; beide teilen sich nur den Code.
@Observable @MainActor
final class PhoneOrtsModell {

    private(set) var katalog: PhoneOrtsKatalog?
    /// Läuft ein Katalogaufbau? Die Übersicht zeigt nur dann einen Spinner, wenn
    /// noch **kein** Katalog da ist — sonst frischt sie still auf.
    private(set) var baut = false
    /// Nur gesetzt, wenn der Aufbau scheitert **und** kein Katalog vorliegt.
    /// Mit Katalog bleibt ein Fehlschlag still (Spec, „Fehlerfälle").
    private(set) var aufbauFehler: String?
    private(set) var auswahl: PhoneSuchAuswahl = .leer
    /// Namen zu den Personen-IDs der Auswahl, für die Filterleiste. Die Auswahl
    /// trägt nur IDs (ihre Gleichheit steuert das Neuladen); den Namen bringt der
    /// angetippte Chip mit.
    private(set) var personenNamen: [String: String] = [:]

    var suchtext = ""

    let feed = PhonePhotoFeed()
    let facetten = PhoneOrtsFacetten()

    private let speicher: PhoneOrtsKatalogSpeicher
    /// Für welchen Server `katalog` geladen wurde.
    private var basis: URL?
    /// Der Server, für den `aufbauTask` gerade läuft — `nil`, solange keiner läuft.
    private var aufbauServer: URL?
    /// Der laufende Katalogaufbau, falls einer läuft. Jeder Aufruf von
    /// ``aktualisieren(apiClient:neuEinlesen:jetzt:)`` wartet einen schon laufenden
    /// Lauf zuerst ab, statt ihn stillschweigend zu ignorieren — sonst verpufft „Orte
    /// neu einlesen", während im Hintergrund gerade eine Frische-Auffrischung läuft.
    private var aufbauTask: Task<Void, Never>?
    /// Zählt jeden ``starteAufbau(apiClient:neuEinlesen:jetzt:)`` und jedes ``leere()``
    /// hoch. Der Lauf übernimmt sein Ergebnis und räumt `aufbauTask`/`aufbauServer`/`baut`
    /// **in seinem eigenen Rumpf** auf, nur wenn er noch der aktuelle ist — sonst könnte
    /// ein nach dem Abmelden gestarteter Lauf von einem nachzüglerischen alten (des
    /// Vorkontos) überschrieben werden.
    private var aufbauID: UInt64 = 0
    private var facettenTask: Task<Void, Never>?
    private var personenTask: Task<Void, Never>?

    init(speicher: PhoneOrtsKatalogSpeicher = .standard) {
        self.speicher = speicher
    }

    var treffer: [PhoneOrtsTreffer] {
        PhoneOrtsSuche.treffer(suchtext, in: katalog)
    }

    // MARK: - Katalog

    /// Aus `.task(id: baseURL)` der Ansicht. Liest beim ersten Mal (und nach einem
    /// Serverwechsel) den gespeicherten Katalog dieses Servers und frischt ihn auf,
    /// wenn er älter als ``PhoneOrtsKatalog/maxAlter`` ist. Offline nur lesen.
    func erscheint(apiClient: ImmichAPIClient, offline: Bool, jetzt: Date = Date()) async {
        if basis != apiClient.baseURL {
            await wechsleServer(zu: apiClient)
        }
        guard !offline else { return }
        if katalog?.istFrisch(jetzt: jetzt) != true {
            await aktualisieren(apiClient: apiClient, jetzt: jetzt)
        }
    }

    /// Voller Lauf. Aus der Frische-Regel, dem Aktualisieren-Zug und — mit
    /// `neuEinlesen` — aus den Einstellungen; dann werden auch die gezählten
    /// Städte verworfen.
    ///
    /// Läuft schon ein Aufbau, wartet dieser Aufruf ihn zuerst ab, statt ihn zu
    /// ignorieren: Sonst verpufft „Orte neu einlesen", während im Hintergrund
    /// gerade eine Frische-Auffrischung unterwegs ist — der laufende Aufbau würde mit
    /// dem alten `vorher`-Katalog fertig, und die gezählten Städte blieben trotz
    /// `neuEinlesen` erhalten. Nach dem Abwarten startet dieser Aufruf einen eigenen
    /// Lauf, außer der abgewartete war schon für **denselben** Server **und** ohne
    /// `neuEinlesen` gewünscht — sonst (anderer Server, oder wir wollten neu einlesen)
    /// erneut prüfen, ob inzwischen nicht schon jemand anderes genau das erledigt hat.
    ///
    /// Ein ``leere()`` (Abmelden) während des Wartens entwertet den abgewarteten Lauf:
    /// Er gehörte womöglich zu einem anderen Konto hinter derselben Adresse. Dann
    /// zählt er nicht als erledigt — erkennbar daran, dass sich `aufbauID` beim Warten
    /// geändert hat.
    func aktualisieren(apiClient: ImmichAPIClient, neuEinlesen: Bool = false, jetzt: Date = Date()) async {
        // Auch hier, nicht nur in `erscheint`: „Orte neu einlesen" kann vor dem ersten
        // Öffnen des Reiters kommen. Ohne Lesen der Datei stünde danach `basis` schon
        // richtig, `erscheint` läse sie nie mehr — und ein gescheiterter Lauf zeigte
        // einen Fehler statt der gespeicherten Orte.
        if basis != apiClient.baseURL {
            await wechsleServer(zu: apiClient)
        }
        while let laufend = aufbauTask {
            let warFuerUnserenServer = aufbauServer == apiClient.baseURL
            let idVorher = aufbauID
            await laufend.value
            if warFuerUnserenServer && !neuEinlesen && aufbauID == idVorher { return }
        }
        await starteAufbau(apiClient: apiClient, neuEinlesen: neuEinlesen, jetzt: jetzt)
    }

    /// Der eigentliche Netzlauf. Immer über ``aktualisieren(apiClient:neuEinlesen:jetzt:)``
    /// aufgerufen, nie direkt — nur so ist `aufbauTask` immer der **eine** laufende Lauf,
    /// und `baut` ist genau während dieser Funktion `true`.
    ///
    /// **Wichtig:** `aufbauTask`/`aufbauServer`/`baut` werden **im Rumpf des `Task`
    /// selbst** zurückgesetzt, als dessen letzter Schritt — nicht erst danach, hier in
    /// `starteAufbau`, nach einem eigenen `await lauf.value`. Zwei getrennte Fortsetzungen
    /// (die dieser Funktion und die eines wartenden ``aktualisieren(apiClient:neuEinlesen:jetzt:)``)
    /// hängen beide an genau demselben `lauf.value`; welche zuerst dran ist, legt Swift
    /// nicht fest. Räumt nur diese Funktion nach ihrem eigenen `await` auf, kann ein
    /// Wartender, dessen Fortsetzung zuerst läuft, `aufbauTask` immer wieder als „noch
    /// da" vorfinden und in einer Schleife aus `await` auf einen längst fertigen Lauf
    /// hängen bleiben, ohne dass die aufräumende Fortsetzung je zum Zug kommt — gemessen
    /// als Sackgasse bei 0 % CPU hier, ~100 % im simulierten App-Prozess. Räumt der Lauf
    /// sich selbst auf, bevor er sich als „fertig" zeigt, sieht das niemand mehr offen.
    private func starteAufbau(apiClient: ImmichAPIClient, neuEinlesen: Bool, jetzt: Date) async {
        aufbauID &+= 1
        let meineID = aufbauID
        aufbauServer = apiClient.baseURL
        baut = true
        let vorherKatalog = neuEinlesen ? nil : katalog
        let lauf = Task<Void, Never> {
            do {
                let neu = try await PhoneOrtsKatalogAufbau.aufbauen(apiClient: apiClient, vorher: vorherKatalog, jetzt: jetzt)
                // Ein Serverwechsel während des Laufs: Das Ergebnis gehört nicht mehr hierher.
                // Ein Abmelden ebenso — auch wenn danach dieselbe Adresse mit einem
                // anderen Schlüssel wieder erscheint und der Adressabgleich wieder passt.
                if self.aufbauID == meineID, apiClient.baseURL == self.basis {
                    self.katalog = neu
                    self.aufbauFehler = nil
                    self.speichere(neu)
                    self.facetten.vergissPersonen()
                }
            } catch {
                AppLogger.cache.error("Ortskatalog-Aufbau gescheitert: \(error.localizedDescription, privacy: .public)")
                // Derselbe Serverwechsel-Schutz für den Fehlerfall: Der Fehlschlag eines
                // Laufs für den **alten** Server darf beim neuen keinen Fehler zeigen.
                if self.aufbauID == meineID, apiClient.baseURL == self.basis, self.katalog == nil {
                    self.aufbauFehler = error.localizedDescription
                }
            }
            // Nur aufräumen, wenn inzwischen kein neuerer Lauf gestartet wurde — siehe
            // `aufbauID`. Noch im selben, synchronen Anschluss wie oben: Bis hierher ist
            // kein weiteres `await` mehr nötig, also kann sich kein Wartender dazwischen-
            // schieben, bevor `aufbauTask` wirklich `nil` ist.
            if self.aufbauID == meineID {
                self.aufbauTask = nil
                self.aufbauServer = nil
                self.baut = false
            }
        }
        aufbauTask = lauf
        await lauf.value
    }

    // MARK: - Auswahl

    /// Jede Auswahländerung läuft hierüber: Suchtreffer, Länderkachel, Chip,
    /// ✕ in der Filterleiste. Der Feed lädt dabei von vorne (Cursor-Reset), laufende
    /// Chip-Läufe der alten Auswahl werden abgebrochen.
    func waehle(_ neu: PhoneSuchAuswahl, apiClient: ImmichAPIClient) async {
        suchtext = ""
        guard neu != auswahl else { return }
        auswahl = neu
        personenNamen = personenNamen.filter { neu.personen.contains($0.key) }
        facettenTask?.cancel()
        personenTask?.cancel()

        guard !neu.istLeer else {
            facetten.leere()
            feed.leere()
            return
        }
        // Bildsuche: Trefferzahl und Nachschlag-Chips zählten ohne den Text und
        // zeigten damit Zahlen, die nicht zum Raster passen — also keine.
        guard neu.freitext.isEmpty else {
            facetten.leere()
            await feed.setzeAuswahl(neu, apiClient: apiClient)
            return
        }

        let land = neu.land.flatMap { katalog?.land($0) }
        let gespeichert = neu.istNurLand ? neu.land.flatMap { katalog?.staedteAnzahlen[$0] } : nil
        facettenTask = Task { [facetten] in
            let gezaehlt = await facetten.laden(
                fuer: neu, katalogLand: land, gespeicherteStaedte: gespeichert, apiClient: apiClient
            )
            // Ein Abbruch ist eine Absicherung, kein verlässlicher Zeitpunkt: Bis hierher
            // kann die Auswahl weitergezogen sein oder der Server gewechselt haben, ohne
            // dass der Task das noch mitbekommt. Nur bei exakt derselben Auswahl **und**
            // demselben Server dürfen die gezählten Städte in den Katalog zurück.
            guard !Task.isCancelled, self.auswahl == neu, self.basis == apiClient.baseURL else { return }
            if let gezaehlt, let name = neu.land {
                self.merkeStaedte(gezaehlt, land: name)
            }
        }
        await feed.setzeAuswahl(neu, apiClient: apiClient)
    }

    func tippePerson(_ chip: PhoneOrtsChip, apiClient: ImmichAPIClient) async {
        personenNamen[chip.id] = chip.titel
        await waehle(auswahl.mitPerson(chip.id), apiClient: apiClient)
    }

    /// Wie ``tippePerson(_:apiClient:)``: Die neue Auswahl entsteht aus der
    /// **aktuellen**, nicht aus der beim Zeichnen der Ansicht — sonst verlöre ein
    /// schneller zweiter Tipp (2019, dann Tokyo vor dem Neuzeichnen) den ersten.
    func tippeStadt(_ chip: PhoneOrtsChip, apiClient: ImmichAPIClient) async {
        await waehle(auswahl.mitStadt(chip.id), apiClient: apiClient)
    }

    func tippeJahr(_ chip: PhoneOrtsChip, apiClient: ImmichAPIClient) async {
        guard let jahr = Int(chip.id) else { return }
        await waehle(auswahl.mitJahr(jahr), apiClient: apiClient)
    }

    /// Der Knopf „Personen ermitteln (≈ N MB)" über der Schwelle.
    func personenErmitteln(apiClient: ImmichAPIClient) {
        let aktuelle = auswahl
        personenTask?.cancel()
        personenTask = Task { [facetten] in
            await facetten.personenErmitteln(fuer: aktuelle, apiClient: apiClient)
        }
    }

    /// Beim Abmelden (und bei „Zugangsdaten ändern"): Katalogdatei weg, alles zurück —
    /// auch ein laufender Aufbau. Er läuft zwar weiter, aber das Hochzählen von
    /// `aufbauID` entwertet ihn: Sein Ergebnis gehört womöglich zum Vorkonto hinter
    /// derselben Adresse und darf weder in `katalog` noch in die Datei.
    func leere() {
        facettenTask?.cancel()
        personenTask?.cancel()
        aufbauID &+= 1
        aufbauTask = nil
        aufbauServer = nil
        baut = false
        speicher.loeschen()
        katalog = nil
        basis = nil
        aufbauFehler = nil
        auswahl = .leer
        personenNamen = [:]
        suchtext = ""
        facetten.vergiss()
        feed.leere()
        vergissEinstiege()
        PhoneZuletztGesucht.vergiss()
    }

    // MARK: - Einstiege (Entdecken)

    /// Die Startreihe: die häufigsten benannten, sichtbaren Personen.
    private(set) var personen: [Person] = []
    /// Alle benannten, sichtbaren Personen, nach Anzahl — für „Alle“ und die Textsuche.
    private(set) var allePersonen: [Person] = []
    /// Jahre mit Fotos, neu → alt (Spanne ältestes…jüngstes Foto).
    private(set) var jahre: [Int] = []
    private(set) var zuletzt: [PhoneZuletztEintrag] = []

    nonisolated static func topPersonen(_ alle: [Person], anzahl: Int = 12) -> [Person] {
        Array(sichtbar(alle).prefix(anzahl))
    }

    /// Benannt und sichtbar. Sortiert nur, wenn der Server Anzahlen liefert —
    /// Immich tut das bei `/api/people` nicht, sortiert aber selbst schon (benannte
    /// zuerst, dann nach Gesichtern). Stabil: gleiche Anzahl behält die Serverfolge.
    nonisolated private static func sichtbar(_ alle: [Person]) -> [Person] {
        alle.filter { !$0.name.isEmpty && $0.isHidden != true }
            .enumerated()
            .sorted { a, b in
                let (na, nb) = (a.element.assetCount ?? 0, b.element.assetCount ?? 0)
                return na != nb ? na > nb : a.offset < b.offset
            }
            .map(\.element)
    }

    nonisolated static func jahre(aeltestes: String?, juengstes: String?) -> [Int] {
        guard let a = aeltestes.flatMap({ Int($0.prefix(4)) }),
              let j = juengstes.flatMap({ Int($0.prefix(4)) }), a <= j else { return [] }
        return Array((a...j).reversed())
    }

    /// Läuft gerade ``ladeEinstiege(apiClient:personenErlaubt:)``?
    private(set) var laedtEinstiege = false
    private var einstiegeTask: Task<Void, Never>?
    /// Entwertet einen laufenden Lauf bei Abmelden und Serverwechsel — sonst schriebe
    /// er die Personen des alten Kontos zurück.
    private var einstiegeLauf: UInt64 = 0

    /// Personen (nur mit `person.read`) und die Jahresspanne — parallel. „Zuletzt
    /// gesucht“ ist lokal und steht sofort da.
    func ladeEinstiege(apiClient: ImmichAPIClient, personenErlaubt: Bool) async {
        zuletzt = PhoneZuletztGesucht.lade(basis: apiClient.baseURL.absoluteString)
        einstiegeLauf &+= 1
        let lauf = einstiegeLauf
        laedtEinstiege = true
        let aufgabe = Task { [weak self] in
            async let leute: [Person] = personenErlaubt ? ((try? await apiClient.getPeople()) ?? []) : []
            async let spanne = Self.jahresSpanne(apiClient: apiClient)
            let geladen = await leute
            let (aeltestes, juengstes) = await spanne
            guard let self, lauf == self.einstiegeLauf else { return }
            self.allePersonen = Self.sichtbar(geladen)
            self.personen = Array(self.allePersonen.prefix(12))
            self.jahre = Self.jahre(aeltestes: aeltestes, juengstes: juengstes)
        }
        einstiegeTask = aufgabe
        await aufgabe.value
        if lauf == einstiegeLauf { laedtEinstiege = false }
    }

    /// Alles aus den Einstiegen vergessen und laufende Läufe entwerten.
    private func vergissEinstiege() {
        einstiegeLauf &+= 1
        einstiegeTask = nil
        laedtEinstiege = false
        personen = []
        allePersonen = []
        jahre = []
        zuletzt = []
    }

    /// Ältestes und jüngstes Foto: je eine Suche mit einem Treffer, statt je Jahr zu zählen.
    nonisolated private static func jahresSpanne(apiClient: ImmichAPIClient) async -> (String?, String?) {
        @Sendable func erstes(_ richtung: SearchOrder.Direction) async -> String? {
            let anfrage = AssetSearchQuery(
                filter: .visibleLibrary(type: nil),
                orderBy: SearchOrder(field: .fileCreatedAt, direction: richtung),
                size: 1
            )
            return (try? await apiClient.searchAssets(query: anfrage))?.items?.first?.fileCreatedAt
        }
        async let alt = erstes(.asc)
        async let neu = erstes(.desc)
        return await (alt, neu)
    }

    /// Namen aus einem Einstieg (Gesicht, Zuletzt-Eintrag) für die Filterleiste merken.
    func uebernimmNamen(_ namen: [String: String]) {
        personenNamen.merge(namen) { _, neu in neu }
    }

    /// Getippter Text → Auswahl. Katalog: alle Personen und der Ortskatalog.
    func suche(_ text: String, apiClient: ImmichAPIClient) async {
        // Kaltstart: Ohne die Personen läse der Text „Anna“ als Bildsuche.
        await einstiegeTask?.value
        let katalog = PhoneSuchZerlegung.katalog(personen: allePersonen, orte: self.katalog)
        let ergebnis = PhoneSuchZerlegung.zerlege(text, katalog: katalog)
        guard !ergebnis.auswahl.istLeer else { return }
        uebernimmNamen(ergebnis.personenNamen)
        await waehle(ergebnis.auswahl, apiClient: apiClient)
    }

    func merkeZuletzt(titel: String, basis: String) {
        guard !auswahl.istLeer else { return }
        let namen = personenNamen.filter { auswahl.personen.contains($0.key) }
        let eintrag = PhoneZuletztEintrag(auswahl: auswahl, personenNamen: namen,
                                          titel: titel, anzahl: facetten.treffer)
        PhoneZuletztGesucht.merke(eintrag, basis: basis)
        zuletzt = PhoneZuletztGesucht.lade(basis: basis)
    }

    func entferneZuletzt(_ auswahl: PhoneSuchAuswahl, basis: String) {
        PhoneZuletztGesucht.entferne(auswahl, basis: basis)
        zuletzt = PhoneZuletztGesucht.lade(basis: basis)
    }

    // MARK: - Intern

    /// Server gewechselt (oder zum ersten Mal einer): gespeicherten Katalog dieses
    /// Servers lesen, Chips samt Personen-Zwischenspeicher vergessen, Auswahl
    /// zurücksetzen. Die eine Stelle für ``erscheint(apiClient:offline:jetzt:)`` und
    /// ``aktualisieren(apiClient:neuEinlesen:jetzt:)`` — wer zuerst kommt, liest.
    private func wechsleServer(zu apiClient: ImmichAPIClient) async {
        basis = apiClient.baseURL
        katalog = speicher.laden(basis: apiClient.baseURL)
        aufbauFehler = nil
        facettenTask?.cancel()
        personenTask?.cancel()
        facetten.vergiss()
        vergissEinstiege()
        await waehle(.leer, apiClient: apiClient)
    }

    private func merkeStaedte(_ chips: [PhoneOrtsChip], land: String) {
        guard var neu = katalog else { return }
        neu.staedteAnzahlen[land] = chips
        katalog = neu
        speichere(neu)
    }

    private func speichere(_ katalog: PhoneOrtsKatalog) {
        do {
            try speicher.speichern(katalog)
        } catch {
            AppLogger.cache.error("Ortskatalog nicht gespeichert: \(error.localizedDescription, privacy: .public)")
        }
    }
}
