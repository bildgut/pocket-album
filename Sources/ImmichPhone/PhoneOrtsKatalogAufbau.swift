import Foundation

/// Baut den Ortskatalog vom Server: die Länderliste, dann je Land Anzahl, Städte,
/// Regionen und das jüngste Foto — bei 25 Ländern 101 Anfragen. Gemessen ohne die
/// Regionen: 76 Anfragen in 2,3 s.
enum PhoneOrtsKatalogAufbau {
    /// Wie viele Länder gleichzeitig laufen. Auch die Zählabfragen der Chips
    /// (`PhoneOrtsFacetten`) halten sich daran.
    static let parallel = 8

    /// `land == nil` heißt: mindestens eine der vier Anfragen dieses Landes scheiterte.
    private struct LandErgebnis: Sendable {
        let name: String
        let land: PhoneOrtsLand?
        /// Die Zählabfrage kam mit 403 zurück — dem Schlüssel fehlt `asset.statistics`.
        var statistikAbgelehnt = false
    }

    static let statistikRecht = "asset.statistics"

    /// Katalog plus die Auskunft, ob der Server die Zählabfrage mit 403 abwies.
    struct Ergebnis: Sendable {
        let katalog: PhoneOrtsKatalog
        let statistikAbgelehnt: Bool
    }

    /// - Parameter vorher: der bisherige Katalog. Aus ihm kommt der Stand eines
    ///   Landes, dessen Anfragen diesmal scheitern. Seine Städte-Anzahlen **nicht**:
    ///   Sie würden sonst nie aufgefrischt; beim nächsten Öffnen zählt der Reiter neu. `nil` beim manuellen Neuaufbau.
    /// - Throws: nur, wenn schon die Länderliste nicht kommt.
    static func aufbauen(
        apiClient: ImmichAPIClient,
        vorher: PhoneOrtsKatalog?,
        jetzt: Date = Date(),
        statistikErlaubt: Bool = true,
        geteilteAlben: [String] = PhoneGeteilteAlben.aktuell
    ) async throws -> PhoneOrtsKatalog {
        try await aufbauenMitMeldung(apiClient: apiClient, vorher: vorher, jetzt: jetzt,
                                     statistikErlaubt: statistikErlaubt, geteilteAlben: geteilteAlben).katalog
    }

    /// Wie ``aufbauen(apiClient:vorher:jetzt:statistikErlaubt:)``. Ohne das Recht
    /// `asset.statistics` (oder nach einem 403 darauf) bleibt `anzahl` `nil` —
    /// früher scheiterte daran das **ganze** Land: Platzhalter ohne Titelbild,
    /// `aufgebautAm` nil und damit bei jedem Öffnen ein Neuaufbau mit ~101 Anfragen.
    static func aufbauenMitMeldung(
        apiClient: ImmichAPIClient,
        vorher: PhoneOrtsKatalog?,
        jetzt: Date = Date(),
        statistikErlaubt: Bool = true,
        geteilteAlben: [String] = PhoneGeteilteAlben.aktuell
    ) async throws -> Ergebnis {
        let eigeneNamen = try await apiClient.searchSuggestions(type: "country")
        // Die Vorschlagsliste kennt nur die eigene Bibliothek. Orte aus geteilten Alben
        // kommen aus deren Fotos; scheitert das, fehlen sie — der Lauf gilt dann als
        // unvollständig und wird beim nächsten Öffnen wiederholt.
        let geteilt = await geteilteOrte(geteilteAlben, apiClient: apiClient)
        let zusatzOrte = geteilt ?? [:]
        let namen = PhoneGeteilteOrte.vereint(eigeneNamen, zusatzOrte.keys.sorted())

        let ergebnisse = await withTaskGroup(of: LandErgebnis.self) { gruppe in
            var gesammelt: [String: LandErgebnis] = [:]
            var laufend = 0
            for name in namen {
                if laufend == parallel, let fertig = await gruppe.next() {
                    gesammelt[fertig.name] = fertig
                    laufend -= 1
                }
                let zusatz = zusatzOrte[name]
                gruppe.addTask {
                    await land(name, geteilt: zusatz, geteilteAlben: geteilteAlben,
                               apiClient: apiClient, zaehlen: statistikErlaubt)
                }
                laufend += 1
            }
            for await fertig in gruppe {
                gesammelt[fertig.name] = fertig
            }
            return gesammelt
        }

        var vollstaendig = geteilt != nil
        var laender: [PhoneOrtsLand] = []
        for name in namen {
            if let neu = ergebnisse[name]?.land {
                // Ein Land, das nur archivierte oder gelöschte Fotos hat, führt die
                // Vorschlagsliste trotzdem — im Reiter wäre es eine leere Kachel.
                // Ohne Zählung entscheidet das jüngste sichtbare Foto.
                let hatFotos = neu.anzahl.map { $0 > 0 } ?? (neu.titelbildId != nil)
                if hatFotos { laender.append(neu) }
            } else {
                vollstaendig = false
                laender.append(vorher?.land(name) ?? PhoneOrtsLand(
                    name: name, anzahl: 0, zuletzt: nil, titelbildId: nil, staedte: [], regionen: []
                ))
            }
        }

        AppLogger.cache.info("Ortskatalog: \(laender.count, privacy: .public) Länder, vollständig: \(vollstaendig, privacy: .public)")
        let katalog = PhoneOrtsKatalog(
            basis: apiClient.baseURL.absoluteString,
            laender: laender,
            aufgebautAm: vollstaendig ? jetzt : nil,
            staedteAnzahlen: [:],
            geteilteAlben: geteilteAlben
        )
        return Ergebnis(katalog: katalog, statistikAbgelehnt: ergebnisse.values.contains { $0.statistikAbgelehnt })
    }

    /// Länder mit Städten und Regionen aus den Fotos geteilter Alben; `nil`, wenn die
    /// Abfrage scheiterte. Ohne geteilte Alben keine Anfrage.
    private static func geteilteOrte(
        _ albumIds: [String], apiClient: ImmichAPIClient
    ) async -> [String: PhoneGeteilteOrte.Land]? {
        guard !albumIds.isEmpty else { return [:] }
        var filter = SearchFilter.visibleLibrary(type: nil)
        filter.albumIds = .anyOf(albumIds)
        do {
            let assets = try await apiClient.searchAllAssets(filter: filter, withExif: true)
            let orte = PhoneGeteilteOrte.aus(assets)
            AppLogger.cache.info("Ortskatalog: \(albumIds.count, privacy: .public) geteilte Alben, \(assets.count, privacy: .public) Fotos, \(orte.count, privacy: .public) Länder")
            return orte
        } catch {
            AppLogger.cache.error("Ortskatalog: Orte geteilter Alben gescheitert: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func land(
        _ name: String, geteilt: PhoneGeteilteOrte.Land?, geteilteAlben: [String],
        apiClient: ImmichAPIClient, zaehlen: Bool
    ) async -> LandErgebnis {
        // Zählung und jüngstes Foto über eigene Bibliothek und geteilte Alben.
        let filter = PhoneSuchAuswahl.land(name).searchFilter(geteilteAlben: geteilteAlben)
        // Ein 403 auf die Zählung ist kein Ausfall des Landes.
        async let zaehlung = zaehle(filter, apiClient: apiClient, zaehlen: zaehlen)
        do {
            async let staedte = apiClient.searchSuggestions(type: "city", country: name)
            async let regionen = apiClient.searchSuggestions(type: "state", country: name)
            async let juengstes = apiClient.searchAssets(query: AssetSearchQuery(
                filter: filter,
                orderBy: SearchOrder(field: .localDateTime, direction: .desc),
                size: 1
            ))
            let erstes = try await juengstes.items?.first
            let (anzahl, abgelehnt) = try await zaehlung
            return LandErgebnis(name: name, land: PhoneOrtsLand(
                name: name,
                anzahl: anzahl,
                zuletzt: erstes?.localDateTime ?? erstes?.fileCreatedAt,
                titelbildId: erstes?.id,
                staedte: PhoneGeteilteOrte.vereint(try await staedte, geteilt?.staedte ?? []),
                regionen: PhoneGeteilteOrte.vereint(try await regionen, geteilt?.regionen ?? [])
            ), statistikAbgelehnt: abgelehnt)
        } catch {
            AppLogger.cache.error("Ortskatalog: \(name, privacy: .public) gescheitert: \(error.localizedDescription, privacy: .public)")
            return LandErgebnis(name: name, land: nil)
        }
    }

    /// (Anzahl, 403?). Nur ein 403 — fehlendes Recht — ergibt „keine Zahl“; jeder
    /// andere Fehler bleibt ein Ausfall des Landes (Teilausfall, neuer Versuch).
    private static func zaehle(_ filter: SearchFilter, apiClient: ImmichAPIClient, zaehlen: Bool) async throws -> (Int?, Bool) {
        guard zaehlen else { return (nil, false) }
        do { return (try await apiClient.searchStatistics(filter: filter), false) }
        catch APIError.httpError(403) { return (nil, true) }
    }
}
