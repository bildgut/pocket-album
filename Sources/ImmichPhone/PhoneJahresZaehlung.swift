import Foundation

/// Die Jahresleiste in „Entdecken“: nur Jahre, in denen es Fotos gibt.
///
/// Früher stand dort die volle Spanne ältestes…jüngstes Foto — mit Lücken, die
/// beim Tippen in ein leeres Raster führten. Zwei Wege zu den Zahlen:
/// 1. `POST /search/statistics` je Kandidatenjahr (~30 ms, 8 parallel) — braucht
///    `asset.statistics`.
/// 2. Ohne das Recht (oder nach 403): `GET /timeline/buckets?size=MONTH`, das
///    auch ein eingeschränkter Schlüssel lesen darf; die Monate werden zu Jahren
///    aufsummiert.
/// Scheitert beides, bleibt die alte Spanne — besser Lücken als gar keine Leiste.
enum PhoneJahresZaehlung {

    struct Ergebnis: Equatable, Sendable {
        let jahre: [Int]
        /// Die Zählabfrage kam mit 403 zurück — der Aufrufer merkt sich das Recht als abgelehnt.
        let statistikAbgelehnt: Bool
    }

    static func jahre(
        aeltestes: String?,
        juengstes: String?,
        statistikErlaubt: Bool,
        apiClient: ImmichAPIClient,
        session: URLSession = .shared
    ) async -> Ergebnis {
        let spanne = PhoneOrtsModell.jahre(aeltestes: aeltestes, juengstes: juengstes)
        guard !spanne.isEmpty else { return Ergebnis(jahre: [], statistikAbgelehnt: false) }

        var abgelehnt = false
        if statistikErlaubt {
            // Die Grenzen kommen hier aus `fileCreatedAt` (UTC) wie die Zählung über
            // `takenAt` — anders als bei den Facetten braucht es keinen Rand von ±1 Jahr.
            let zaehlung = await zaehle(spanne, apiClient: apiClient)
            abgelehnt = zaehlung.abgelehnt
            if !abgelehnt {
                // Ein einzelnes gescheitertes Jahr bleibt stehen (Zahl unbekannt),
                // statt die ganze Leiste zu verlieren.
                var werte = zaehlung.anzahlen
                for jahr in zaehlung.gescheitert where spanne.contains(jahr) { werte[jahr] = 1 }
                return Ergebnis(jahre: PhoneOrtsFacettenRechnung.jahresChips(werte).compactMap { Int($0.id) },
                                statistikAbgelehnt: false)
            }
        }
        if let ausZeitleiste = try? await jahreAusZeitleiste(apiClient: apiClient, session: session) {
            return Ergebnis(jahre: ausZeitleiste, statistikAbgelehnt: abgelehnt)
        }
        return Ergebnis(jahre: spanne, statistikAbgelehnt: abgelehnt)
    }

    /// Monate der Zeitleiste → Jahre mit mindestens einem Foto, absteigend.
    static func jahre(ausMonaten monate: [(zeit: String, anzahl: Int)]) -> [Int] {
        var summe: [Int: Int] = [:]
        for monat in monate {
            guard let jahr = PhoneOrtsFacettenRechnung.jahr(aus: monat.zeit) else { continue }
            summe[jahr, default: 0] += monat.anzahl
        }
        return PhoneOrtsFacettenRechnung.jahresChips(summe).compactMap { Int($0.id) }
    }

    private struct Zaehlung: Sendable {
        var anzahlen: [Int: Int] = [:]
        var gescheitert: [Int] = []
        var abgelehnt = false
    }

    private static func zaehle(_ jahre: [Int], apiClient: ImmichAPIClient) async -> Zaehlung {
        await withTaskGroup(of: (Int, Result<Int, Error>).self) { gruppe in
            var z = Zaehlung()
            func nimm(_ paar: (Int, Result<Int, Error>)) {
                switch paar.1 {
                case .success(let n): z.anzahlen[paar.0] = n
                case .failure(APIError.httpError(403)): z.abgelehnt = true
                case .failure: z.gescheitert.append(paar.0)
                }
            }
            var laufend = 0
            for jahr in jahre {
                if laufend == PhoneOrtsKatalogAufbau.parallel, let paar = await gruppe.next() {
                    nimm(paar); laufend -= 1
                }
                gruppe.addTask {
                    do { return (jahr, .success(try await apiClient.searchStatistics(
                        filter: PhoneSuchAuswahl.leer.mitJahr(jahr).searchFilter()))) }
                    catch { return (jahr, .failure(error)) }
                }
                laufend += 1
            }
            for await paar in gruppe { nimm(paar) }
            return z
        }
    }

    /// `GET /api/timeline/buckets?size=MONTH&visibility=timeline`. Eigene Anfrage
    /// statt `ImmichAPIClient`, dessen Sitzung privat ist — die Kopfzeile ist
    /// dieselbe, `session` ist nur für Tests austauschbar.
    static func jahreAusZeitleiste(apiClient: ImmichAPIClient, session: URLSession) async throws -> [Int] {
        struct Monat: Decodable { let timeBucket: String; let count: Int }
        var teile = URLComponents(url: apiClient.baseURL.appending(path: "api/timeline/buckets"),
                                  resolvingAgainstBaseURL: false)!
        teile.queryItems = [URLQueryItem(name: "size", value: "MONTH"),
                            URLQueryItem(name: "visibility", value: "timeline")]
        var anfrage = URLRequest(url: teile.url!, cachePolicy: .reloadIgnoringLocalCacheData)
        anfrage.setValue(apiClient.apiKey, forHTTPHeaderField: "x-api-key")
        // Mit Weiterleitungsschutz: die Anfrage trägt den API-Key (siehe SichereWeiterleitung).
        let (daten, antwort) = try await session.data(for: anfrage, delegate: SichereWeiterleitung.shared)
        let code = (antwort as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else { throw APIError.httpError(code) }
        let monate = try JSONDecoder().decode([Monat].self, from: daten)
        return jahre(ausMonaten: monate.map { ($0.timeBucket, $0.count) })
    }
}
