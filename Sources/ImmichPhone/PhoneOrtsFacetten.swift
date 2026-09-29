import Foundation
import Observation

/// Die reinen Rechenteile der Chip-Reihen — ohne Netz prüfbar.
enum PhoneOrtsFacettenRechnung {
    /// Ab so vielen Treffern ermittelt der Reiter die Personen nur auf Tippen.
    static let personenSchwelle = 2_000
    /// Gemessen am 12.09.2026: eine Seite à 1 000 Assets mit Personen = 1,39 MB.
    static let megabyteJeTausend = 1.39

    static func personenAutomatisch(treffer: Int) -> Bool {
        treffer < personenSchwelle
    }

    static func geschaetzteMegabyte(treffer: Int) -> Int {
        max(1, Int((Double(treffer) / 1_000 * megabyteJeTausend).rounded()))
    }

    /// Zählt benannte, sichtbare Personen. Unbenannte fallen heraus — in Tokyo war
    /// „(unbenannt)" mit 36 Gesichtern der häufigste Treffer und stünde sonst vorn.
    static func personen(aus assets: [Asset]) -> [PhoneOrtsChip] {
        var anzahl: [String: Int] = [:]
        var namen: [String: String] = [:]
        for asset in assets {
            // Zwei erkannte Gesichter derselben Person auf einem Foto zählen einmal.
            var gesehen = Set<String>()
            for person in asset.people ?? [] {
                let name = person.name.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, person.isHidden != true, gesehen.insert(person.id).inserted else { continue }
                anzahl[person.id, default: 0] += 1
                namen[person.id] = name
            }
        }
        return anzahl
            .map { PhoneOrtsChip(id: $0.key, titel: namen[$0.key] ?? "", anzahl: $0.value) }
            .sorted { $0.anzahl != $1.anzahl ? $0.anzahl > $1.anzahl : $0.titel < $1.titel }
    }

    /// Kandidatenjahre zwischen ältestem und jüngstem Foto, **um je ein Jahr
    /// erweitert**: Die Grenzfotos kommen nach `localDateTime`, gezählt wird über
    /// `takenAt` in UTC — ein Foto vom 1. Januar 00:30 in Tokyo liegt in UTC noch im
    /// Vorjahr. Leere Jahre fallen nach dem Zählen weg.
    static func kandidatenjahre(juengstes: String?, aeltestes: String?) -> [Int] {
        guard let bis = juengstes.flatMap(jahr(aus:)),
              let von = aeltestes.flatMap(jahr(aus:)),
              von <= bis
        else { return [] }
        return Array(((von - 1)...(bis + 1)).reversed())
    }

    static func jahr(aus zeitstempel: String) -> Int? {
        Int(zeitstempel.prefix(4))
    }

    static func jahresChips(_ zaehlung: [Int: Int]) -> [PhoneOrtsChip] {
        zaehlung
            .filter { $0.value > 0 }
            .sorted { $0.key > $1.key }
            .map { PhoneOrtsChip(id: String($0.key), titel: String($0.key), anzahl: $0.value) }
    }

    static func stadtChips(_ zaehlung: [String: Int]) -> [PhoneOrtsChip] {
        zaehlung
            .filter { $0.value > 0 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { PhoneOrtsChip(id: $0.key, titel: $0.key, anzahl: $0.value) }
    }
}

/// Die drei Chip-Reihen des Orte-Reiters und die Trefferzahl der Filterleiste.
///
/// Städte und Jahre kommen aus Zählabfragen (`/search/statistics`, ~30 ms je
/// Abfrage), Personen aus einem Durchlauf mit `withPeople` — automatisch nur unter
/// ``PhoneOrtsFacettenRechnung/personenSchwelle``. Warum drei Wege: Spec,
/// Abschnitt „Die Chips".
@Observable @MainActor
final class PhoneOrtsFacetten {

    enum Personen: Equatable {
        case keine
        case laedt
        /// Über der Schwelle — die Ansicht zeigt „Personen ermitteln (≈ N MB)".
        case aufAnfrage(megabyte: Int)
        case bereit([PhoneOrtsChip])
        case fehler(String)
    }

    static let trefferFehlerText = String(localized: "Couldn’t determine the number of results.")

    private(set) var treffer: Int?
    private(set) var staedte: [PhoneOrtsChip] = []
    private(set) var staedteLaden = false
    private(set) var jahre: [PhoneOrtsChip] = []
    private(set) var jahreLaden = false
    private(set) var personen: Personen = .keine

    /// Zählt jedes ``leere()`` hoch. Ein Lauf, der nach seinem `await` eine andere
    /// Zahl vorfindet, gehört zu einer überholten Auswahl und schreibt nichts mehr.
    private var generation: UInt64 = 0

    /// Ermittelte Personen je Auswahl. Der Durchlauf ist der einzige teure Weg —
    /// dieselbe Auswahl ein zweites Mal soll ihn nicht wiederholen.
    /// Der Schlüssel ist **nur** die Auswahl, nicht Server oder Konto — deshalb muss
    /// ``vergiss()`` bei jedem Server- oder Kontowechsel laufen, sonst stünden die
    /// Personen von Konto A bei Konto B (samt IDs, die dort in den Filter gerieten).
    private var personenCache: [PhoneSuchAuswahl: [PhoneOrtsChip]] = [:]

    /// Der Weg zum Vergessen: Abmelden und Serverwechsel. Leert die Reihen wie
    /// ``leere()`` und zusätzlich den Personen-Zwischenspeicher.
    func vergiss() {
        vergissPersonen()
        leere()
    }

    /// Nur der Zwischenspeicher, die sichtbaren Reihen bleiben. Nach einem
    /// übernommenen Katalogaufbau: Die gezählten Personen sollen eine Auffrischung
    /// nicht überdauern, die gerade gezeigten Chips aber auch nicht verschwinden —
    /// niemand lüde sie danach neu.
    func vergissPersonen() {
        personenCache = [:]
    }

    func leere() {
        generation &+= 1
        treffer = nil
        staedte = []
        staedteLaden = false
        jahre = []
        jahreLaden = false
        personen = .keine
    }

    /// Rechnet alle drei Reihen für `auswahl` neu.
    ///
    /// - Parameter gespeicherteStaedte: aus dem Katalog; gezeigt, **bevor** die
    ///   Zählung zurückkommt, und behalten, wenn sie scheitert.
    /// - Returns: die frisch gezählten Städte, wenn `auswahl` nur ein Land ist (zum
    ///   Zurückschreiben in den Katalog), sonst `nil`.
    @discardableResult
    func laden(
        fuer auswahl: PhoneSuchAuswahl,
        katalogLand: PhoneOrtsLand?,
        gespeicherteStaedte: [PhoneOrtsChip]?,
        apiClient: ImmichAPIClient
    ) async -> [PhoneOrtsChip]? {
        // Ein schon abgebrochener Lauf, der erst jetzt anläuft, darf die Reihen der
        // neuen Auswahl nicht noch einmal auf „lädt" setzen.
        guard !Task.isCancelled else { return nil }
        leere()
        let meine = generation
        guard !auswahl.istLeer else { return nil }
        staedte = gespeicherteStaedte ?? []
        staedteLaden = true
        jahreLaden = true
        personen = .laedt

        async let trefferZahl = Self.zaehle(auswahl.searchFilter(), apiClient: apiClient)
        async let stadtChips = Self.zaehleStaedte(auswahl.ohneStadt(), namen: katalogLand?.staedte ?? [], apiClient: apiClient)
        async let jahresChips = Self.zaehleJahre(auswahl.ohneJahr(), apiClient: apiClient)

        let gezaehlt = await trefferZahl
        guard meine == generation, !Task.isCancelled else { return nil }
        treffer = gezaehlt

        let neueJahre = await jahresChips
        guard meine == generation, !Task.isCancelled else { return nil }
        jahre = neueJahre
        jahreLaden = false

        let neueStaedte = await stadtChips
        guard meine == generation, !Task.isCancelled else { return nil }
        if let neueStaedte { staedte = neueStaedte }
        staedteLaden = false

        if let gezaehlt {
            if PhoneOrtsFacettenRechnung.personenAutomatisch(treffer: gezaehlt) || personenCache[auswahl] != nil {
                await personenErmitteln(fuer: auswahl, apiClient: apiClient)
            } else {
                personen = .aufAnfrage(megabyte: PhoneOrtsFacettenRechnung.geschaetzteMegabyte(treffer: gezaehlt))
            }
        } else {
            personen = .fehler(Self.trefferFehlerText)
        }
        // Derselbe Schutz wie oben, jetzt für den Rückgabewert: Ein Abbruch (oder eine
        // neue Auswahl) zwischen dem letzten `await` oben und hier darf die gezählten
        // Städte nicht mehr an den Aufrufer zum Zurückschreiben in den Katalog geben.
        guard meine == generation, !Task.isCancelled else { return nil }
        return auswahl.istNurLand ? neueStaedte : nil
    }

    /// Der Durchlauf über alle Treffer mit `withPeople`. Aus ``laden(fuer:katalogLand:gespeicherteStaedte:apiClient:)``
    /// unter der Schwelle, sonst vom Knopf.
    func personenErmitteln(fuer auswahl: PhoneSuchAuswahl, apiClient: ImmichAPIClient) async {
        guard !Task.isCancelled else { return }
        if let gemerkt = personenCache[auswahl] {
            personen = .bereit(gemerkt)
            return
        }
        let meine = generation
        personen = .laedt
        do {
            let assets = try await apiClient.searchAllAssets(filter: auswahl.searchFilter(), withPeople: true)
            guard meine == generation, !Task.isCancelled else { return }
            let chips = PhoneOrtsFacettenRechnung.personen(aus: assets)
            personenCache[auswahl] = chips
            personen = .bereit(chips)
        } catch {
            // Eine mittendrin abgebrochene Anfrage wirft `URLError(.cancelled)` von
            // `session.data`, nicht `CancellationError` — beide sind kein Fehler,
            // den die Ansicht zeigen soll.
            let abgebrochen = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
            guard meine == generation, !abgebrochen else { return }
            personen = .fehler(error.localizedDescription)
        }
    }

    // MARK: - Zählen

    nonisolated private static func zaehle(_ filter: SearchFilter, apiClient: ImmichAPIClient) async -> Int? {
        try? await apiClient.searchStatistics(filter: filter)
    }

    /// `nil`, wenn eine Zählung scheitert.
    nonisolated private static func zaehleStaedte(
        _ basis: PhoneSuchAuswahl,
        namen: [String],
        apiClient: ImmichAPIClient
    ) async -> [PhoneOrtsChip]? {
        let basisFilter = basis.searchFilter()
        let zaehlung = await parallelZaehlen(namen, filter: { name in
            // Direkt am Filter statt über `mitStadt`: Das würde eine gewählte Region
            // entfernen, gezählt werden soll aber innerhalb der Region.
            var filter = basisFilter
            filter.city = .equals(name)
            return filter
        }, apiClient: apiClient)
        return zaehlung.map(PhoneOrtsFacettenRechnung.stadtChips)
    }

    nonisolated private static func zaehleJahre(_ basis: PhoneSuchAuswahl, apiClient: ImmichAPIClient) async -> [PhoneOrtsChip] {
        let filter = basis.searchFilter()
        async let neu = try? apiClient.searchAssets(query: AssetSearchQuery(
            filter: filter, orderBy: SearchOrder(field: .localDateTime, direction: .desc), size: 1
        ))
        async let alt = try? apiClient.searchAssets(query: AssetSearchQuery(
            filter: filter, orderBy: SearchOrder(field: .localDateTime, direction: .asc), size: 1
        ))
        let juengstes = await neu?.items?.first
        let aeltestes = await alt?.items?.first
        let kandidaten = PhoneOrtsFacettenRechnung.kandidatenjahre(
            juengstes: juengstes?.localDateTime ?? juengstes?.fileCreatedAt,
            aeltestes: aeltestes?.localDateTime ?? aeltestes?.fileCreatedAt
        )
        let zaehlung = await parallelZaehlen(kandidaten, filter: { basis.mitJahr($0).searchFilter() }, apiClient: apiClient)
        return PhoneOrtsFacettenRechnung.jahresChips(zaehlung ?? [:])
    }

    /// Zählabfragen mit höchstens ``PhoneOrtsKatalogAufbau/parallel`` gleichzeitig.
    /// `nil` nur, wenn keine einzige gelingt; einzelne Fehlschläge fallen heraus.
    nonisolated private static func parallelZaehlen<Schluessel: Hashable & Sendable>(
        _ schluessel: [Schluessel],
        filter: @escaping @Sendable (Schluessel) -> SearchFilter,
        apiClient: ImmichAPIClient
    ) async -> [Schluessel: Int]? {
        await withTaskGroup(of: (Schluessel, Int?).self) { gruppe in
            var ergebnis: [Schluessel: Int] = [:]
            var gescheitert = false
            var laufend = 0
            for eintrag in schluessel {
                // Destrukturierung eines Tupels innerhalb einer optionalen Bindung ist
                // kein gültiges Swift („if laufend == …, let (fertig, anzahl) = …") —
                // deshalb erst auf ein Paar binden und dann per `.0`/`.1` zugreifen.
                if laufend == PhoneOrtsKatalogAufbau.parallel, let paar = await gruppe.next() {
                    let (fertig, anzahl) = paar
                    if let anzahl { ergebnis[fertig] = anzahl } else { gescheitert = true }
                    laufend -= 1
                }
                gruppe.addTask { (eintrag, try? await apiClient.searchStatistics(filter: filter(eintrag))) }
                laufend += 1
            }
            for await (fertig, anzahl) in gruppe {
                if let anzahl { ergebnis[fertig] = anzahl } else { gescheitert = true }
            }
            // Nur `nil`, wenn **nichts** gezählt wurde: Eine einzelne gescheiterte
            // Zählung ließ früher die ganze Reihe verschwinden.
            return gescheitert && ergebnis.isEmpty ? nil : ergebnis
        }
    }
}
