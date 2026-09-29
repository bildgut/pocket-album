import Foundation
import Testing
@testable import ImmichPhone

// Befunde aus dem Verbindungs-Review (September 2026): Adressen mit „/api“,
// Kontowechsel ohne ermittelbare Kennung, kurze Fristen im Onboarding.

@Suite("ServerAdresse: abschließendes /api")
struct ServerAdresseApiEndungTests {
    @Test("„/api“ am Ende fällt weg, in jeder Schreibweise und mit Schrägstrich")
    func apiEndung() {
        let erwartet = [URL(string: "https://fotos.example.de")!]
        #expect(ServerAdresse.kandidaten(fuer: "https://fotos.example.de/api") == erwartet)
        #expect(ServerAdresse.kandidaten(fuer: "https://fotos.example.de/API/") == erwartet)
        #expect(ServerAdresse.kandidaten(fuer: "fotos.example.de:2283/Api").map(\.absoluteString)
                == ["https://fotos.example.de:2283", "http://fotos.example.de:2283"])
    }

    @Test("Ein Unterpfad vor /api bleibt erhalten, ein Host „api“ auch")
    func unterpfad() {
        #expect(ServerAdresse.kandidaten(fuer: "https://example.de/immich/api").map(\.absoluteString)
                == ["https://example.de/immich"])
        #expect(ServerAdresse.kandidaten(fuer: "https://api").map(\.absoluteString) == ["https://api"])
        #expect(ServerAdresse.kandidaten(fuer: "https://example.de/rapi").map(\.absoluteString)
                == ["https://example.de/rapi"])
    }
}

@Suite("KontoWechsel: Rückfall über die Zugangsdaten")
struct KontoWechselZugangTests {
    private let a = KontoWechsel.zugang(serverURL: "https://a.test", apiKey: "k1")

    @Test("Beide Kennungen bekannt: nur sie entscheiden")
    func kennungen() {
        let b = KontoWechsel.zugang(serverURL: "https://b.test", apiKey: "k2")
        #expect(KontoWechsel.istWechsel(bisher: "u1", neu: "u2", bisherZugang: a, neuZugang: a))
        #expect(!KontoWechsel.istWechsel(bisher: "u1", neu: "u1", bisherZugang: a, neuZugang: b))
    }

    @Test("Kennung fehlt: andere Zugangsdaten gelten als Wechsel, gleiche nicht")
    func ohneKennung() {
        let andererKey = KontoWechsel.zugang(serverURL: "https://a.test", apiKey: "k2")
        let andererServer = KontoWechsel.zugang(serverURL: "https://b.test", apiKey: "k1")
        #expect(KontoWechsel.istWechsel(bisher: "u1", neu: nil, bisherZugang: a, neuZugang: andererKey))
        #expect(KontoWechsel.istWechsel(bisher: nil, neu: nil, bisherZugang: a, neuZugang: andererServer))
        #expect(KontoWechsel.istWechsel(bisher: nil, neu: "u2", bisherZugang: a, neuZugang: andererKey))
        #expect(!KontoWechsel.istWechsel(bisher: "u1", neu: nil, bisherZugang: a, neuZugang: a))
    }

    @Test("Ohne früheren Zugang (Erstanmeldung, Update) kein Wechsel")
    func erstanmeldung() {
        #expect(!KontoWechsel.istWechsel(bisher: nil, neu: nil, bisherZugang: nil, neuZugang: a))
        #expect(!KontoWechsel.istWechsel(bisher: "u1", neu: nil, bisherZugang: nil, neuZugang: a))
    }

    @Test("Der Fingerabdruck enthält den Key nicht im Klartext")
    func keinKlartext() {
        #expect(!KontoWechsel.zugang(serverURL: "https://a.test", apiKey: "GEHEIM-123").contains("GEHEIM"))
    }
}

@Suite("ConnectionManager: Zustandsfolge beim Verbinden", .serialized)
@MainActor
struct VerbindungsZustandTests {
    private static let host = "wiederverbinden.test"

    private func registriere(verzoegerung: TimeInterval = 0.3) {
        OrteMockURLProtocol.registriere(host: Self.host, verzoegerung: verzoegerung) { r, _ in
            GespielterServer.antwort(r, extra: ["/api/albums": (200, "[]")])
        }
    }

    private func manager() -> ConnectionManager {
        let c = ConnectionManager()
        c.sitzungsKonfiguration = GespielterServer.konfiguration
        return c
    }

    /// Wartet kurz und liest dann den Zustand — mitten im gebremsten Lauf.
    private func zustandWaehrend(_ c: ConnectionManager, _ lauf: @escaping @MainActor () async -> Void) async -> (ConnectionState, ConnectionState) {
        let t = Task { await lauf() }
        try? await Task.sleep(for: .milliseconds(120))
        let mitten = c.state
        await t.value
        return (mitten, c.state)
    }

    @Test("Automatisch aus .offline: nie .connecting, danach verbunden")
    func ausOffline() async {
        registriere()
        defer { OrteMockURLProtocol.entferne(host: Self.host) }
        let c = manager()
        c.state = .offline
        let (mitten, ende) = await zustandWaehrend(c) {
            await c.connect(serverURL: "https://\(Self.host)", apiKey: "k", isAutoReconnect: true)
        }
        #expect(mitten == .offline)
        #expect(ende == .connected(version: "3.2.2"))
        c.disconnect()
    }

    @Test("Automatisch aus .connected: bleibt sichtbar verbunden")
    func ausVerbunden() async {
        registriere()
        defer { OrteMockURLProtocol.entferne(host: Self.host) }
        let c = manager()
        c.state = .connected(version: "3.2.1")
        let (mitten, ende) = await zustandWaehrend(c) {
            await c.connect(serverURL: "https://\(Self.host)", apiKey: "k", isAutoReconnect: true)
        }
        #expect(mitten == .connected(version: "3.2.1"))
        #expect(ende == .connected(version: "3.2.2"))
        c.disconnect()
    }

    @Test("Automatisch aus .offline, Server weg: bleibt .offline")
    func ausOfflineGescheitert() async {
        let c = manager()
        c.state = .offline
        await c.connect(serverURL: "https://niemand-da.test", apiKey: "k", isAutoReconnect: true)
        #expect(c.state == .offline)
    }

    @Test("Manuell: sichtbar .connecting")
    func manuell() async {
        registriere()
        defer { OrteMockURLProtocol.entferne(host: Self.host) }
        let c = manager()
        let (mitten, ende) = await zustandWaehrend(c) {
            await c.connect(serverURL: "https://\(Self.host)", apiKey: "k")
        }
        #expect(mitten == .connecting)
        #expect(ende == .connected(version: "3.2.2"))
        c.disconnect()
    }

    @Test("Kaltstart mit Cache: sofort .offline, danach verbunden")
    func kaltstartMitCache() async {
        registriere()
        defer {
            OrteMockURLProtocol.entferne(host: Self.host)
            AppEnvironment.defaults.removeObject(forKey: "hasCachedAlbums")
        }
        KeychainStore.save(key: "serverURL", value: "https://\(Self.host)")
        KeychainStore.save(key: "apiKey", value: "k")
        AppEnvironment.defaults.set(true, forKey: "hasCachedAlbums")
        let c = manager()
        c.sofortOfflineBeimKaltstart = true
        let (mitten, ende) = await zustandWaehrend(c) {
            await c.connect(serverURL: "https://\(Self.host)", apiKey: "k", isAutoReconnect: true)
        }
        #expect(mitten == .offline)
        #expect(ende == .connected(version: "3.2.2"))
        c.disconnect()
    }

    @Test("HTML mit 200 auf den Ping heißt „kein Immich“")
    func htmlAntwort() async {
        OrteMockURLProtocol.registriere(host: Self.host) { _, _ in (200, Data("<html></html>".utf8)) }
        defer { OrteMockURLProtocol.entferne(host: Self.host) }
        let c = manager()
        await c.connect(serverURL: "https://\(Self.host)", apiKey: "k")
        #expect(c.state == .error(APIError.keinImmich.errorDescription!))
    }
}

@Suite("PhoneEinrichtung: Fehlerbilder der Prüfung", .serialized)
@MainActor
struct PhoneEinrichtungFehlerbildTests {
    private static let host = "einrichtung-fehlerbild.test"

    @Test("502 des Proxys heißt „nicht erreichbar“, nicht „kein Immich“")
    func proxyFehler() async {
        OrteMockURLProtocol.registriere(host: Self.host) { _, _ in (502, Data("<html>Bad Gateway</html>".utf8)) }
        defer { OrteMockURLProtocol.entferne(host: Self.host) }
        let m = PhoneEinrichtung(mitVorspann: false, konfiguration: GespielterServer.konfiguration, verzoegerung: .zero)
        await m.pruefeServer(Self.host)
        #expect(m.server == .nichtErreichbar)
    }

    @Test("Wahl nach Kandidaten-Reihenfolge, Befund vor „kein Immich“ vor „nicht erreichbar“")
    func wahl() {
        let url = URL(string: "https://x.test")!
        let v = ImmichVersion("3.2.2")!
        #expect(PhoneEinrichtung.waehle([(.nichtErreichbar, true), (.gefunden(url, v), false)]).0 == .gefunden(url, v))
        #expect(PhoneEinrichtung.waehle([(.gefunden(url, v), true), (.keinImmich, true)]).0 == .gefunden(url, v))
        #expect(PhoneEinrichtung.waehle([(.nichtErreichbar, true), (.keinImmich, true)]).0 == .keinImmich)
        #expect(PhoneEinrichtung.waehle([(.nichtErreichbar, true), (.nichtErreichbar, true)]).0 == .nichtErreichbar)
    }

    @Test("Key-Prüfung: Weiterleitung und Serverfehler bekommen eigene Meldungen")
    func keyMeldungen() async {
        for (status, text) in [(302, OnboardingTexts.keyProxyAnmeldung), (502, OnboardingTexts.keyServerFehler)] {
            OrteMockURLProtocol.registriere(host: Self.host) { r, _ in
                GespielterServer.antwort(r, extra: ["/api/albums": (status, "")])
            }
            let m = PhoneEinrichtung(mitVorspann: false, konfiguration: GespielterServer.konfiguration, verzoegerung: .zero)
            await m.pruefeServer(Self.host)
            await m.pruefeKey("KEY")
            #expect(m.key == .fehler(text))
            #expect(!m.kannVerbinden)
            OrteMockURLProtocol.entferne(host: Self.host)
        }
    }
}
