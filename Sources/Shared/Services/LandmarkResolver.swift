import Foundation

/// Macht aus dem Namen, den das Bildmodell genannt hat, eine Koordinate — und aus
/// der Trefferlage ein Urteil darüber, wie belastbar sie ist.
///
/// Der eigentliche Grund für diesen Umweg: Ein Sprachmodell, das Koordinaten
/// nennt, klingt genauso überzeugt, wenn es sie erfindet. Eine Kartendatenbank
/// findet einen Namen entweder oder nicht — und wenn sie ihn zweihundertmal
/// findet, ist genau das die Auskunft, die man braucht.
actor LandmarkResolver {

    static let shared = LandmarkResolver()

    /// Wie viele Treffer je Abfrage betrachtet werden. Mehr als einer ist nötig,
    /// um Streuung überhaupt sehen zu können.
    static let matchLimit = 5

    /// Mindestabstand zwischen zwei Kartenanfragen — wie in ``GeocoderCache``.
    /// MKLocalSearch hat undokumentierte Grenzen, und Drosselung sieht von außen
    /// aus wie „nichts gefunden".
    private static let minInterval: TimeInterval = 1.1

    /// Rohtreffer je normalisierter Abfrage. Bewusst die Treffer und nicht das
    /// Urteil: Dasselbe Wahrzeichen kann bei anderem Foto einen anderen Anker und
    /// eine andere Sicherheit haben, die Karte antwortet aber gleich.
    private var cache: [String: [AddressMatch]] = [:]

    private var lastRequestAt: Date = .distantPast

    // MARK: - Auflösen

    /// Sucht den Ort. `nil`, wenn die Karte den Namen nicht kennt — dann verfällt
    /// der Vorschlag ersatzlos, statt auf eine geratene Koordinate auszuweichen.
    func resolve(_ guess: LandmarkGuess,
                 nearestAnchor: LandmarkAnchorHint?,
                 minConfidence: Int) async -> LandmarkResolution? {
        guard guess.recognized else { return nil }

        for query in Self.queryChain(for: guess) {
            let matches = await matches(for: query)
            guard !matches.isEmpty else { continue }
            return Self.evaluate(matches: matches, guess: guess,
                                 nearestAnchor: nearestAnchor,
                                 minConfidence: minConfidence,
                                 usedQuery: query)
        }
        AppLogger.ui.debug("Wahrzeichen: Karte kennt '\(guess.name)' nicht")
        return nil
    }

    /// Von der vollständigen Zeile zum bloßen Namen. Höchstens drei Stufen, damit
    /// ein unauffindbarer Name nicht die Drosselung mehrerer Fotos aufbraucht.
    static func queryChain(for guess: LandmarkGuess) -> [String] {
        var chain = [guess.searchQuery]
        if let city = guess.city { chain.append("\(guess.name), \(city)") }
        if let country = guess.country { chain.append("\(guess.name), \(country)") }
        chain.append(guess.name)

        var seen = Set<String>()
        return chain
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            .prefix(3)
            .map { $0 }
    }

    private func matches(for query: String) async -> [AddressMatch] {
        let key = query.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if let cached = cache[key] { return cached }

        await throttle()
        let matches = await AddressSearchService.shared.search(query, limit: Self.matchLimit)
        // `search` meldet Netzfehler und „nichts gefunden" beide als leere Liste.
        // Für die Sitzung wird das gemerkt, damit dieselbe Reise nicht vierzigmal
        // dieselbe Anfrage stellt — dauerhaft gespeichert wird es nicht.
        cache[key] = matches
        return matches
    }

    /// Reserviert den Slot **vor** dem Warten. Sonst schlafen zehn gleichzeitige
    /// Aufrufer alle bis zur selben Uhrzeit und feuern dann gemeinsam los.
    private func throttle() async {
        let now = Date()
        let earliest = lastRequestAt.addingTimeInterval(Self.minInterval)
        let slot = max(now, earliest)
        lastRequestAt = slot

        let delay = slot.timeIntervalSince(now)
        if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
    }

    // MARK: - Bewertung (rein)

    /// Wiegt die Trefferlage gegen das ab, was das Modell behauptet hat.
    ///
    /// Vier voneinander unabhängige Zweifel — Land, Streuung, Gegenprobe am
    /// nächsten Anker, Selbsteinschätzung. Keiner davon ist ein Beweis; deshalb
    /// setzt sich immer der schwerste durch, statt sie gegeneinander aufzurechnen.
    static func evaluate(matches: [AddressMatch],
                         guess: LandmarkGuess,
                         nearestAnchor: LandmarkAnchorHint?,
                         minConfidence: Int,
                         usedQuery: String) -> LandmarkResolution? {
        guard let first = matches.first else { return nil }

        // 1. Land. Ein abweichender Ländercode wirft den Treffer raus — aber wenn
        //    dann nichts übrig bleibt, wird trotzdem gezeigt statt geschwiegen:
        //    Beim Land irrt das Bildmodell öfter als die Karte beim Namen, und der
        //    Nutzer soll die Diskrepanz sehen können.
        var considered = matches
        var countryDoubt: LandmarkDoubt?
        if let code = guess.countryCode?.uppercased(), !code.isEmpty {
            let matching = matches.filter { match in
                match.countryCode.map { $0.uppercased() == code } ?? true
            }
            if matching.isEmpty {
                countryDoubt = LandmarkDoubt(reason: .countryMismatch(
                    guessed: guess.country ?? code,
                    resolved: first.country ?? first.countryCode ?? "unbekannt"
                ))
            } else {
                considered = matching
            }
        }

        let best = considered[0]
        let spread = GeoMatcher.spreadMeters(
            of: considered.map { (latitude: $0.latitude, longitude: $0.longitude) }
        )
        let spreadKm = spread / 1000

        var verdict = LandmarkPlausibility.ok

        // 2. Streuung. „Rathaus" trifft zweihundertmal in Deutschland — genau das
        //    soll hier hängen bleiben. Führt ein Treffer namentlich deutlich, ist
        //    die Streuung dagegen bloß Beifang der Suche.
        if spreadKm > 50 {
            let doubt = LandmarkDoubt(reason: .scatteredMatches(km: spreadKm))
            verdict = nameLeads(best, among: considered, guess: guess)
                ? .flagged(doubt)
                : .rejected(doubt)
        } else if spreadKm > 2 {
            verdict = .flagged(LandmarkDoubt(reason: .scatteredMatches(km: spreadKm)))
        }

        if let countryDoubt {
            verdict = worse(verdict, .flagged(countryDoubt))
        }

        // 3. Gegenprobe: Ein Foto mit GPS von wenigen Stunden davor oder danach ist
        //    ein härterer Beleg als jede Bilderkennung.
        if let anchor = nearestAnchor, anchor.gapSeconds <= 24 * 3600 {
            let meters = GeoMatcher.haversineMeters(best.latitude, best.longitude,
                                                    anchor.latitude, anchor.longitude)
            if meters > 1_000_000 {
                verdict = worse(verdict, .flagged(LandmarkDoubt(reason: .farFromNearestAnchor(
                    km: meters / 1000,
                    gapHours: Double(anchor.gapSeconds) / 3600
                ))))
            }
        }

        // 4. Selbsteinschätzung. Unter 50 % hat das Modell selbst gesagt, dass es
        //    nicht darauf wetten würde — dann tun wir es auch nicht.
        if guess.confidence < 50 {
            verdict = worse(verdict, .rejected(LandmarkDoubt(
                reason: .lowConfidence(guess.confidence))))
        } else if guess.confidence < minConfidence {
            verdict = worse(verdict, .flagged(LandmarkDoubt(
                reason: .lowConfidence(guess.confidence))))
        }

        return LandmarkResolution(
            latitude: best.latitude,
            longitude: best.longitude,
            displayName: best.name,
            displayDetail: best.detail,
            matchCount: matches.count,
            spreadMeters: Int(spread.rounded()),
            usedQuery: usedQuery,
            plausibility: verdict
        )
    }

    /// Ob der erste Treffer den gesuchten Namen trägt und die anderen nicht.
    private static func nameLeads(_ best: AddressMatch,
                                  among matches: [AddressMatch],
                                  guess: LandmarkGuess) -> Bool {
        let wanted = LandmarkNameGuard.normalize(guess.name)
        guard !wanted.isEmpty else { return false }
        guard LandmarkNameGuard.normalize(best.name).contains(wanted) else { return false }
        return !matches.dropFirst().contains {
            LandmarkNameGuard.normalize($0.name).contains(wanted)
        }
    }

    private static func worse(_ a: LandmarkPlausibility,
                              _ b: LandmarkPlausibility) -> LandmarkPlausibility {
        rank(b) > rank(a) ? b : a
    }

    private static func rank(_ value: LandmarkPlausibility) -> Int {
        switch value {
        case .ok: return 0
        case .flagged: return 1
        case .rejected: return 2
        }
    }
}
