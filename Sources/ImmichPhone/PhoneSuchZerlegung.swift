import Foundation

/// Getippter Text → ``PhoneSuchAuswahl``. Zerlegt wird mit dem geteilten
/// `SearchTermMatcher.parse` (dieselben Regeln wie am Mac); hier steht nur die
/// Übersetzung in die Auswahl des Telefons.
///
/// Chips, die das Telefon nicht kann, fallen weg: Der Umkreis braucht den
/// Mac-Rasterindex, und Tag, Album, Kamera und Bildtext stehen nicht im Katalog.
enum PhoneSuchZerlegung {

    struct Ergebnis: Equatable {
        let auswahl: PhoneSuchAuswahl
        let personenNamen: [String: String]
    }

    /// Personen (benannt, nicht versteckt) und Orte aus dem Ortskatalog.
    static func katalog(personen: [Person], orte: PhoneOrtsKatalog?) -> SearchCatalog {
        var katalog = SearchCatalog()
        katalog.people = personen.filter { !$0.name.isEmpty && $0.isHidden != true }
        let laender = orte?.laender ?? []
        katalog.countries = laender.map { (country: $0.name, count: $0.anzahl ?? 0) }
        var staedte: [String: Int] = [:]
        for land in laender {
            for stadt in land.staedte { staedte[stadt, default: 0] += 1 }
            for chip in orte?.staedteAnzahlen[land.name] ?? [] { staedte[chip.titel] = chip.anzahl }
        }
        katalog.cities = staedte.map { (city: $0.key, count: $0.value) }.sorted { $0.count > $1.count }
        return katalog
    }

    static func zerlege(_ text: String, katalog: SearchCatalog, jetzt: Date = Date()) -> Ergebnis {
        let (tokens, rest) = SearchTermMatcher.parse(text, catalog: katalog, now: jetzt)
        var auswahl = PhoneSuchAuswahl.leer
        var namen: [String: String] = [:]
        for token in tokens {
            switch token {
            case .person(let id, let name) where !auswahl.personen.contains(id):
                auswahl = auswahl.mitPerson(id)
                namen[id] = name
            case .year(let jahr) where auswahl.jahr == nil:
                auswahl = auswahl.mitJahr(jahr)
            case .dateRange(let von, let bis, let label) where auswahl.zeitraum == nil:
                auswahl = auswahl.mitZeitraum(.init(von: von, bis: bis, label: label))
            case .country(let land) where auswahl.land == nil:
                auswahl = auswahl.mitLand(land)
            case .city(let stadt) where auswahl.stadt == nil:
                auswahl = auswahl.mitStadt(stadt)
            case .type(let typ):
                auswahl = auswahl.mitTyp(typ)
            case .favorite:
                auswahl = auswahl.mitFavoriten(true)
            default:
                continue
            }
        }
        return Ergebnis(auswahl: auswahl.mitFreitext(rest), personenNamen: namen)
    }
}
