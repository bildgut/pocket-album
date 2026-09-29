import Foundation
import Testing
@testable import ImmichPhone

/// Ein Land, eine Stadt, ein Foto — genug für einen vollständigen Katalogaufbau.
private func einLandServer(mitschnitt: OrteMitschnitt) -> OrteMockURLProtocol.Handler {
    { request, koerper in
        mitschnitt.merke(request, koerper)
        switch request.url?.path {
        case "/api/search/suggestions":
            return OrteMockURLProtocol.query(request, "type") == "country"
                ? (200, Data(#"["Japan"]"#.utf8))
                : (200, Data("[]".utf8))
        case "/api/search/statistics":
            return (200, Data(#"{"total":10}"#.utf8))
        case "/api/search/metadata":
            return (200, OrteMockURLProtocol.seiteJSON([OrteMockURLProtocol.assetJSON(id: "jp-1", localDateTime: "2025-11-24T08:10:23.000Z")]))
        default:
            return (404, Data())
        }
    }
}

/// Wie `einLandServer`, aber die Länderliste kommt erst nach ~0,3 s — genug Zeit, um
/// mittendrin einen zweiten `aktualisieren`- oder `erscheint`-Aufruf zu starten, ohne
/// die Suite unnötig zu verlangsamen. Alles andere (Zählung, jüngstes Foto) antwortet
/// sofort, damit der restliche Aufbau schnell fertig wird.
private func langsamerLandServer(land: String, mitschnitt: OrteMitschnitt) -> OrteMockURLProtocol.Handler {
    { request, koerper in
        mitschnitt.merke(request, koerper)
        switch request.url?.path {
        case "/api/search/suggestions":
            guard OrteMockURLProtocol.query(request, "type") == "country" else { return (200, Data("[]".utf8)) }
            Thread.sleep(forTimeInterval: 0.3)
            return (200, Data(#"["\#(land)"]"#.utf8))
        case "/api/search/statistics":
            return (200, Data(#"{"total":10}"#.utf8))
        case "/api/search/metadata":
            return (200, OrteMockURLProtocol.seiteJSON([]))
        default:
            return (404, Data())
        }
    }
}

/// Wie `langsamerLandServer`, meldet aber am Ende jeder Anfrage einen Fehler — für
/// einen Aufbau, der erst nach einer Weile scheitert (der alte Server im
/// Serverwechsel-Test).
private func langsamerFehlschlagenderServer() -> OrteMockURLProtocol.Handler {
    { request, _ in
        if request.url?.path == "/api/search/suggestions", OrteMockURLProtocol.query(request, "type") == "country" {
            Thread.sleep(forTimeInterval: 0.3)
        }
        return (404, Data())
    }
}

/// Meldet, sobald eine verzögerte Server-Antwort tatsächlich verschickt wurde — der
/// Test pollt darauf, statt eine feste Zeit zu raten, wann der Personendurchlauf mit
/// seiner (einzigen) Anfrage fertig ist.
private final class Vollzugsmelder: @unchecked Sendable {
    private let lock = NSLock()
    private var _fertig = false
    var fertig: Bool {
        lock.lock(); defer { lock.unlock() }
        return _fertig
    }
    func melde() {
        lock.lock(); defer { lock.unlock() }
        _fertig = true
    }
}

/// Wenige Treffer (`total` weit unter der Personen-Schwelle) — der automatische
/// Personendurchlauf (`withPeople: true`) läuft von selbst an. Nur **diese** eine
/// Anfrageart hängt 0,5 s und meldet sich danach bei `melder`; Zählung und
/// Jahres-/Städte-Suche (kein `withPeople`) antworten sofort, damit der Test sicher
/// mitten im Personendurchlauf steht, wenn er den Server wechselt — nicht irgendwo
/// in der schnellen Vorphase.
private func personenLangsamerServer(mitschnitt: OrteMitschnitt, melder: Vollzugsmelder) -> OrteMockURLProtocol.Handler {
    { request, koerper in
        mitschnitt.merke(request, koerper)
        switch request.url?.path {
        case "/api/search/statistics":
            return (200, Data(#"{"total":50}"#.utf8))
        case "/api/search/metadata":
            if OrteMockURLProtocol.json(koerper)["withPeople"] as? Bool == true {
                Thread.sleep(forTimeInterval: 0.5)
                melder.melde()
            }
            return (200, OrteMockURLProtocol.seiteJSON([]))
        default:
            return (200, Data("[]".utf8))
        }
    }
}

/// Wie `einLandServer`, aber mit frei wählbarem Land und ohne Verzögerung — der
/// „andere Server" hinter derselben Adresse im Abmelde-Test.
private func schnellerLandServer(land: String) -> OrteMockURLProtocol.Handler {
    { request, _ in
        switch request.url?.path {
        case "/api/search/suggestions":
            return OrteMockURLProtocol.query(request, "type") == "country"
                ? (200, Data(#"["\#(land)"]"#.utf8))
                : (200, Data("[]".utf8))
        case "/api/search/statistics":
            return (200, Data(#"{"total":10}"#.utf8))
        case "/api/search/metadata":
            return (200, OrteMockURLProtocol.seiteJSON([OrteMockURLProtocol.assetJSON(id: "\(land)-1", localDateTime: "2025-11-24T08:10:23.000Z")]))
        default:
            return (404, Data())
        }
    }
}

/// Zählt jede Anfrage mit `total` und liefert im Personendurchlauf genau eine
/// benannte Person — für die Tests, ob ermittelte Personen einen Server- oder
/// Kontowechsel überleben. Über der Schwelle (`total >= 2 000`) läuft der Durchlauf
/// nicht von selbst; ein Treffer im Zwischenspeicher zeigte die Personen trotzdem.
private func personenServer(total: Int, person: (id: String, name: String)) -> OrteMockURLProtocol.Handler {
    { request, koerper in
        switch request.url?.path {
        case "/api/search/statistics":
            return (200, Data(#"{"total":\#(total)}"#.utf8))
        case "/api/search/metadata":
            let personen = OrteMockURLProtocol.json(koerper)["withPeople"] as? Bool == true ? [(id: person.id, name: person.name, hidden: false)] : []
            return (200, OrteMockURLProtocol.seiteJSON([OrteMockURLProtocol.assetJSON(id: "a-\(person.id)", localDateTime: "2019-04-02T10:00:00.000Z", people: personen)]))
        default:
            return (200, Data("[]".utf8))
        }
    }
}

@Suite("PhoneOrtsModell", .serialized)
@MainActor
struct PhoneOrtsModellTests {

    private let host = "orte-modell.test"
    private let jetzt = Date(timeIntervalSince1970: 1_800_000_000)

    private func speicher() -> PhoneOrtsKatalogSpeicher {
        let ordner = FileManager.default.temporaryDirectory.appending(path: "orte-modell-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true)
        return PhoneOrtsKatalogSpeicher(datei: ordner.appending(path: "orte_katalog.json"))
    }

    private func katalog(basis: String, aufgebautAm: Date?) -> PhoneOrtsKatalog {
        PhoneOrtsKatalog(
            basis: basis,
            laender: [PhoneOrtsLand(name: "Greece", anzahl: 452, zuletzt: "2026-06-29T12:00:00.000Z", titelbildId: "gr-1", staedte: [], regionen: [])],
            aufgebautAm: aufgebautAm
        )
    }

    private func unerreichbarerClient() -> ImmichAPIClient {
        let konfiguration = URLSessionConfiguration.ephemeral
        konfiguration.timeoutIntervalForRequest = 5
        konfiguration.timeoutIntervalForResource = 5
        return ImmichAPIClient(baseURL: URL(string: "https://immich.invalid")!, apiKey: "test", sessionConfiguration: konfiguration)
    }

    @Test("Frischer gespeicherter Katalog: sofort da, kein Netzweg")
    func frischOhneNetz() async throws {
        let mitschnitt = OrteMitschnitt()
        OrteMockURLProtocol.registriere(host: host, einLandServer(mitschnitt: mitschnitt))
        defer { OrteMockURLProtocol.entferne(host: host) }
        let s = speicher()
        try s.speichern(katalog(basis: "https://\(host)", aufgebautAm: jetzt.addingTimeInterval(-60)))

        let modell = PhoneOrtsModell(speicher: s)
        await modell.erscheint(apiClient: OrteMockURLProtocol.client(host: host), offline: false, jetzt: jetzt)

        #expect(modell.katalog?.land("Greece") != nil)
        #expect(mitschnitt.alle.isEmpty)
    }

    @Test("Veralteter Katalog wird aufgefrischt und gespeichert")
    func veraltetWirdAufgefrischt() async throws {
        let mitschnitt = OrteMitschnitt()
        OrteMockURLProtocol.registriere(host: host, einLandServer(mitschnitt: mitschnitt))
        defer { OrteMockURLProtocol.entferne(host: host) }
        let s = speicher()
        try s.speichern(katalog(basis: "https://\(host)", aufgebautAm: jetzt.addingTimeInterval(-3600)))

        let client = OrteMockURLProtocol.client(host: host)
        let modell = PhoneOrtsModell(speicher: s)
        await modell.erscheint(apiClient: client, offline: false, jetzt: jetzt)

        #expect(modell.katalog?.aufgebautAm == jetzt)
        #expect(modell.katalog?.land("Japan")?.anzahl == 10)
        #expect(s.laden(basis: client.baseURL)?.aufgebautAm == jetzt)
        #expect(!modell.baut)
    }

    @Test("Offline: gespeicherten Katalog zeigen, nicht auffrischen")
    func offlineOhneAuffrischung() async throws {
        let mitschnitt = OrteMitschnitt()
        OrteMockURLProtocol.registriere(host: host, einLandServer(mitschnitt: mitschnitt))
        defer { OrteMockURLProtocol.entferne(host: host) }
        let s = speicher()
        try s.speichern(katalog(basis: "https://\(host)", aufgebautAm: jetzt.addingTimeInterval(-3600)))

        let modell = PhoneOrtsModell(speicher: s)
        await modell.erscheint(apiClient: OrteMockURLProtocol.client(host: host), offline: true, jetzt: jetzt)

        #expect(modell.katalog != nil)
        #expect(mitschnitt.alle.isEmpty)
    }

    @Test("Der Katalog eines anderen Servers wird nicht gezeigt")
    func andererServer() async throws {
        let s = speicher()
        try s.speichern(katalog(basis: "https://anderer.example", aufgebautAm: jetzt))

        let modell = PhoneOrtsModell(speicher: s)
        await modell.erscheint(apiClient: unerreichbarerClient(), offline: true, jetzt: jetzt)

        #expect(modell.katalog == nil)
    }

    @Test("Aufbau scheitert ohne Katalog: Fehler sichtbar")
    func fehlerOhneKatalog() async {
        let modell = PhoneOrtsModell(speicher: speicher())
        await modell.erscheint(apiClient: unerreichbarerClient(), offline: false, jetzt: jetzt)

        #expect(modell.katalog == nil)
        #expect(modell.aufbauFehler != nil)
    }

    @Test("Aufbau scheitert mit Katalog: still, der Katalog bleibt")
    func fehlerMitKatalog() async throws {
        let s = speicher()
        try s.speichern(katalog(basis: "https://immich.invalid", aufgebautAm: jetzt.addingTimeInterval(-3600)))

        let modell = PhoneOrtsModell(speicher: s)
        await modell.erscheint(apiClient: unerreichbarerClient(), offline: false, jetzt: jetzt)

        #expect(modell.katalog?.land("Greece") != nil)
        #expect(modell.aufbauFehler == nil)
    }

    @Test("waehle setzt die Auswahl im Feed und leert das Suchfeld")
    func waehle() async {
        let modell = PhoneOrtsModell(speicher: speicher())
        modell.suchtext = "jap"
        await modell.waehle(.land("Japan"), apiClient: unerreichbarerClient())

        #expect(modell.auswahl == .land("Japan"))
        #expect(modell.feed.auswahl == .land("Japan"))
        #expect(modell.suchtext.isEmpty)
    }

    @Test("Zurück zur Übersicht leert Feed und Chips")
    func zurueck() async {
        let modell = PhoneOrtsModell(speicher: speicher())
        let client = unerreichbarerClient()
        await modell.waehle(.land("Japan"), apiClient: client)
        await modell.waehle(.leer, apiClient: client)

        #expect(modell.auswahl.istLeer)
        #expect(modell.feed.auswahl == .leer)
        #expect(modell.facetten.treffer == nil)
        #expect(modell.facetten.personen == .keine)
    }

    @Test("tippePerson merkt sich den Namen, Abwählen vergisst ihn")
    func personenNamen() async {
        let modell = PhoneOrtsModell(speicher: speicher())
        let client = unerreichbarerClient()
        let clara = PhoneOrtsChip(id: "p1", titel: "Clara", anzahl: 3)
        await modell.waehle(.land("Japan"), apiClient: client)

        await modell.tippePerson(clara, apiClient: client)
        #expect(modell.auswahl.personen == ["p1"])
        #expect(modell.personenNamen["p1"] == "Clara")

        await modell.tippePerson(clara, apiClient: client)
        #expect(modell.auswahl.personen.isEmpty)
        #expect(modell.personenNamen["p1"] == nil)
    }

    @Test("Treffer kommen aus dem Suchtext gegen den Katalog")
    func treffer() async throws {
        let s = speicher()
        try s.speichern(katalog(basis: "https://immich.invalid", aufgebautAm: jetzt))
        let modell = PhoneOrtsModell(speicher: s)
        await modell.erscheint(apiClient: unerreichbarerClient(), offline: true, jetzt: jetzt)

        modell.suchtext = "gree"
        #expect(modell.treffer.map(\.name) == ["Greece"])
    }

    @Test("leere() löscht Katalogdatei und Zustand")
    func leeren() async throws {
        let s = speicher()
        try s.speichern(katalog(basis: "https://immich.invalid", aufgebautAm: jetzt))
        let modell = PhoneOrtsModell(speicher: s)
        await modell.erscheint(apiClient: unerreichbarerClient(), offline: true, jetzt: jetzt)

        modell.leere()

        #expect(modell.katalog == nil)
        #expect(modell.auswahl.istLeer)
        #expect(!FileManager.default.fileExists(atPath: s.datei.path))
    }

    // MARK: - Nebenläufigkeit (Fix-Runde 1)

    /// Prüft wiederholt (20-ms-Schritte, begrenzt auf `timeout`), ob die übergebene
    /// Bedingung eingetreten ist, statt eines festen `sleep`: Ein Hintergrund-Task, den
    /// der Test nicht direkt referenzieren kann (`facettenTask`, `aufbauTask` sind
    /// privat), bekommt so bis zu `timeout` Zeit, sich zu melden — tritt die Bedingung
    /// nie ein, kehrt die Funktion erst nach `timeout` zurück, und der anschließende
    /// `#expect` schlägt fehl.
    private func wartetAuf(timeout: TimeInterval = 3, _ bedingung: () -> Bool) async {
        let start = Date()
        while !bedingung(), Date().timeIntervalSince(start) < timeout {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    /// Startet `aktion` und wartet höchstens `sekunden` darauf, indem es über
    /// ``wartetAuf(timeout:_:)`` auf ein von `aktion` selbst gesetztes Flag pollt.
    ///
    /// Eine Warteschleife wie in `PhoneOrtsModell.aktualisieren` kann — durch einen
    /// künftigen Rückfall in genau den Fehler dieser Fix-Runde — den ganzen Testlauf
    /// aufhängen, statt nur den einen Test fehlschlagen zu lassen (gemessen: 8+ Minuten,
    /// bis der Prozess von außen beendet wurde). Diese Hülle macht daraus einen
    /// fehlschlagenden Test: Läuft `aktion` länger als `sekunden`, meldet
    /// `Issue.record` das und die Funktion kehrt trotzdem zurück — der hängende
    /// `Task` bleibt dann zwar im Hintergrund liegen, blockiert aber nicht mehr das
    /// Ende dieser Funktion oder den Rest der Suite.
    private func mitZeitlimit(_ sekunden: TimeInterval = 5, _ aktion: @escaping () async -> Void) async {
        var fertig = false
        Task {
            await aktion()
            fertig = true
        }
        await wartetAuf(timeout: sekunden) { fertig }
        if !fertig {
            Issue.record("Zeitlimit von \(sekunden) s überschritten — vermutlich eine hängende Warteschleife.")
        }
    }

    @Test("Neu einlesen während eines laufenden Aufbaus verwirft die alten Städtezahlen trotzdem")
    func neuEinlesenWaehrendLaufendemAufbau() async throws {
        let mitschnitt = OrteMitschnitt()
        OrteMockURLProtocol.registriere(host: host, langsamerLandServer(land: "Greece", mitschnitt: mitschnitt))
        defer { OrteMockURLProtocol.entferne(host: host) }

        let s = speicher()
        var alt = katalog(basis: "https://\(host)", aufgebautAm: jetzt.addingTimeInterval(-3600))
        alt.staedteAnzahlen["Greece"] = [PhoneOrtsChip(id: "Athens", titel: "Athens", anzahl: 100)]
        try s.speichern(alt)

        let client = OrteMockURLProtocol.client(host: host)
        let modell = PhoneOrtsModell(speicher: s)
        await modell.erscheint(apiClient: client, offline: true, jetzt: jetzt)
        #expect(modell.katalog?.staedteAnzahlen["Greece"] != nil)

        // Ein normaler Aktualisieren-Zug läuft schon (die Länderliste hängt 0,3 s),
        // während „Orte neu einlesen" dazwischenfunkt.
        let hintergrund = Task { await modell.aktualisieren(apiClient: client, jetzt: jetzt) }
        try? await Task.sleep(nanoseconds: 100_000_000)

        await mitZeitlimit {
            await modell.aktualisieren(apiClient: client, neuEinlesen: true, jetzt: jetzt)
            await hintergrund.value
        }

        #expect(modell.katalog?.staedteAnzahlen["Greece"] == nil)
        #expect(!modell.baut)
        let landAnfragen = mitschnitt.alle.filter {
            $0.request.url?.path == "/api/search/suggestions" && OrteMockURLProtocol.query($0.request, "type") == "country"
        }
        #expect(landAnfragen.count == 2)
    }

    @Test("Serverwechsel während eines laufenden Aufbaus liefert am Ende den neuen Server")
    func serverwechselWaehrendAufbau() async throws {
        let hostA = "orte-modell-wechsel-a.test"
        let hostB = "orte-modell-wechsel-b.test"
        OrteMockURLProtocol.registriere(host: hostA, langsamerLandServer(land: "Japan", mitschnitt: OrteMitschnitt()))
        OrteMockURLProtocol.registriere(host: hostB, einLandServer(mitschnitt: OrteMitschnitt()))
        defer {
            OrteMockURLProtocol.entferne(host: hostA)
            OrteMockURLProtocol.entferne(host: hostB)
        }

        let clientA = OrteMockURLProtocol.client(host: hostA)
        let clientB = OrteMockURLProtocol.client(host: hostB)
        let modell = PhoneOrtsModell(speicher: speicher())

        // Der Aufbau für A hängt 0,3 s in der Länderliste, wenn der Server wechselt.
        let lauf = Task { await modell.erscheint(apiClient: clientA, offline: false, jetzt: jetzt) }
        try? await Task.sleep(nanoseconds: 100_000_000)

        await mitZeitlimit {
            await modell.erscheint(apiClient: clientB, offline: false, jetzt: jetzt)
            await lauf.value
        }

        #expect(modell.katalog?.basis == clientB.baseURL.absoluteString)
        #expect(modell.katalog?.aufgebautAm != nil)
        #expect(!modell.baut)
    }

    @Test("Ein scheiternder Aufbau des alten Servers setzt beim neuen keinen Fehler")
    func fehlschlagAlterServerKeinFehlerBeimNeuen() async throws {
        let hostA = "orte-modell-fehler-a.test"
        let hostB = "orte-modell-fehler-b.test"
        OrteMockURLProtocol.registriere(host: hostA, langsamerFehlschlagenderServer())
        OrteMockURLProtocol.registriere(host: hostB, einLandServer(mitschnitt: OrteMitschnitt()))
        defer {
            OrteMockURLProtocol.entferne(host: hostA)
            OrteMockURLProtocol.entferne(host: hostB)
        }

        let clientA = OrteMockURLProtocol.client(host: hostA)
        let clientB = OrteMockURLProtocol.client(host: hostB)
        let modell = PhoneOrtsModell(speicher: speicher())

        // A scheitert erst nach 0,3 s — nach dem Serverwechsel darf der Fehler nicht
        // mehr bei B ankommen.
        let lauf = Task { await modell.erscheint(apiClient: clientA, offline: false, jetzt: jetzt) }
        try? await Task.sleep(nanoseconds: 100_000_000)

        await mitZeitlimit {
            await modell.erscheint(apiClient: clientB, offline: false, jetzt: jetzt)
            await lauf.value
        }
        await wartetAuf { modell.aufbauFehler != nil || modell.katalog != nil }

        #expect(modell.aufbauFehler == nil)
        #expect(modell.katalog?.basis == clientB.baseURL.absoluteString)
    }

    @Test("Städtezahlen eines Personendurchlaufs landen nicht im Katalog eines inzwischen anderen Servers")
    func staedtezahlenNachVerwerfenNichtImNeuenKatalog() async throws {
        // Anders als eine einfache Zählung räumt `leere()` die Auswahl **sofort** ab
        // (`facetten.leere()` erhöht die Generation synchron) — ein Test, der dort
        // ansetzt, triftt die schon vor dieser Fix-Runde vorhandene erste Wache in
        // `PhoneOrtsFacetten.laden` (vor der Personenermittlung), nie die beiden hier
        // neuen Wachen. Deshalb hier stattdessen: wenige Treffer, damit der
        // **automatische** Personendurchlauf läuft, mitten in dessen einziger (0,5 s
        // hängender) Anfrage per `erscheint` auf einen **anderen** Server wechseln —
        // mit einem echten eigenen Katalog für ihn, in den ein durchgerutschtes
        // Schreiben tatsächlich sichtbar würde (ein `katalog == nil` verdeckte den
        // Fehler sonst zufällig, weil `merkeStaedte` dann selbst nichts täte).
        let hostA = "orte-modell-personen-a.test"
        let hostB = "orte-modell-personen-b.test"
        let mitschnitt = OrteMitschnitt()
        let melder = Vollzugsmelder()
        OrteMockURLProtocol.registriere(host: hostA, personenLangsamerServer(mitschnitt: mitschnitt, melder: melder))
        defer { OrteMockURLProtocol.entferne(host: hostA) }

        let s = speicher()
        try s.speichern(katalog(basis: "https://\(hostA)", aufgebautAm: jetzt))
        let clientA = OrteMockURLProtocol.client(host: hostA)
        let clientB = OrteMockURLProtocol.client(host: hostB)
        let modell = PhoneOrtsModell(speicher: s)
        await modell.erscheint(apiClient: clientA, offline: true, jetzt: jetzt)

        // Eine reine Landauswahl (`istNurLand`) — nur die schreibt gezählte Städte in
        // den Katalog zurück.
        let lauf = Task { await modell.waehle(.land("Greece"), apiClient: clientA) }
        await wartetAuf(timeout: 5) {
            mitschnitt.alle.contains { OrteMockURLProtocol.json($0.koerper)["withPeople"] as? Bool == true }
        }

        // Jetzt, mitten in der hängenden `withPeople`-Anfrage für A, auf B wechseln.
        try s.speichern(katalog(basis: "https://\(hostB)", aufgebautAm: jetzt))
        await modell.erscheint(apiClient: clientB, offline: true, jetzt: jetzt)
        await mitZeitlimit { await lauf.value }

        // Warten, bis die verzögerte Antwort für A tatsächlich verschickt wurde, plus
        // eine kurze Gnadenfrist für den restlichen (synchronen) Abschlusscode danach.
        await wartetAuf(timeout: 5) { melder.fertig }
        try? await Task.sleep(nanoseconds: 150_000_000)

        #expect(modell.katalog?.staedteAnzahlen["Greece"] == nil)
        #expect(s.laden(basis: clientB.baseURL)?.staedteAnzahlen["Greece"] == nil)
    }

    @Test("Ein scheiternder Aufbau des alten Servers setzt keinen Fehler, auch ohne dass ein neuer Aufbau ihn nachträglich löscht")
    func fehlerAlterServerBleibtStillOhneNeuenAufbau() async throws {
        // Ergänzt `fehlschlagAlterServerKeinFehlerBeimNeuen`: Dort baut B danach
        // erfolgreich, was `aufbauFehler` ohnehin auf `nil` zurücksetzt — die Wache im
        // `catch` selbst (Serverabgleich vor dem Schreiben des Fehlers) bliebe so
        // ungeprüft. Hier bleibt B ohne eigenen Aufbau (offline, kein gespeicherter
        // Katalog): Nichts außer der Wache kann `aufbauFehler` noch auf `nil` halten.
        let hostA = "orte-modell-fehlerstill-a.test"
        let hostB = "orte-modell-fehlerstill-b.test"
        OrteMockURLProtocol.registriere(host: hostA, langsamerFehlschlagenderServer())
        defer { OrteMockURLProtocol.entferne(host: hostA) }

        let clientA = OrteMockURLProtocol.client(host: hostA)
        let clientB = OrteMockURLProtocol.client(host: hostB)
        let modell = PhoneOrtsModell(speicher: speicher())

        // A hängt 0,3 s und scheitert dann — der Wechsel passiert lange davor.
        let lauf = Task { await modell.erscheint(apiClient: clientA, offline: false, jetzt: jetzt) }
        try? await Task.sleep(nanoseconds: 100_000_000)

        await mitZeitlimit {
            await modell.erscheint(apiClient: clientB, offline: true, jetzt: jetzt)
            await lauf.value
        }
        await wartetAuf { !modell.baut }

        #expect(modell.aufbauFehler == nil)
        #expect(modell.katalog == nil)
    }

    // MARK: - Abschluss-Review

    /// Wartet, bis die Personenreihe einen Endzustand erreicht hat (nicht mehr
    /// `.keine`/`.laedt`), höchstens 5 s.
    private func wartetAufPersonen(_ modell: PhoneOrtsModell) async {
        await wartetAuf(timeout: 5) {
            switch modell.facetten.personen {
            case .keine, .laedt: false
            default: true
            }
        }
    }

    @Test("Ermittelte Personen überleben keinen Serverwechsel")
    func personenCacheNichtUeberServerwechsel() async {
        let hostA = "orte-modell-cache-a.test"
        let hostB = "orte-modell-cache-b.test"
        OrteMockURLProtocol.registriere(host: hostA, personenServer(total: 50, person: ("pa", "Anna vom Server A")))
        OrteMockURLProtocol.registriere(host: hostB, personenServer(total: 5_000, person: ("pb", "Berta vom Server B")))
        defer {
            OrteMockURLProtocol.entferne(host: hostA)
            OrteMockURLProtocol.entferne(host: hostB)
        }
        let clientA = OrteMockURLProtocol.client(host: hostA)
        let clientB = OrteMockURLProtocol.client(host: hostB)
        let modell = PhoneOrtsModell(speicher: speicher())

        await modell.erscheint(apiClient: clientA, offline: true, jetzt: jetzt)
        await modell.waehle(.land("Japan"), apiClient: clientA)
        await wartetAufPersonen(modell)
        #expect(modell.facetten.personen == .bereit([PhoneOrtsChip(id: "pa", titel: "Anna vom Server A", anzahl: 1)]))

        await modell.erscheint(apiClient: clientB, offline: true, jetzt: jetzt)
        await modell.waehle(.land("Japan"), apiClient: clientB)
        await wartetAufPersonen(modell)

        // B liegt über der Schwelle: ohne Zwischenspeicher-Treffer nur der Knopf.
        #expect(modell.facetten.personen == .aufAnfrage(megabyte: 7))
    }

    @Test("Ermittelte Personen überleben kein Abmelden")
    func personenCacheNichtUeberLeere() async {
        let host = "orte-modell-cache-abmelden.test"
        OrteMockURLProtocol.registriere(host: host, personenServer(total: 50, person: ("pa", "Anna vom Konto A")))
        defer { OrteMockURLProtocol.entferne(host: host) }
        let modell = PhoneOrtsModell(speicher: speicher())

        let clientA = OrteMockURLProtocol.client(host: host)
        await modell.erscheint(apiClient: clientA, offline: true, jetzt: jetzt)
        await modell.waehle(.land("Japan"), apiClient: clientA)
        await wartetAufPersonen(modell)
        #expect(modell.facetten.personen == .bereit([PhoneOrtsChip(id: "pa", titel: "Anna vom Konto A", anzahl: 1)]))

        // Abmelden, dasselbe Server-URL mit einem anderen Konto.
        modell.leere()
        OrteMockURLProtocol.registriere(host: host, personenServer(total: 5_000, person: ("pb", "Berta vom Konto B")))
        let clientB = OrteMockURLProtocol.client(host: host)
        await modell.erscheint(apiClient: clientB, offline: true, jetzt: jetzt)
        await modell.waehle(.land("Japan"), apiClient: clientB)
        await wartetAufPersonen(modell)

        #expect(modell.facetten.personen == .aufAnfrage(megabyte: 7))
    }

    @Test("Abmelden während eines laufenden Aufbaus: Am Ende steht der Katalog des neuen Kontos")
    func abmeldenWaehrendAufbau() async throws {
        // Dieselbe Adresse vorher und nachher — genau der Fall, in dem der
        // Serverabgleich (`apiClient.baseURL == basis`) den alten Lauf nicht mehr
        // aufhält, sobald das neue Konto erschienen ist.
        let host = "orte-modell-abmelden-aufbau.test"
        let mitschnitt = OrteMitschnitt()
        OrteMockURLProtocol.registriere(host: host, langsamerLandServer(land: "Japan", mitschnitt: mitschnitt))
        defer { OrteMockURLProtocol.entferne(host: host) }

        let s = speicher()
        let clientA = OrteMockURLProtocol.client(host: host)
        let modell = PhoneOrtsModell(speicher: s)
        let laufA = Task { await modell.erscheint(apiClient: clientA, offline: false, jetzt: jetzt) }
        // Bis die (0,3 s hängende) Länderliste von A unterwegs ist.
        await wartetAuf(timeout: 5) {
            mitschnitt.alle.contains {
                $0.request.url?.path == "/api/search/suggestions" && OrteMockURLProtocol.query($0.request, "type") == "country"
            }
        }
        #expect(modell.baut)

        modell.leere()
        // Das neue Konto sieht auf demselben Server ein anderes Land.
        OrteMockURLProtocol.registriere(host: host, schnellerLandServer(land: "Korea"))
        let clientB = OrteMockURLProtocol.client(host: host)

        await mitZeitlimit {
            await modell.erscheint(apiClient: clientB, offline: false, jetzt: jetzt)
            await laufA.value
        }
        await wartetAuf { !modell.baut }

        #expect(modell.katalog?.land("Korea") != nil)
        #expect(modell.katalog?.land("Japan") == nil)
        let gespeichert = s.laden(basis: clientB.baseURL)
        #expect(gespeichert?.land("Korea") != nil)
        #expect(gespeichert?.land("Japan") == nil)
        #expect(!modell.baut)
    }

    @Test("Neu einlesen vor dem ersten Öffnen scheitert: der gespeicherte Katalog bleibt sichtbar")
    func neuEinlesenVorErstemOeffnenLiestGespeichertenKatalog() async throws {
        let host = "orte-modell-neueinlesen-fehler.test"
        OrteMockURLProtocol.registriere(host: host) { _, _ in (500, Data()) }
        defer { OrteMockURLProtocol.entferne(host: host) }

        let s = speicher()
        try s.speichern(katalog(basis: "https://\(host)", aufgebautAm: jetzt.addingTimeInterval(-3600)))
        let client = OrteMockURLProtocol.client(host: host)
        let modell = PhoneOrtsModell(speicher: s)

        await mitZeitlimit {
            await modell.aktualisieren(apiClient: client, neuEinlesen: true, jetzt: jetzt)
        }

        #expect(modell.katalog?.land("Greece") != nil)
        #expect(modell.aufbauFehler == nil)
    }

    @Test("Zwei schnelle Chip-Tipps hintereinander: Stadt und Jahr bleiben beide gesetzt")
    func schnelleChipTippsUeberschreibenSichNicht() async {
        let client = unerreichbarerClient()
        let modell = PhoneOrtsModell(speicher: speicher())
        await modell.waehle(.land("Japan"), apiClient: client)

        // Wie aus der Ansicht: zwei unstrukturierte Tasks, beide gestartet, bevor einer
        // läuft — also bevor die Ansicht nach dem ersten Tipp neu zeichnen könnte.
        let jahr = Task { await modell.tippeJahr(PhoneOrtsChip(id: "2019", titel: "2019", anzahl: 10), apiClient: client) }
        let stadt = Task { await modell.tippeStadt(PhoneOrtsChip(id: "Tokyo", titel: "Tokyo", anzahl: 4), apiClient: client) }
        await mitZeitlimit {
            await jahr.value
            await stadt.value
        }

        #expect(modell.auswahl.stadt == "Tokyo")
        #expect(modell.auswahl.jahr == 2019)
    }
}
