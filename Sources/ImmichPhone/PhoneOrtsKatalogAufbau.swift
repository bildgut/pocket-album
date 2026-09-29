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
    }

    /// - Parameter vorher: der bisherige Katalog. Aus ihm kommen die
    ///   Städte-Anzahlen (dieser Lauf zählt keine Städte) und der Stand eines
    ///   Landes, dessen Anfragen diesmal scheitern. `nil` beim manuellen Neuaufbau.
    /// - Throws: nur, wenn schon die Länderliste nicht kommt.
    static func aufbauen(
        apiClient: ImmichAPIClient,
        vorher: PhoneOrtsKatalog?,
        jetzt: Date = Date()
    ) async throws -> PhoneOrtsKatalog {
        let namen = try await apiClient.searchSuggestions(type: "country")

        let ergebnisse = await withTaskGroup(of: LandErgebnis.self) { gruppe in
            var gesammelt: [String: LandErgebnis] = [:]
            var laufend = 0
            for name in namen {
                if laufend == parallel, let fertig = await gruppe.next() {
                    gesammelt[fertig.name] = fertig
                    laufend -= 1
                }
                gruppe.addTask { await land(name, apiClient: apiClient) }
                laufend += 1
            }
            for await fertig in gruppe {
                gesammelt[fertig.name] = fertig
            }
            return gesammelt
        }

        var vollstaendig = true
        var laender: [PhoneOrtsLand] = []
        for name in namen {
            if let neu = ergebnisse[name]?.land {
                // Ein Land, das nur archivierte oder gelöschte Fotos hat, führt die
                // Vorschlagsliste trotzdem — im Reiter wäre es eine leere Kachel.
                if neu.anzahl > 0 { laender.append(neu) }
            } else {
                vollstaendig = false
                laender.append(vorher?.land(name) ?? PhoneOrtsLand(
                    name: name, anzahl: 0, zuletzt: nil, titelbildId: nil, staedte: [], regionen: []
                ))
            }
        }

        AppLogger.cache.info("Ortskatalog: \(laender.count, privacy: .public) Länder, vollständig: \(vollstaendig, privacy: .public)")
        return PhoneOrtsKatalog(
            basis: apiClient.baseURL.absoluteString,
            laender: laender,
            aufgebautAm: vollstaendig ? jetzt : nil,
            staedteAnzahlen: vorher?.staedteAnzahlen ?? [:]
        )
    }

    private static func land(_ name: String, apiClient: ImmichAPIClient) async -> LandErgebnis {
        let filter = PhoneSuchAuswahl.land(name).searchFilter()
        do {
            async let anzahl = apiClient.searchStatistics(filter: filter)
            async let staedte = apiClient.searchSuggestions(type: "city", country: name)
            async let regionen = apiClient.searchSuggestions(type: "state", country: name)
            async let juengstes = apiClient.searchAssets(query: AssetSearchQuery(
                filter: filter,
                orderBy: SearchOrder(field: .localDateTime, direction: .desc),
                size: 1
            ))
            let erstes = try await juengstes.items?.first
            return LandErgebnis(name: name, land: PhoneOrtsLand(
                name: name,
                anzahl: try await anzahl,
                zuletzt: erstes?.localDateTime ?? erstes?.fileCreatedAt,
                titelbildId: erstes?.id,
                staedte: try await staedte,
                regionen: try await regionen
            ))
        } catch {
            AppLogger.cache.error("Ortskatalog: \(name, privacy: .public) gescheitert: \(error.localizedDescription, privacy: .public)")
            return LandErgebnis(name: name, land: nil)
        }
    }
}
