import Foundation
import Observation

/// Zustand und Logik des Onboardings — ohne SwiftUI, damit alles ohne Oberfläche
/// prüfbar ist. Die Ansichten unter `Onboarding/` lesen nur und rufen Methoden.
///
/// Zugangsdaten verlassen dieses Modell erst in ``verbinde(mit:)``: Bis dahin prüft
/// es mit eigenen, kurzlebigen `ImmichAPIClient`s.
@Observable
@MainActor
final class PhoneEinrichtung {

    enum Schritt: Equatable { case vorspann, server, key, anmelden, fertig }

    enum ServerStand: Equatable {
        case leer, prueft
        case gefunden(URL, ImmichVersion)
        case zuAlt(ImmichVersion)
        case keinImmich, nichtErreichbar
    }

    var schritt: Schritt
    private(set) var server: ServerStand = .leer
    /// `false` bei reinen SSO-Servern — dann gibt es keinen Anmeldelink.
    private(set) var passwortLoginErlaubt = true

    let konfiguration: URLSessionConfiguration
    private let verzoegerung: Duration
    private var serverLauf = 0
    private var serverAufgabe: Task<Void, Never>?

    init(mitVorspann: Bool,
         konfiguration: URLSessionConfiguration = .default,
         verzoegerung: Duration = .milliseconds(600)) {
        self.schritt = mitVorspann ? .vorspann : .server
        self.konfiguration = konfiguration
        self.verzoegerung = verzoegerung
    }

    var serverURL: URL? {
        if case .gefunden(let url, _) = server { return url }
        return nil
    }

    /// Beim Tippen: wartet `verzoegerung` ab, ein neuer Tastendruck bricht ab.
    func serverEingabeGeaendert(_ text: String) {
        serverAufgabe?.cancel()
        // Sofort, nicht erst nach der Wartezeit: Sonst bliebe „Weiter“ mit der
        // alten Adresse aktiv. Die Laufnummer entwertet zugleich einen laufenden
        // älteren Lauf.
        serverLauf += 1
        server = ServerAdresse.kandidaten(fuer: text).isEmpty ? .leer : .prueft
        vergissKey()
        serverAufgabe = Task { [verzoegerung] in
            try? await Task.sleep(for: verzoegerung)
            guard !Task.isCancelled else { return }
            await self.pruefeServer(text)
        }
    }

    /// Aus „Einfügen“: sofort prüfen. Die Wartezeit ist nur fürs Tippen da, wo
    /// jede Taste eine halbe Adresse ergibt.
    func serverEingefuegt(_ text: String) {
        serverEingabeGeaendert(text)
        serverAufgabe?.cancel()
        serverAufgabe = Task { await self.pruefeServer(text) }
    }

    /// Versucht die Kandidaten der Reihe nach. Nur der **jüngste** Lauf schreibt
    /// sein Ergebnis — ein langsamer alter darf ein neueres nicht überschreiben.
    func pruefeServer(_ text: String) async {
        serverLauf += 1
        let lauf = serverLauf
        let kandidaten = ServerAdresse.kandidaten(fuer: text)
        guard !kandidaten.isEmpty else { server = .leer; return }
        server = .prueft

        var ergebnis: ServerStand = .nichtErreichbar
        var loginErlaubt = true
        for url in kandidaten {
            let client = ImmichAPIClient(baseURL: url, apiKey: "", sessionConfiguration: konfiguration)
            do {
                guard try await client.ping(),
                      let version = ImmichVersion(try await client.getServerVersion())
                else { ergebnis = .keinImmich; continue }
                if version < .mindestens { ergebnis = .zuAlt(version); break }
                loginErlaubt = (try? await client.passwortLoginErlaubt()) ?? true
                ergebnis = .gefunden(url, version)
                break
            } catch is DecodingError {
                ergebnis = .keinImmich
            } catch {
                // Netzfehler: nächsten Kandidaten versuchen.
            }
        }
        guard lauf == serverLauf else { return }
        server = ergebnis
        passwortLoginErlaubt = loginErlaubt
    }

    // MARK: - Key

    enum KeyStand: Equatable {
        case leer, prueft
        case gueltig(KeyRechte)
        case abgelehnt, ohneAlbumRecht
        case fehler(String)
    }

    /// Was der Key darf, den das Hilfe-Blatt empfiehlt bzw. die Anmeldung anlegt.
    enum Umfang: CaseIterable {
        case nurAnsehen, voll
        var rechte: [String] {
            let lesen = ["album.read", "asset.read", "asset.view", "asset.download", "asset.statistics", "person.read"]
            return self == .voll ? lesen + [KeyRechte.favorit, KeyRechte.loeschen] : lesen
        }
    }

    private(set) var key: KeyStand = .leer
    var umfang: Umfang = .voll
    /// Der zuletzt **erfolgreich** geprüfte Key, getrimmt.
    private(set) var gepruefterKey = ""
    private var keyLauf = 0

    /// Ein Key gehört zu genau einem Server: Ändert sich die Adresse, gilt er nicht mehr.
    private func vergissKey() {
        keyLauf += 1
        key = .leer
        gepruefterKey = ""
    }

    var kannVerbinden: Bool {
        if case .gueltig = key { return serverURL != nil }
        return false
    }

    /// Wie bei der Server-Prüfung schreibt nur der **jüngste** Lauf: Das Feld
    /// ändert sich bei jedem Tastendruck, und ein langsamer alter Lauf dürfte sonst
    /// einen anderen Key speichern als den, der im Feld steht.
    func pruefeKey(_ text: String) async {
        keyLauf += 1
        let lauf = keyLauf
        let eingabe = text.trimmingCharacters(in: .whitespacesAndNewlines)
        gepruefterKey = ""
        guard let url = serverURL, !eingabe.isEmpty else { key = .leer; return }
        key = .prueft
        let client = ImmichAPIClient(baseURL: url, apiKey: eingabe, sessionConfiguration: konfiguration)
        let ergebnis: KeyStand
        do {
            try await client.pruefeSchluessel()
            var rechte = KeyRechte()
            if let gemeldet = try? await client.eigeneKeyRechte() { rechte.uebernimmMeldung(gemeldet) }
            ergebnis = .gueltig(rechte)
        } catch APIError.apiKeyRejected {
            ergebnis = .abgelehnt
        } catch APIError.apiKeyLacksPermission {
            ergebnis = .ohneAlbumRecht
        } catch {
            ergebnis = .fehler(error.localizedDescription)
        }
        guard lauf == keyLauf else { return }
        key = ergebnis
        if case .gueltig = ergebnis { gepruefterKey = eingabe }
    }

    // MARK: - Anmelden

    private(set) var anmeldungLaeuft = false
    private(set) var anmeldeFehler: String?

    /// Meldet sich einmal an, legt einen Key mit ``umfang`` an, meldet sich wieder ab
    /// und prüft den neuen Key wie einen eingefügten. Das Passwort ist nur Parameter:
    /// Es wird nirgends gespeichert und geht nur an `POST /api/auth/login`.
    func meldeAn(email: String, passwort: String, geraet: String) async {
        guard let url = serverURL, !anmeldungLaeuft else { return }
        anmeldungLaeuft = true
        anmeldeFehler = nil
        defer { anmeldungLaeuft = false }

        let token: String
        do {
            token = try await ImmichAPIClient.login(
                baseURL: url, email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                password: passwort, sessionConfiguration: konfiguration
            ).accessToken
        } catch APIError.loginFailed {
            anmeldeFehler = OnboardingTexts.falschesPasswort
            return
        } catch {
            anmeldeFehler = error.localizedDescription
            return
        }

        let neuerKey: String
        do {
            neuerKey = try await ImmichAPIClient.erstelleApiKey(
                baseURL: url, sessionToken: token, name: "Pocket Album (\(geraet))",
                rechte: umfang.rechte, sessionConfiguration: konfiguration
            )
        } catch {
            await ImmichAPIClient.logout(baseURL: url, sessionToken: token, sessionConfiguration: konfiguration)
            anmeldeFehler = OnboardingTexts.keyAnlageGescheitert(error.localizedDescription)
            return
        }
        await ImmichAPIClient.logout(baseURL: url, sessionToken: token, sessionConfiguration: konfiguration)
        await pruefeKey(neuerKey)
        if kannVerbinden { schritt = .key }
    }

    // MARK: - Fertig

    struct Zusammenfassung: Equatable {
        /// `nil`, wenn die Albumliste scheiterte — dann keine erfundene „0 Alben“.
        let alben: Int?
        /// `nil`, wenn der Key `asset.statistics` nicht hat — dann entfällt die Zahl.
        let fotos: Int?
        /// Rohdaten der Titelbilder; Nukes Pipeline hat vor dem Verbinden noch keinen Key.
        let titelbilder: [Data]
    }

    private(set) var zusammenfassung: Zusammenfassung?

    func weiterZuFertig() async {
        guard kannVerbinden, let url = serverURL else { return }
        schritt = .fertig
        let client = ImmichAPIClient(baseURL: url, apiKey: gepruefterKey, sessionConfiguration: konfiguration)
        let alben = try? await client.getAlbums()
        let fotos = try? await client.searchStatistics(filter: .visibleLibrary(type: nil))
        var bilder: [Data] = []
        let session = URLSession.mitSichererWeiterleitung(konfiguration)
        defer { session.finishTasksAndInvalidate() }
        for id in (alben ?? []).compactMap(\.albumThumbnailAssetId).prefix(6) {
            var request = URLRequest(url: client.thumbnailURL(assetId: id, size: .thumbnail, edited: false))
            request.setValue(gepruefterKey, forHTTPHeaderField: "x-api-key")
            if let (data, _) = try? await session.data(for: request) { bilder.append(data) }
        }
        zusammenfassung = Zusammenfassung(alben: alben?.count, fotos: fotos, titelbilder: bilder)
    }

    /// Meldung, wenn `connect` am Ende doch scheitert — der Fertig-Bildschirm zeigt
    /// sie und gibt den Knopf wieder frei.
    private(set) var verbindeFehler: String?

    /// Erst hier gehen die Zugangsdaten an den `ConnectionManager` (Keychain).
    func verbinde(mit connection: ConnectionManager) async {
        guard kannVerbinden, let url = serverURL else { return }
        verbindeFehler = nil
        OnboardingStatus.markiereGesehen()
        await connection.connect(serverURL: url.absoluteString, apiKey: gepruefterKey)
        if case .error(let meldung) = connection.state { verbindeFehler = meldung }
    }
}
