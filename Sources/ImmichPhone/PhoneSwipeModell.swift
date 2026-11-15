import Foundation
import Observation
import SwiftData

/// Die zwei Modi des 30-Tage-Swipe-Decks.
enum PhoneSwipeModus: String, CaseIterable, Identifiable, Codable, Sendable {
    case favoriten
    case aussortieren

    var id: String { rawValue }

    var titel: String {
        switch self {
        case .favoriten: PhoneSwipeTexts.modusFavoriten
        case .aussortieren: PhoneSwipeTexts.modusAussortieren
        }
    }

    /// Nur Modi anbieten, für die der API-Key das jeweilige Recht trägt.
    static func verfuegbareModi(rechte: KeyRechte) -> [PhoneSwipeModus] {
        var modi: [PhoneSwipeModus] = []
        if rechte.darf(KeyRechte.favorit) { modi.append(.favoriten) }
        if rechte.darf(KeyRechte.loeschen) { modi.append(.aussortieren) }
        return modi
    }

    /// Der Einstieg bleibt ausgeblendet, wenn der Nutzer offline ist oder ein
    /// Nur-Lese-Key weder favorisieren noch löschen darf.
    static func istEinstiegSichtbar(rechte: KeyRechte, istOffline: Bool) -> Bool {
        !istOffline && !verfuegbareModi(rechte: rechte).isEmpty
    }
}

/// Eine einzelne Karte im Swipe-Stapel (nur Standbilder).
struct PhoneSwipeKarteEintrag: Identifiable, Equatable, Sendable {
    let id: String
    let tagesSchluessel: String
    let stadt: String?
    let isFavorite: Bool
    let istGestapelt: Bool

    init(
        id: String,
        tagesSchluessel: String,
        stadt: String? = nil,
        isFavorite: Bool = false,
        istGestapelt: Bool = false
    ) {
        self.id = id
        self.tagesSchluessel = tagesSchluessel
        self.stadt = stadt
        self.isFavorite = isFavorite
        self.istGestapelt = istGestapelt
    }

    init?(asset: Asset, istGestapelt: Bool = false) {
        guard asset.type == .image,
              !asset.isTrashed,
              !asset.isArchived,
              asset.visibility != .hidden,
              !asset.isStackChild
        else { return nil }

        let datum = (asset.localDateTime?.isEmpty == false ? asset.localDateTime : nil) ?? asset.fileCreatedAt
        let stadtName = asset.exifInfo?.city.flatMap { $0.isEmpty ? nil : $0 }

        self.init(
            id: asset.id,
            tagesSchluessel: String(datum.prefix(10)),
            stadt: stadtName,
            isFavorite: asset.isFavorite,
            istGestapelt: istGestapelt || asset.isStacked
        )
    }
}

enum PhoneSwipeEntscheidung: Equatable, Sendable {
    case rechts
    case links
}

struct PhoneSwipeVerlaufEintrag: Equatable, Sendable {
    let karte: PhoneSwipeKarteEintrag
    let modus: PhoneSwipeModus
    let entscheidung: PhoneSwipeEntscheidung
}

/// Speichert je Server-Basis und Modus, welche Fotos schon durchgewischt wurden,
/// damit man beim nächsten Öffnen nicht von vorn beginnt. Einträge älter als
/// 35 Tage fallen automatisch heraus.
struct PhoneSwipeGesehenSpeicher {
    static let schluessel = "swipe.gesehen.v1"
    static let aufbewahrungsDauer: TimeInterval = 35 * 86_400

    let defaults: UserDefaults

    init(defaults: UserDefaults = AppEnvironment.defaults) {
        self.defaults = defaults
    }

    func geseheneIds(basis: URL, modus: PhoneSwipeModus, jetzt: Date = .now) -> Set<String> {
        let alle = ladeWoerterbuch()
        guard let eintraege = alle[Self.eimerSchluessel(basis: basis, modus: modus)] else { return [] }
        let grenze = jetzt.timeIntervalSince1970 - Self.aufbewahrungsDauer
        return Set(eintraege.compactMap { id, zeitstempel in
            zeitstempel >= grenze ? id : nil
        })
    }

    func merke(assetId: String, basis: URL, modus: PhoneSwipeModus, jetzt: Date = .now) {
        var alle = ladeWoerterbuch()
        let eimerKey = Self.eimerSchluessel(basis: basis, modus: modus)
        let jetztSekunden = jetzt.timeIntervalSince1970
        let grenze = jetztSekunden - Self.aufbewahrungsDauer
        var eimer = (alle[eimerKey] ?? [:]).filter { $0.value >= grenze }
        eimer[assetId] = jetztSekunden
        alle[eimerKey] = eimer
        speichereWoerterbuch(alle)
    }

    func entferne(assetId: String, basis: URL, modus: PhoneSwipeModus) {
        var alle = ladeWoerterbuch()
        let eimerKey = Self.eimerSchluessel(basis: basis, modus: modus)
        guard var eimer = alle[eimerKey] else { return }
        eimer.removeValue(forKey: assetId)
        if eimer.isEmpty {
            alle.removeValue(forKey: eimerKey)
        } else {
            alle[eimerKey] = eimer
        }
        speichereWoerterbuch(alle)
    }

    func zuruecksetzen(basis: URL, modus: PhoneSwipeModus) {
        var alle = ladeWoerterbuch()
        let eimerKey = Self.eimerSchluessel(basis: basis, modus: modus)
        guard alle.removeValue(forKey: eimerKey) != nil else { return }
        speichereWoerterbuch(alle)
    }

    private static func eimerSchluessel(basis: URL, modus: PhoneSwipeModus) -> String {
        "\(basis.absoluteString)#\(modus.rawValue)"
    }

    private func ladeWoerterbuch() -> [String: [String: Double]] {
        guard let daten = defaults.data(forKey: Self.schluessel),
              let decodiert = try? JSONDecoder().decode([String: [String: Double]].self, from: daten)
        else { return [:] }
        return decodiert
    }

    private func speichereWoerterbuch(_ wert: [String: [String: Double]]) {
        if wert.isEmpty {
            defaults.removeObject(forKey: Self.schluessel)
            return
        }
        if let daten = try? JSONEncoder().encode(wert) {
            defaults.set(daten, forKey: Self.schluessel)
        }
    }
}

/// Zustand und Logik des 30-Tage-Swipe-Decks.
///
/// Reiner `@Observable @MainActor`-Typ ohne SwiftUI — prüfbar gegen
/// `OrteMockURLProtocol` in `Tests/ImmichPhoneTests/PhoneSwipeModellTests.swift`.
@Observable @MainActor
final class PhoneSwipeModell {
    static let tage = 30
    static let seitengroesse = 250
    static let maxSeiten = 10

    private(set) var modus: PhoneSwipeModus
    private(set) var verfuegbareModi: [PhoneSwipeModus]
    private(set) var stapel: [PhoneSwipeKarteEintrag] = []
    private(set) var verlauf: [PhoneSwipeVerlaufEintrag] = []
    private(set) var vorgemerkteKarten: [PhoneSwipeKarteEintrag] = []
    private(set) var gesamtImZeitraum: Int = 0
    private(set) var laedt = false
    private(set) var loescht = false
    private(set) var hatGeladen = false
    private(set) var fehler: String?

    var vorgemerkteIds: Set<String> { Set(vorgemerkteKarten.map(\.id)) }

    @ObservationIgnored private let gesehenSpeicher: PhoneSwipeGesehenSpeicher
    @ObservationIgnored private var ladeGeneration: UInt64 = 0
    @ObservationIgnored private var offeneFavoritenTasks: [String: Task<Void, Never>] = [:]

    init(
        rechte: KeyRechte = KeyRechte(),
        gesehenSpeicher: PhoneSwipeGesehenSpeicher = PhoneSwipeGesehenSpeicher()
    ) {
        let modi = PhoneSwipeModus.verfuegbareModi(rechte: rechte)
        self.verfuegbareModi = modi
        self.modus = modi.first ?? .favoriten
        self.gesehenSpeicher = gesehenSpeicher
    }

    /// Suchfilter für die Standbilder der letzten 30 Tage.
    static func suchFilter(
        modus: PhoneSwipeModus,
        jetzt: Date = .now,
        kalender: Calendar = .current
    ) -> SearchFilter? {
        guard var filter = ZuletztOffline.filter(tage: Self.tage, jetzt: jetzt, kalender: kalender) else {
            return nil
        }
        filter.type = .equals(.image)
        if modus == .favoriten {
            filter.isFavorite = .equals(false)
        }
        return filter
    }

    func aktualisiereRechte(_ rechte: KeyRechte) {
        verfuegbareModi = PhoneSwipeModus.verfuegbareModi(rechte: rechte)
        if !verfuegbareModi.contains(modus), let erster = verfuegbareModi.first {
            modus = erster
        }
    }

    /// UTC-Monats-Buckets (`YYYY-MM-01`) für das Stapel-Fenster rund um die letzten `tage`.
    static func monatsBuckets(tage: Int = PhoneSwipeModell.tage, jetzt: Date = .now) -> [String] {
        var kalender = Calendar(identifier: .gregorian)
        kalender.timeZone = TimeZone(secondsFromGMT: 0) ?? kalender.timeZone

        let startDatum = jetzt.addingTimeInterval(-Double(tage + 1) * 86_400)
        let endDatum = jetzt.addingTimeInterval(86_400)

        guard let startMonat = kalender.date(from: kalender.dateComponents([.year, .month], from: startDatum)),
              let endMonat = kalender.date(from: kalender.dateComponents([.year, .month], from: endDatum))
        else { return [] }

        var buckets: [String] = []
        var aktuell = startMonat
        while aktuell <= endMonat {
            let teile = kalender.dateComponents([.year, .month], from: aktuell)
            if let jahr = teile.year, let monat = teile.month {
                buckets.append(String(format: "%04d-%02d-01", jahr, monat))
            }
            guard let naechster = kalender.date(byAdding: .month, value: 1, to: aktuell) else { break }
            aktuell = naechster
        }
        return buckets
    }

    func lade(apiClient: ImmichAPIClient, jetzt: Date = .now) async {
        guard let filter = Self.suchFilter(modus: modus, jetzt: jetzt) else { return }

        ladeGeneration &+= 1
        let meineGeneration = ladeGeneration
        let geladenerModus = modus

        laedt = true
        fehler = nil
        stapel = []
        verlauf = []
        gesamtImZeitraum = 0

        defer {
            if meineGeneration == ladeGeneration {
                laedt = false
            }
        }

        var alle: [PhoneSwipeKarteEintrag] = []
        var geseheneIdsImLauf = Set<String>()
        var cursor: String?
        var seite = 0

        do {
            let stapelInfo = await apiClient.ladeStapelInfoFuerMonate(Self.monatsBuckets(jetzt: jetzt))
            guard meineGeneration == ladeGeneration else { return }

            while seite < Self.maxSeiten {
                let query = AssetSearchQuery(
                    filter: filter,
                    orderBy: SearchOrder(field: .fileCreatedAt, direction: .desc),
                    cursor: cursor,
                    size: Self.seitengroesse,
                    withExif: true
                )
                let antwort = try await apiClient.searchAssets(query: query)
                guard meineGeneration == ladeGeneration else { return }

                let items = antwort.items ?? []
                for asset in items {
                    guard geseheneIdsImLauf.insert(asset.id).inserted,
                          !stapelInfo.versteckteKindIds.contains(asset.id),
                          let karte = PhoneSwipeKarteEintrag(
                              asset: asset,
                              istGestapelt: stapelInfo.gestapelteTitelbildIds.contains(asset.id)
                          )
                    else { continue }
                    if geladenerModus == .favoriten && karte.isFavorite { continue }
                    alle.append(karte)
                }

                seite += 1
                cursor = antwort.nextCursor
                if items.isEmpty || PhonePhotoFeed.istEnde(cursor) {
                    break
                }
            }

            let bereitsGesehen = gesehenSpeicher.geseheneIds(basis: apiClient.baseURL, modus: geladenerModus, jetzt: jetzt)
            let vorgemerkt = vorgemerkteIds

            gesamtImZeitraum = alle.count
            stapel = alle.filter { !bereitsGesehen.contains($0.id) && !vorgemerkt.contains($0.id) }
            verlauf = []
            hatGeladen = true
        } catch {
            guard meineGeneration == ladeGeneration else { return }
            fehler = error.localizedDescription
            hatGeladen = true
        }
    }

    func wechseleModus(_ neu: PhoneSwipeModus, apiClient: ImmichAPIClient, jetzt: Date = .now) async {
        guard neu != modus, verfuegbareModi.contains(neu) else { return }
        modus = neu
        await lade(apiClient: apiClient, jetzt: jetzt)
    }

    @discardableResult
    func wische(
        _ entscheidung: PhoneSwipeEntscheidung,
        apiClient: ImmichAPIClient,
        context: ModelContext? = nil,
        jetzt: Date = .now,
        onRechtAbgelehnt: ((String) -> Void)? = nil
    ) -> Task<Void, Never>? {
        guard !stapel.isEmpty else { return nil }
        let karte = stapel.removeFirst()
        let aktuellerModus = modus
        verlauf.append(PhoneSwipeVerlaufEintrag(karte: karte, modus: aktuellerModus, entscheidung: entscheidung))
        gesehenSpeicher.merke(assetId: karte.id, basis: apiClient.baseURL, modus: aktuellerModus, jetzt: jetzt)

        switch (aktuellerModus, entscheidung) {
        case (.favoriten, .rechts):
            PhoneFavoritMeldung.melde(assetId: karte.id, ist: true)
            aktualisiereFavoritImCache(assetId: karte.id, ist: true, context: context)
            let vorheriger = offeneFavoritenTasks[karte.id]
            let task = Task {
                await vorheriger?.value
                do {
                    try await apiClient.toggleFavorite(assetId: karte.id, isFavorite: true)
                    AppLogger.library.info("Swipe-Favorit \(karte.id, privacy: .public) gesetzt")
                } catch {
                    PhoneFavoritMeldung.melde(assetId: karte.id, ist: false)
                    aktualisiereFavoritImCache(assetId: karte.id, ist: false, context: context)
                    AppLogger.library.error("Swipe-Favorit \(karte.id, privacy: .public) fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
                    if case APIError.httpError(403) = error {
                        onRechtAbgelehnt?(KeyRechte.favorit)
                        fehler = PhoneSwipeTexts.rechtFehlt
                    } else {
                        fehler = error.localizedDescription
                    }
                }
            }
            offeneFavoritenTasks[karte.id] = task
            return task

        case (.aussortieren, .links):
            if !vorgemerkteKarten.contains(where: { $0.id == karte.id }) {
                vorgemerkteKarten.append(karte)
            }
            return nil

        case (.favoriten, .links), (.aussortieren, .rechts):
            return nil
        }
    }

    @discardableResult
    func rueckgaengig(
        apiClient: ImmichAPIClient,
        context: ModelContext? = nil,
        onRechtAbgelehnt: ((String) -> Void)? = nil
    ) -> Task<Void, Never>? {
        guard let letzter = verlauf.popLast() else { return nil }
        gesehenSpeicher.entferne(assetId: letzter.karte.id, basis: apiClient.baseURL, modus: letzter.modus)

        if letzter.modus == modus {
            stapel.insert(letzter.karte, at: 0)
        }

        switch (letzter.modus, letzter.entscheidung) {
        case (.favoriten, .rechts):
            PhoneFavoritMeldung.melde(assetId: letzter.karte.id, ist: false)
            aktualisiereFavoritImCache(assetId: letzter.karte.id, ist: false, context: context)
            let vorheriger = offeneFavoritenTasks[letzter.karte.id]
            let task = Task {
                await vorheriger?.value
                do {
                    try await apiClient.toggleFavorite(assetId: letzter.karte.id, isFavorite: false)
                    AppLogger.library.info("Swipe-Favorit \(letzter.karte.id, privacy: .public) rückgängig gemacht")
                } catch {
                    AppLogger.library.error("Swipe-Favorit-Undo \(letzter.karte.id, privacy: .public) fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
                    if case APIError.httpError(403) = error {
                        onRechtAbgelehnt?(KeyRechte.favorit)
                        fehler = PhoneSwipeTexts.rechtFehlt
                    } else {
                        fehler = error.localizedDescription
                    }
                }
            }
            offeneFavoritenTasks[letzter.karte.id] = task
            return task

        case (.aussortieren, .links):
            vorgemerkteKarten.removeAll { $0.id == letzter.karte.id }
            return nil

        case (.favoriten, .links), (.aussortieren, .rechts):
            return nil
        }
    }

    func hebeVormerkungAuf(assetId: String) {
        vorgemerkteKarten.removeAll { $0.id == assetId }
    }

    func leereFehler() {
        fehler = nil
    }

    func leereInPapierkorb(
        apiClient: ImmichAPIClient,
        context: ModelContext? = nil,
        onGeloescht: ([String]) -> Void = { _ in },
        onRechtAbgelehnt: ((String) -> Void)? = nil
    ) async -> Bool {
        let vorgemerkteSnapshot = vorgemerkteKarten
        guard !vorgemerkteSnapshot.isEmpty, !loescht else { return false }

        loescht = true
        defer { loescht = false }

        var alleZuLoeschendenIds: [String] = []
        var gesehen = Set<String>()
        for karte in vorgemerkteSnapshot {
            let stapelIds: [String]
            if karte.istGestapelt {
                stapelIds = await apiClient.getStackAssetIds(primaryAssetId: karte.id)
            } else {
                stapelIds = [karte.id]
            }
            for id in stapelIds where gesehen.insert(id).inserted {
                alleZuLoeschendenIds.append(id)
            }
        }

        do {
            try await apiClient.deleteAssets(ids: alleZuLoeschendenIds, force: false)
            AppLogger.library.info("Swipe-Korb: \(alleZuLoeschendenIds.count, privacy: .public) Asset(s) in den Papierkorb gelegt")
            let geloeschteMenge = Set(alleZuLoeschendenIds)
            markiereGeloeschtImCache(assetIds: geloeschteMenge, context: context)
            vorgemerkteKarten.removeAll { geloeschteMenge.contains($0.id) }
            verlauf.removeAll { geloeschteMenge.contains($0.karte.id) }
            onGeloescht(alleZuLoeschendenIds)
            return true
        } catch {
            AppLogger.library.error("Swipe-Korb löschen fehlgeschlagen: \(error.localizedDescription, privacy: .public)")
            if case APIError.httpError(403) = error {
                onRechtAbgelehnt?(KeyRechte.loeschen)
                fehler = PhoneSwipeTexts.rechtFehlt
            } else {
                fehler = error.localizedDescription
            }
            return false
        }
    }

    func nochmalsDurchsehen(apiClient: ImmichAPIClient, jetzt: Date = .now) async {
        gesehenSpeicher.zuruecksetzen(basis: apiClient.baseURL, modus: modus)
        await lade(apiClient: apiClient, jetzt: jetzt)
    }

    private func aktualisiereFavoritImCache(assetId: String, ist: Bool, context: ModelContext?) {
        guard let context else { return }
        let descriptor = FetchDescriptor<CachedAsset>(predicate: #Predicate<CachedAsset> { $0.assetId == assetId })
        guard let cached = try? context.fetch(descriptor).first else { return }
        cached.isFavorite = ist
        try? context.save()
    }

    private func markiereGeloeschtImCache(assetIds: Set<String>, context: ModelContext?) {
        guard let context, !assetIds.isEmpty else { return }
        let eindeutig = Array(assetIds)
        var start = 0
        var geaendert = false
        while start < eindeutig.count {
            let teil = Set(eindeutig[start..<min(start + 500, eindeutig.count)])
            start += 500
            let descriptor = FetchDescriptor<CachedAsset>(predicate: #Predicate<CachedAsset> { teil.contains($0.assetId) })
            if let eintraege = try? context.fetch(descriptor), !eintraege.isEmpty {
                for eintrag in eintraege {
                    eintrag.isTrashed = true
                }
                geaendert = true
            }
        }
        if geaendert {
            try? context.save()
        }
    }
}

/// Alle Anzeigetexte als Konstanten/Funktionen — SwiftUI parst String-Literale
/// direkt in `Text("…")` als Markdown.
enum PhoneSwipeTexts {
    static let einstieg = String(localized: "Review 30 Days")
    static let modusFavoriten = String(localized: "Favorites")
    static let modusAussortieren = String(localized: "Sort Out")

    static let stempelFavorit = String(localized: "FAVORITE")
    static let stempelWeiter = String(localized: "SKIP")
    static let stempelBehalten = String(localized: "KEEP")
    static let stempelPapierkorb = String(localized: "TRASH")

    static let aktionWeiter = String(localized: "Skip")
    static let aktionFavorit = String(localized: "Favorite")
    static let aktionBehalten = String(localized: "Keep")
    static let aktionVormerken = String(localized: "Mark for Trash")
    static let aktionRueckgaengig = String(localized: "Undo")

    static let laedtText = String(localized: "Loading photos from the last 30 days…")
    static let nichtVerfuegbar = String(localized: "Photos Unavailable")
    static let erneut = String(localized: "Try Again")
    static let leerTitel = String(localized: "All Caught Up")
    static let leerFavoritenText = String(localized: "All unrated photos from the last 30 days have been reviewed.")
    static let leerAussortierenText = String(localized: "All photos from the last 30 days have been reviewed.")
    static let nochmalDurchsehen = String(localized: "Review Again")
    static let vorgemerktPruefen = String(localized: "Review Marked Photos")

    static let korbTitel = String(localized: "Marked for Trash")
    static let korbHinweis = String(localized: "Tap a photo to remove it from the trash selection.")
    static let korbEntfernenLabel = String(localized: "Remove from trash selection")
    static let schliessen = String(localized: "Close")
    static let abbrechen = String(localized: "Cancel")
    static let ok = String(localized: "OK")
    static let fehlerTitel = String(localized: "Something Went Wrong")
    static let schliessenFrageTitel = String(localized: "Marked Photos Remaining")
    static let ohneLoeschenSchliessen = String(localized: "Close Without Deleting")
    static let rechtFehlt = String(localized: "Your API key doesn’t allow this action.")

    static func korbButton(anzahl: Int) -> String {
        if anzahl == 1 {
            return String(localized: "Move 1 Photo to Trash")
        }
        return String(localized: "Move \(anzahl) Photos to Trash")
    }

    static func schliessenFrageText(anzahl: Int) -> String {
        if anzahl == 1 {
            return String(localized: "1 photo is still marked for trash. What would you like to do?")
        }
        return String(localized: "\(anzahl) photos are still marked for trash. What would you like to do?")
    }

    static func korbZaehler(anzahl: Int) -> String {
        String(localized: "\(anzahl) marked")
    }
}
