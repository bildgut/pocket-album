import Foundation
import Testing
@testable import ImmichPhone

/// Antworten eines gespielten Immich-Servers, je Pfad.
enum GespielterServer {
    static func antwort(_ request: URLRequest, version: String = #"{"major":3,"minor":2,"patch":2}"#,
                        extra: [String: (Int, String)] = [:]) -> (Int, Data) {
        let pfad = request.url?.path ?? ""
        if let (status, text) = extra[pfad] { return (status, Data(text.utf8)) }
        switch pfad {
        case "/api/server/ping": return (200, Data(#"{"res":"pong"}"#.utf8))
        case "/api/server/version": return (200, Data(version.utf8))
        case "/api/server/features": return (200, Data(#"{"passwordLogin":true}"#.utf8))
        default: return (404, Data())
        }
    }

    static var konfiguration: URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [OrteMockURLProtocol.self]
        return config
    }
}

@Suite("PhoneEinrichtung: Server", .serialized)
@MainActor
struct PhoneEinrichtungServerTests {
    private static let host = "einrichtung-server.test"
    private static let langsam = "einrichtung-langsam.test"

    private func modell() -> PhoneEinrichtung {
        PhoneEinrichtung(mitVorspann: false, konfiguration: GespielterServer.konfiguration, verzoegerung: .zero)
    }

    @Test("Ein aktueller Immich wird gefunden, https zuerst")
    func gefunden() async {
        OrteMockURLProtocol.registriere(host: Self.host) { r, _ in GespielterServer.antwort(r) }
        defer { OrteMockURLProtocol.entferne(host: Self.host) }
        let m = modell()
        await m.pruefeServer(Self.host)
        #expect(m.server == .gefunden(URL(string: "https://\(Self.host)")!, ImmichVersion("3.2.2")!))
        #expect(m.serverURL?.scheme == "https")
    }

    @Test("Nur per http erreichbar: http wird gefunden")
    func nurHttp() async {
        OrteMockURLProtocol.registriere(host: Self.host) { r, _ in
            r.url?.scheme == "https" ? (503, Data()) : GespielterServer.antwort(r)
        }
        defer { OrteMockURLProtocol.entferne(host: Self.host) }
        let m = modell()
        await m.pruefeServer(Self.host)
        #expect(m.serverURL?.scheme == "http")
    }

    @Test("Zu alt wird benannt")
    func zuAlt() async {
        OrteMockURLProtocol.registriere(host: Self.host) { r, _ in
            GespielterServer.antwort(r, version: #"{"major":3,"minor":1,"patch":0}"#)
        }
        defer { OrteMockURLProtocol.entferne(host: Self.host) }
        let m = modell()
        await m.pruefeServer("https://\(Self.host)")
        #expect(m.server == .zuAlt(ImmichVersion("3.1.0")!))
        #expect(m.serverURL == nil)
    }

    @Test("Antwortet, ist aber kein Immich")
    func keinImmich() async {
        OrteMockURLProtocol.registriere(host: Self.host) { _, _ in (200, Data("<html>".utf8)) }
        defer { OrteMockURLProtocol.entferne(host: Self.host) }
        let m = modell()
        await m.pruefeServer("https://\(Self.host)")
        #expect(m.server == .keinImmich)
    }

    @Test("Nicht erreichbar")
    func nichtErreichbar() async {
        let m = modell()
        await m.pruefeServer("niemand-da.test")
        #expect(m.server == .nichtErreichbar)
    }

    @Test("Leere Eingabe setzt zurück")
    func leer() async {
        let m = modell()
        await m.pruefeServer("  ")
        #expect(m.server == .leer)
    }

    @Test("SSO-Server: Passwort-Login gilt als abgeschaltet")
    func sso() async {
        OrteMockURLProtocol.registriere(host: Self.host) { r, _ in
            GespielterServer.antwort(r, extra: ["/api/server/features": (200, #"{"passwordLogin":false}"#)])
        }
        defer { OrteMockURLProtocol.entferne(host: Self.host) }
        let m = modell()
        await m.pruefeServer(Self.host)
        #expect(m.passwortLoginErlaubt == false)
    }

    @Test("Ein überholter Lauf überschreibt kein neueres Ergebnis")
    func ueberholt() async {
        OrteMockURLProtocol.registriere(host: Self.host) { r, _ in GespielterServer.antwort(r) }
        // Der alte Lauf trifft einen Server, der langsam antwortet und zu alt ist.
        OrteMockURLProtocol.registriere(host: Self.langsam, verzoegerung: 0.4) { r, _ in
            GespielterServer.antwort(r, version: #"{"major":3,"minor":0,"patch":0}"#)
        }
        defer {
            OrteMockURLProtocol.entferne(host: Self.host)
            OrteMockURLProtocol.entferne(host: Self.langsam)
        }
        let m = modell()
        let alt = Task { await m.pruefeServer("https://\(Self.langsam)") }
        while m.server != .prueft { await Task.yield() }
        await m.pruefeServer(Self.host)
        await alt.value
        #expect(m.serverURL?.host() == Self.host)
    }
}

/// Antwort von `GET /api/api-keys/me` mit den genannten Rechten.
func keyMeJSON(_ rechte: [String]) -> String {
    let liste = rechte.map { "\"\($0)\"" }.joined(separator: ",")
    return #"{"id":"00000000-0000-4000-8000-000000000000","name":"k","createdAt":"2026-01-01T00:00:00.000Z","updatedAt":"2026-01-01T00:00:00.000Z","permissions":[\#(liste)]}"#
}

@Suite("PhoneEinrichtung: Key", .serialized)
@MainActor
struct PhoneEinrichtungKeyTests {
    private static let host = "einrichtung-key.test"

    private func verbundenesModell(extra: [String: (Int, String)]) async -> PhoneEinrichtung {
        OrteMockURLProtocol.registriere(host: Self.host) { r, _ in GespielterServer.antwort(r, extra: extra) }
        let m = PhoneEinrichtung(mitVorspann: false, konfiguration: GespielterServer.konfiguration, verzoegerung: .zero)
        await m.pruefeServer(Self.host)
        return m
    }

    @Test("Gültiger Key: Rechte vom Server, getrimmt übernommen")
    func gueltig() async {
        defer { OrteMockURLProtocol.entferne(host: Self.host) }
        let m = await verbundenesModell(extra: [
            "/api/albums": (200, "[]"),
            "/api/api-keys/me": (200, keyMeJSON(["album.read", "asset.read"])),
        ])
        await m.pruefeKey("  KEY-1\n")
        #expect(m.key == .gueltig(KeyRechte(gemeldet: ["album.read", "asset.read"])))
        #expect(m.gepruefterKey == "KEY-1")
        #expect(m.kannVerbinden)
    }

    @Test("401 = abgelehnt, 403 = album.read fehlt")
    func abgelehnt() async {
        defer { OrteMockURLProtocol.entferne(host: Self.host) }
        let m = await verbundenesModell(extra: ["/api/albums": (401, "")])
        await m.pruefeKey("FALSCH")
        #expect(m.key == .abgelehnt)
        #expect(!m.kannVerbinden)

        OrteMockURLProtocol.registriere(host: Self.host) { r, _ in GespielterServer.antwort(r, extra: ["/api/albums": (403, "")]) }
        await m.pruefeKey("OHNE-RECHT")
        #expect(m.key == .ohneAlbumRecht)
    }

    @Test("Leerer Key setzt zurück")
    func leer() async {
        defer { OrteMockURLProtocol.entferne(host: Self.host) }
        let m = await verbundenesModell(extra: [:])
        await m.pruefeKey(" \n")
        #expect(m.key == .leer)
    }

    @Test("Umfang bestimmt die Rechte-Liste")
    func umfang() {
        #expect(PhoneEinrichtung.Umfang.nurAnsehen.rechte == ["album.read", "asset.read", "asset.view", "asset.download", "asset.statistics", "person.read"])
        #expect(PhoneEinrichtung.Umfang.voll.rechte == ["album.read", "asset.read", "asset.view", "asset.download", "asset.statistics", "person.read", "asset.update", "asset.delete"])
    }
}

@Suite("PhoneEinrichtung: Anmelden", .serialized)
@MainActor
struct PhoneEinrichtungAnmeldenTests {
    private static let host = "einrichtung-login.test"
    private static let passwort = "Geheim-Passwort-42!"

    private func modell(keyAnlage: (Int, String), mitschnitt: OrteMitschnitt) async -> PhoneEinrichtung {
        OrteMockURLProtocol.registriere(host: Self.host) { r, k in
            mitschnitt.merke(r, k)
            if r.url?.path == "/api/api-keys", r.httpMethod == "POST" { return (keyAnlage.0, Data(keyAnlage.1.utf8)) }
            return GespielterServer.antwort(r, extra: [
                "/api/auth/login": (201, #"{"accessToken":"SESSION","userId":"u","userEmail":"a@b.c","name":"A"}"#),
                "/api/auth/logout": (200, "{}"),
                "/api/albums": (200, "[]"),
                "/api/api-keys/me": (200, keyMeJSON(["all"])),
            ])
        }
        let m = PhoneEinrichtung(mitVorspann: false, konfiguration: GespielterServer.konfiguration, verzoegerung: .zero)
        await m.pruefeServer(Self.host)
        m.schritt = .anmelden
        return m
    }

    @Test("Login → Key mit gewähltem Umfang → Logout → Key geprüft")
    func erfolg() async throws {
        defer { OrteMockURLProtocol.entferne(host: Self.host) }
        let mitschnitt = OrteMitschnitt()
        let m = await modell(keyAnlage: (201, #"{"secret":"NEUER-KEY","apiKey":{}}"#), mitschnitt: mitschnitt)
        m.umfang = .nurAnsehen

        await m.meldeAn(email: "a@b.c", passwort: Self.passwort, geraet: "iPhone")

        #expect(m.gepruefterKey == "NEUER-KEY")
        #expect(m.kannVerbinden)
        #expect(m.schritt == .key)
        #expect(m.anmeldeFehler == nil)
        #expect(mitschnitt.alle.contains { $0.request.url?.path == "/api/auth/logout" })
        let anlage = try #require(mitschnitt.alle.first { $0.request.url?.path == "/api/api-keys" && $0.request.httpMethod == "POST" })
        #expect(OrteMockURLProtocol.json(anlage.koerper)["permissions"] as? [String] == PhoneEinrichtung.Umfang.nurAnsehen.rechte)
        #expect(OrteMockURLProtocol.json(anlage.koerper)["name"] as? String == "Pocket Album (iPhone)")
    }

    @Test("Das Passwort geht nur an den Login und wird nirgends gespeichert")
    func passwortNurImLogin() async {
        defer { OrteMockURLProtocol.entferne(host: Self.host) }
        let mitschnitt = OrteMitschnitt()
        let m = await modell(keyAnlage: (201, #"{"secret":"K","apiKey":{}}"#), mitschnitt: mitschnitt)
        await m.meldeAn(email: "a@b.c", passwort: Self.passwort, geraet: "iPhone")

        #expect(mitschnitt.alle.contains { $0.request.url?.path == "/api/auth/login" })
        for eintrag in mitschnitt.alle where eintrag.request.url?.path != "/api/auth/login" {
            #expect(!String(decoding: eintrag.koerper, as: UTF8.self).contains(Self.passwort))
            #expect(!(eintrag.request.allHTTPHeaderFields ?? [:]).values.contains { $0.contains(Self.passwort) })
        }
        #expect(!AppEnvironment.defaults.dictionaryRepresentation().description.contains(Self.passwort))
        #expect(KeychainStore.read(key: "password") != Self.passwort)
        let spiegel = Mirror(reflecting: m).children.map { String(describing: $0.value) }.joined()
        #expect(!spiegel.contains(Self.passwort))
    }

    @Test("Key-Anlage scheitert: Fehler, trotzdem abgemeldet, kein Key")
    func anlageScheitert() async {
        defer { OrteMockURLProtocol.entferne(host: Self.host) }
        let mitschnitt = OrteMitschnitt()
        let m = await modell(keyAnlage: (500, ""), mitschnitt: mitschnitt)
        await m.meldeAn(email: "a@b.c", passwort: Self.passwort, geraet: "iPhone")
        #expect(m.anmeldeFehler != nil)
        #expect(!m.kannVerbinden)
        #expect(m.schritt == .anmelden)
        #expect(mitschnitt.alle.contains { $0.request.url?.path == "/api/auth/logout" })
    }

    @Test("Falsches Passwort")
    func falschesPasswort() async {
        defer { OrteMockURLProtocol.entferne(host: Self.host) }
        OrteMockURLProtocol.registriere(host: Self.host) { r, _ in
            GespielterServer.antwort(r, extra: ["/api/auth/login": (401, "{}")])
        }
        let m = PhoneEinrichtung(mitVorspann: false, konfiguration: GespielterServer.konfiguration, verzoegerung: .zero)
        await m.pruefeServer(Self.host)
        await m.meldeAn(email: "a@b.c", passwort: "falsch", geraet: "iPhone")
        #expect(m.anmeldeFehler == OnboardingTexts.falschesPasswort)
    }
}

@Suite("PhoneEinrichtung: Fertig", .serialized)
@MainActor
struct PhoneEinrichtungFertigTests {
    private static let host = "einrichtung-fertig.test"

    @Test("Zählt Alben und Fotos und lädt bis zu sechs Titelbilder mit dem Key")
    func zusammenfassung() async throws {
        let mitschnitt = OrteMitschnitt()
        let alben = (1...8).map { i in
            #"{"id":"a\#(i)","albumName":"A\#(i)","createdAt":"2026-01-01T00:00:00.000Z","updatedAt":"2026-01-01T00:00:00.000Z","assetCount":1,"albumThumbnailAssetId":"t\#(i)"}"#
        }.joined(separator: ",")
        OrteMockURLProtocol.registriere(host: Self.host) { r, k in
            mitschnitt.merke(r, k)
            if r.url?.path.hasSuffix("/thumbnail") == true { return (200, Data([0xFF, 0xD8])) }
            return GespielterServer.antwort(r, extra: [
                "/api/albums": (200, "[\(alben)]"),
                "/api/api-keys/me": (200, keyMeJSON(["all"])),
                "/api/search/statistics": (200, #"{"total":18346}"#),
            ])
        }
        defer { OrteMockURLProtocol.entferne(host: Self.host) }
        let m = PhoneEinrichtung(mitVorspann: false, konfiguration: GespielterServer.konfiguration, verzoegerung: .zero)
        await m.pruefeServer(Self.host)
        await m.pruefeKey("KEY")

        await m.weiterZuFertig()

        #expect(m.schritt == .fertig)
        let z = try #require(m.zusammenfassung)
        #expect(z.alben == 8)
        #expect(z.fotos == 18346)
        #expect(z.titelbilder.count == 6)
        let bildAnfragen = mitschnitt.alle.filter { $0.request.url?.path.hasSuffix("/thumbnail") == true }
        #expect(bildAnfragen.count == 6)
        #expect(bildAnfragen.allSatisfy { $0.request.value(forHTTPHeaderField: "x-api-key") == "KEY" })
    }

    @Test("Ohne gültigen Key bleibt es beim Schritt")
    func ohneKey() async {
        let m = PhoneEinrichtung(mitVorspann: false, konfiguration: GespielterServer.konfiguration, verzoegerung: .zero)
        m.schritt = .key
        await m.weiterZuFertig()
        #expect(m.schritt == .key)
        #expect(m.zusammenfassung == nil)
    }
}

@Suite("PhoneEinrichtung: Befunde der Abschlussprüfung", .serialized)
@MainActor
struct PhoneEinrichtungBefundTests {
    private static let host = "einrichtung-befund.test"

    @Test("Ein alter Key-Lauf überschreibt kein neueres Ergebnis")
    func keyUeberholt() async {
        OrteMockURLProtocol.registriere(host: Self.host, verzoegerung: 0.3) { r, _ in
            GespielterServer.antwort(r, extra: [
                "/api/albums": (200, "[]"),
                "/api/api-keys/me": (200, keyMeJSON(["all"])),
            ])
        }
        defer { OrteMockURLProtocol.entferne(host: Self.host) }
        let m = PhoneEinrichtung(mitVorspann: false, konfiguration: GespielterServer.konfiguration, verzoegerung: .zero)
        await m.pruefeServer(Self.host)
        let alt = Task { await m.pruefeKey("KEY-A") }
        while m.key != .prueft { await Task.yield() }
        await m.pruefeKey("")          // Feld geleert, während A noch läuft
        await alt.value
        #expect(m.key == .leer)
        #expect(m.gepruefterKey.isEmpty)
        #expect(!m.kannVerbinden)
    }

    @Test("Eine geänderte Adresse sperrt „Weiter“ sofort, nicht erst nach der Wartezeit")
    func adresseGeaendert() async {
        OrteMockURLProtocol.registriere(host: Self.host) { r, _ in GespielterServer.antwort(r) }
        defer { OrteMockURLProtocol.entferne(host: Self.host) }
        let m = PhoneEinrichtung(mitVorspann: false, konfiguration: GespielterServer.konfiguration, verzoegerung: .seconds(60))
        await m.pruefeServer(Self.host)
        #expect(m.serverURL != nil)
        m.serverEingabeGeaendert("anderer-server.test")
        #expect(m.serverURL == nil)
        #expect(m.server == .prueft)
        m.serverEingabeGeaendert("  ")
        #expect(m.server == .leer)
    }
}

@Suite("PhoneRootWeiche")
struct PhoneRootWeicheTests {
    @Test("Verbindet das Onboarding (noch nicht konfiguriert), bleibt das Onboarding stehen")
    func onboardingVerbindet() {
        #expect(PhoneRootWeiche.zweig(state: .connecting, istKonfiguriert: false, bereit: false) == .einrichtung)
    }

    @Test("Scheitert das Verbinden, bleibt das Onboarding stehen")
    func onboardingFehler() {
        #expect(PhoneRootWeiche.zweig(state: .error("x"), istKonfiguriert: false, bereit: false) == .einrichtung)
    }

    @Test("Wiederverbinden mit gespeicherten Zugangsdaten zeigt „Verbinde…“")
    func wiederverbinden() {
        #expect(PhoneRootWeiche.zweig(state: .connecting, istKonfiguriert: true, bereit: false) == .verbindet)
    }

    @Test("Verbunden, aber Alben noch nicht aufgebaut: „Verbinde…“; danach Inhalt")
    func verbunden() {
        #expect(PhoneRootWeiche.zweig(state: .connected(version: "3.2.2"), istKonfiguriert: true, bereit: false) == .verbindet)
        #expect(PhoneRootWeiche.zweig(state: .connected(version: "3.2.2"), istKonfiguriert: true, bereit: true) == .inhalt)
        #expect(PhoneRootWeiche.zweig(state: .offline, istKonfiguriert: true, bereit: true) == .inhalt)
    }

    @Test("Gespeicherte Zugangsdaten, Server weg: „nicht erreichbar“")
    func unerreichbar() {
        #expect(PhoneRootWeiche.zweig(state: .error("x"), istKonfiguriert: true, bereit: false) == .unerreichbar)
        #expect(PhoneRootWeiche.zweig(state: .disconnected, istKonfiguriert: true, bereit: false) == .unerreichbar)
    }
}

@Suite("PhoneEinrichtung: Nachträge", .serialized)
@MainActor
struct PhoneEinrichtungNachtragTests {
    private static let host = "einrichtung-nachtrag.test"

    private func modell(extra: [String: (Int, String)], mitschnitt: OrteMitschnitt = OrteMitschnitt()) async -> PhoneEinrichtung {
        OrteMockURLProtocol.registriere(host: Self.host) { r, k in
            mitschnitt.merke(r, k)
            if r.url?.path == "/api/api-keys", r.httpMethod == "POST" { return (201, Data(#"{"secret":"K","apiKey":{}}"#.utf8)) }
            return GespielterServer.antwort(r, extra: extra)
        }
        let m = PhoneEinrichtung(mitVorspann: false, konfiguration: GespielterServer.konfiguration, verzoegerung: .zero)
        await m.pruefeServer(Self.host)
        return m
    }

    @Test("Die E-Mail geht getrimmt an den Login")
    func emailGetrimmt() async throws {
        defer { OrteMockURLProtocol.entferne(host: Self.host) }
        let mitschnitt = OrteMitschnitt()
        let m = await modell(extra: [
            "/api/auth/login": (201, #"{"accessToken":"S","userId":"u","userEmail":"a@b.c","name":"A"}"#),
            "/api/auth/logout": (200, "{}"),
            "/api/albums": (200, "[]"),
            "/api/api-keys/me": (200, keyMeJSON(["all"])),
        ], mitschnitt: mitschnitt)
        await m.meldeAn(email: "  a@b.c \n", passwort: "p", geraet: "iPhone")
        let login = try #require(mitschnitt.alle.first { $0.request.url?.path == "/api/auth/login" })
        #expect(OrteMockURLProtocol.json(login.koerper)["email"] as? String == "a@b.c")
    }

    @Test("Scheitert die Albumliste, gibt es keine erfundene „0 Alben“-Zeile")
    func albenFehler() async throws {
        defer { OrteMockURLProtocol.entferne(host: Self.host) }
        let m = await modell(extra: [
            "/api/api-keys/me": (200, keyMeJSON(["all"])),
            "/api/search/statistics": (200, #"{"total":5}"#),
        ])
        // Die Key-Prüfung braucht 200 auf /api/albums, die Zusammenfassung scheitert danach.
        OrteMockURLProtocol.registriere(host: Self.host) { r, _ in
            GespielterServer.antwort(r, extra: ["/api/albums": (200, "[]"), "/api/api-keys/me": (200, keyMeJSON(["all"]))])
        }
        await m.pruefeKey("KEY")
        OrteMockURLProtocol.registriere(host: Self.host) { r, _ in
            GespielterServer.antwort(r, extra: ["/api/albums": (500, ""), "/api/search/statistics": (200, #"{"total":5}"#)])
        }
        await m.weiterZuFertig()
        let z = try #require(m.zusammenfassung)
        #expect(z.alben == nil)
        #expect(OnboardingTexts.fertigZahlen(alben: z.alben, fotos: z.fotos) == nil)
    }

    @Test("Ein anderer Server verwirft den geprüften Key")
    func keyBeiServerwechsel() async {
        defer { OrteMockURLProtocol.entferne(host: Self.host) }
        let m = await modell(extra: ["/api/albums": (200, "[]"), "/api/api-keys/me": (200, keyMeJSON(["all"]))])
        await m.pruefeKey("KEY")
        #expect(m.kannVerbinden)
        m.serverEingabeGeaendert("anderer.test")
        #expect(m.key == .leer)
        #expect(m.gepruefterKey.isEmpty)
    }
}

@Suite("PhoneEinrichtung: Einfügen", .serialized)
@MainActor
struct PhoneEinrichtungEinfuegenTests {
    private static let host = "einrichtung-einfuegen.test"

    @Test("Eingefügt wird sofort geprüft, ohne die Wartezeit")
    func sofort() async throws {
        let mitschnitt = OrteMitschnitt()
        OrteMockURLProtocol.registriere(host: Self.host) { r, k in
            mitschnitt.merke(r, k)
            return GespielterServer.antwort(r)
        }
        defer { OrteMockURLProtocol.entferne(host: Self.host) }
        // Wartezeit 60 s: Käme die Prüfung erst danach, liefe dieser Test in die Frist.
        let m = PhoneEinrichtung(mitVorspann: false, konfiguration: GespielterServer.konfiguration, verzoegerung: .seconds(60))
        m.serverEingefuegt("https://\(Self.host)")
        let frist = ContinuousClock.now + .seconds(5)
        while m.serverURL == nil, ContinuousClock.now < frist { try await Task.sleep(for: .milliseconds(20)) }
        #expect(m.serverURL?.host() == Self.host)
        // Genau eine Prüfung (ping, version, features) — keine zweite hinterher.
        #expect(mitschnitt.alle.filter { $0.request.url?.path == "/api/server/ping" }.count == 1)
    }
}
