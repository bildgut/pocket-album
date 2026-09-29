import Foundation

/// Zerlegt eine Foto-Reihe in Reise-Etappen: zusammenhängende Zeiträume an
/// einem Ort, benannt nach dem häufigsten Ortsnamen darin.
///
/// Rein und abhängigkeitsfrei — kein SQLite, kein SwiftData, kein Netz, keine
/// Uhr. Alles, was die Erkennung weiß, kommt aus `[TripScanRow]`. Damit sind
/// Etappengrenzen ohne Umgebung prüfbar (siehe `TripSegmenterTests`).
///
/// Der Ortsname trennt bewusst **nicht**. Immich geokodiert serverseitig über
/// GeoNames und liefert in Großstädten Stadtteile: eine Tokio-Woche käme als
/// „Shinjuku", „Chiyoda", „Taitō", „Minato" an, aus fünf Etappen würden dreißig.
/// Getrennt wird deshalb räumlich, benannt wird nachträglich.
enum TripSegmenter {

    /// So viele Anker legen den Bezugspunkt einer Etappe fest.
    ///
    /// Der Bezugspunkt friert danach ein, statt mitzuwandern. Genau das trennt
    /// eine Zugfahrt ab: Fotos aus dem fahrenden Zug entfernen sich vom Startort
    /// und lösen den Ausbruch aus. Ein gleitender Bezugspunkt würde ihnen folgen
    /// und Tokio bis Kyoto zu einer einzigen Etappe verschmelzen.
    static let baseSampleSize = 25

    // MARK: - Einstiegspunkt

    /// - Parameter ignoredAssetIds: Fotos aus verworfenen Etappen.
    ///
    ///   Geschlüsselt auf Asset-IDs, nicht auf den Fingerabdruck der Etappe —
    ///   dieselbe Entscheidung wie bei `GeoIgnoredAsset` und aus demselben Grund:
    ///   Asset-IDs sind dauerhaft stabil, ein Fingerabdruck ändert sich, sobald ein
    ///   Foto hinzukommt. Eine verworfene Etappe käme sonst nach dem nächsten Sync
    ///   zurück, und ein Verschieben des Radius holte sie ohnehin alle wieder.
    ///
    ///   Ignorierte Fotos werden **nicht** aus der Segmentierung entfernt, anders
    ///   als bei `GeoMatcher.scan`. Dort sind es Einzelvorschläge, hier stützen sie
    ///   die Etappengrenzen ihrer Nachbarn: fehlten sie, verschöben sich Bezugspunkt
    ///   und Zeitfenster ringsum. Verworfen ist deshalb eine Etappe, deren Fotos
    ///   *vollständig* auf der Liste stehen.
    static func segment(rows: [TripScanRow],
                        parameters: TripParameters,
                        ignoredAssetIds: Set<String> = []) -> TripScanResult {

        var partialCount = 0
        var working: [TripScanRow] = []
        working.reserveCapacity(rows.count)

        for row in rows {
            if row.hasPartialCoordinate {
                // Weder Anker noch Waise. Gezählt, nicht verschluckt.
                partialCount += 1
                continue
            }
            working.append(row)
        }

        // Nach (Zeit, ID) statt nur nach Zeit: bei gleichem Zeitstempel wäre die
        // Reihenfolge sonst von der Eingabe abhängig, und damit auch das Ergebnis.
        working.sort(by: timeOrder)
        guard !working.isEmpty else { return .empty }

        let (anchors, implausible) = withoutImplausibleJumps(working.filter { $0.coordinate != nil })

        // Verworfene Anker verlieren nur ihre Koordinate, nicht ihren Platz: sie
        // dürfen wie Fotos ohne Ort zeitlich erben.
        var inheritors = working.filter(\.isOrphan) + implausible
        inheritors.sort(by: timeOrder)

        let staleIds = staleFixIds(anchors, parameters: parameters)
        let drafts = merge(split(anchors, parameters: parameters, staleIds: staleIds),
                           parameters: parameters, staleIds: staleIds)

        var members: [[TripScanRow]] = drafts.map(\.anchors)
        var unassigned: [String] = []
        for row in inheritors {
            if let index = segmentIndex(for: row.timestamp, in: drafts, parameters: parameters) {
                members[index].append(row)
            } else {
                unassigned.append(row.id)
            }
        }

        // Labels angleichen: `coordinate` heißt `(latitude:longitude:)`, `autoDetectHome`
        // erwartet `(lat:lon:)`. Die Reihenfolge stimmt, aber Swift verlangt künftig
        // gleiche Namen — ohne die Umbenennung wäre das später ein Fehler.
        let home = HighlightScorer.autoDetectHome(
            from: anchors.compactMap { $0.coordinate.map { (lat: $0.latitude, lon: $0.longitude) } }
        )

        var segments: [TripSegment] = []
        var hidden: [TripSegment] = []
        for (index, draft) in drafts.enumerated() {
            let segment = makeSegment(draft: draft,
                                      members: members[index].sorted(by: timeOrder),
                                      home: home,
                                      parameters: parameters,
                                      staleIds: staleIds,
                                      ignoredAssetIds: ignoredAssetIds)
            if segment.hiddenReason == nil { segments.append(segment) } else { hidden.append(segment) }
        }

        return TripScanResult(
            segments: segments,
            hiddenSegments: hidden,
            unassignedIds: unassigned,
            homeLatitude: home?.lat,
            homeLongitude: home?.lon,
            homeCountry: homeCountry(anchors: anchors, home: home),
            implausibleAnchorCount: implausible.count,
            staleFixCount: staleIds.count,
            partialCoordinateCount: partialCount
        )
    }

    private static func timeOrder(_ a: TripScanRow, _ b: TripScanRow) -> Bool {
        a.timestamp == b.timestamp ? a.id < b.id : a.timestamp < b.timestamp
    }

    // MARK: - Unmögliche Sprünge

    /// Trennt Anker ab, die von ihrem Vorgänger aus nicht erreichbar sind.
    ///
    /// Schwelle und Begründung stammen aus `GeoMatcher.pairPlausibility`: über
    /// 900 km/h ist entweder der Zeitstempel kaputt oder die Koordinate falsch.
    /// Ein einziges solches Foto darf keine Etappe erfinden — mitten in der
    /// Tokio-Woche stünde sonst ein Ein-Foto-Aufenthalt in Kanada.
    ///
    /// Verglichen wird gegen den zuletzt **angenommenen** Anker, nicht gegen den
    /// unmittelbaren Vorgänger. Sonst risse ein einzelner falscher Anker auch
    /// seinen korrekten Nachfolger mit.
    ///
    /// - Parameter anchors: nach Zeit aufsteigend sortiert.
    static func withoutImplausibleJumps(_ anchors: [TripScanRow]) -> (kept: [TripScanRow],
                                                                     rejected: [TripScanRow]) {
        var kept: [TripScanRow] = []
        var rejected: [TripScanRow] = []
        kept.reserveCapacity(anchors.count)

        for row in anchors {
            guard let last = kept.last,
                  let from = last.coordinate, let to = row.coordinate else {
                kept.append(row)
                continue
            }

            let kilometers = GeoMatcher.haversineMeters(from.latitude, from.longitude,
                                                        to.latitude, to.longitude) / 1_000
            // Unter einem Kilometer sagt die Geschwindigkeit nichts: zwei Fixes
            // 50 m und 2 s auseinander ergeben rechnerisch 90 km/h.
            guard kilometers > 1 else { kept.append(row); continue }

            let seconds = max(1, row.timestamp.timeIntervalSince(last.timestamp))
            if kilometers / (seconds / 3_600) > 900 {
                rejected.append(row)
            } else {
                kept.append(row)
            }
        }

        return (kept, rejected)
    }

    // MARK: - Hängengebliebene Fixes

    /// Wie viele Anker eine Abwesenheit höchstens umfassen darf, damit sie noch als
    /// solche geprüft wird.
    ///
    /// Ein Deckel gegen den ungünstigsten Fall: Ohne ihn liefe die Zwischenprüfung
    /// bei einer Serie von tausenden Aufnahmen in drei Stunden über alles. Wer so
    /// viel dazwischen aufgenommen hat, war ohnehin nicht kurz weg.
    static let staleLookbackLimit = 600

    /// Aufnahmen, deren Koordinate ein hängengebliebener GPS-Fix ist.
    ///
    /// Kennzeichen ist nicht die Wiederholung, sondern die **Rückkehr**: Derselbe
    /// bitgenaue Punkt taucht wieder auf, nachdem die Aufnahmen dazwischen weit weg
    /// waren. Ein Gerät ohne Empfang — in den Bergen, in der Seilbahn, im Tunnel —
    /// schreibt den zuletzt bekannten Standort weiter und liefert damit Belege für
    /// einen Ort, an dem niemand war.
    ///
    /// Nachgemessen an einer Bibliothek mit 106 000 verorteten Aufnahmen: Ein
    /// Kriterium allein auf Wiederholung („viele Aufnahmen auf demselben Punkt")
    /// hätte 23,5 % aller Anker erfasst — darunter Prag mit 715 völlig echten
    /// Aufnahmen auf einem Punkt. Erst die Rückkehr über eine weite Abwesenheit
    /// grenzt es auf rund zwanzig Tage ein. Die Unterscheidung ist auch in der
    /// Tagesstatistik sichtbar: viele Ortswechsel bei *wenigen* verschiedenen
    /// Punkten heißt hängengeblieben, viele Ortswechsel bei *vielen* Punkten heißt
    /// echte Fahrt.
    ///
    /// Verwandt mit `GeoMatcher.timestampCrowding`, das dieselbe Art Falle für
    /// Zeitstempel abfängt: Ein Wert, den zu viele Aufnahmen teilen, ist ein
    /// Rückfallwert und kein Messwert.
    ///
    /// - Parameter anchors: nach Zeit aufsteigend sortiert.
    static func staleFixIds(_ anchors: [TripScanRow],
                            parameters: TripParameters) -> Set<String> {
        guard anchors.count > 2, parameters.staleReturnCount > 0 else { return [] }

        let window = parameters.staleWindowHours * 3_600
        /// Punkt → Index der letzten Sichtung.
        var lastSeen: [Coordinate: Int] = [:]
        /// Punkt → die Abschnitte, in denen er im Widerspruch zu echten Fixes steht.
        var episodes: [Coordinate: [Episode]] = [:]

        for (index, row) in anchors.enumerated() {
            guard let coordinate = row.coordinate else { continue }
            let key = Coordinate(coordinate)
            defer { lastSeen[key] = index }

            guard let previous = lastSeen[key] else { continue }
            let elapsed = row.timestamp.timeIntervalSince(anchors[previous].timestamp)
            guard elapsed <= window else { continue }
            // Direkt aufeinanderfolgende Aufnahmen am selben Punkt sind eine Serie,
            // keine Rückkehr — dazwischen war niemand irgendwo.
            guard index - previous > 1, index - previous <= staleLookbackLimit else { continue }

            let wasAway = anchors[(previous + 1)..<index].contains { between in
                guard let other = between.coordinate else { return false }
                return GeoMatcher.haversineMeters(coordinate.latitude, coordinate.longitude,
                                                  other.latitude, other.longitude) / 1_000
                    > parameters.radiusKm
            }
            guard wasAway else { continue }

            var list = episodes[key] ?? []
            // Zur laufenden Episode gehört, was ihr *zeitlich* folgt — nicht, was
            // im Index direkt anschließt. Zwei Ausflüge kurz hintereinander sind
            // dasselbe Hin und Her; zwei Ausflüge im Abstand von Tagen nicht.
            if var last = list.last,
               anchors[previous].timestamp.timeIntervalSince(anchors[last.upper].timestamp) <= window {
                last.upper = index
                last.returns += 1
                list[list.count - 1] = last
            } else {
                list.append(Episode(lower: previous, upper: index, returns: 1))
            }
            episodes[key] = list
        }

        var stale: Set<String> = []
        for (key, list) in episodes {
            for episode in list where episode.returns >= parameters.staleReturnCount {
                for index in episode.lower...episode.upper {
                    guard let coordinate = anchors[index].coordinate,
                          Coordinate(coordinate) == key else { continue }
                    stale.insert(anchors[index].id)
                }
            }
        }
        return stale
    }

    /// Ein Abschnitt, in dem ein Punkt im Widerspruch zu echten Fixes steht.
    ///
    /// Die Begrenzung ist wesentlich und war anfangs falsch: Wird ein Punkt für den
    /// *ganzen* Durchlauf entwertet, verliert man auch die Belege außerhalb des
    /// Widerspruchs. Am 19.09.2017 hieße das: Die Rückkehr nach Toyama am Abend
    /// wäre nicht mehr erkennbar, und die Abendaufnahmen landeten in der
    /// Alpenroute-Etappe. Misstrauen gilt nur dort, wo tatsächlich widersprochen
    /// wird — davor und danach ist derselbe Punkt ein brauchbarer Beleg.
    private struct Episode {
        let lower: Int
        var upper: Int
        var returns: Int
    }

    /// Ein Punkt als Wörterbuchschlüssel — bitgenau, ohne Rundung.
    ///
    /// Die Bitgenauigkeit ist der Kern: Echte GPS-Fixes zittern, sechs identische
    /// Nachkommastellen über Stunden sind ein weitergeschriebener Wert. Ein
    /// gerundeter Schlüssel fasste echte Fixes derselben Gegend zusammen und
    /// verlöre genau diese Unterscheidung.
    private struct Coordinate: Hashable {
        let latitude: Double
        let longitude: Double

        init(_ coordinate: (latitude: Double, longitude: Double)) {
            self.latitude = coordinate.latitude
            self.longitude = coordinate.longitude
        }
    }

    // MARK: - Segmentierung

    /// Eine Etappe im Aufbau: ihre Anker und deren Median.
    ///
    /// `start`/`end` sind gespeichert, nicht gerechnet: ein leerer Entwurf
    /// entsteht gar nicht erst, statt sich später an einem `first!` zu rächen.
    struct Draft: Sendable {
        var anchors: [TripScanRow]
        var latitude: Double
        var longitude: Double
        var start: Date
        var end: Date
    }

    /// `nil` für eine leere Reihe — ein Entwurf ohne Anker hat keinen Ort.
    private static func makeDraft(_ rows: [TripScanRow], staleIds: Set<String>) -> Draft? {
        guard let first = rows.first, let last = rows.last else { return nil }
        let position = position(of: rows, staleIds: staleIds)
        return Draft(anchors: rows,
                     latitude: position.latitude,
                     longitude: position.longitude,
                     start: first.timestamp,
                     end: last.timestamp)
    }

    /// Der Median einer Etappe — aus den echten Fixes, solange es welche gibt.
    ///
    /// Ohne diese Einschränkung zöge ein mitgeschleppter Standwert den Median an
    /// den Ort zurück, an dem niemand war: Die Alpenroute-Etappe des 19.09.2017
    /// trüge die Koordinate von Toyama, weil dort die Mehrheit der Aufnahmen
    /// verortet ist.
    ///
    /// Der Rückfall auf *alle* Zeilen ist ebenso wichtig: Zu Hause sind womöglich
    /// alle Anker Standwerte, und ohne ihn hätte die Etappe gar keine Position.
    private static func position(of rows: [TripScanRow],
                                 staleIds: Set<String>) -> (latitude: Double, longitude: Double) {
        let real = rows.filter { !staleIds.contains($0.id) }.compactMap(\.coordinate)
        let coordinates = real.isEmpty ? rows.compactMap(\.coordinate) : real
        return (GeoMatcher.median(coordinates.map(\.latitude)),
                GeoMatcher.median(coordinates.map(\.longitude)))
    }

    /// Läuft die Anker in Zeitfolge ab und trennt an zwei Bedingungen:
    /// `breakoutRunLength` **echte** Anker in Folge außerhalb des Radius, oder eine
    /// Pause länger als `maxGapDays`.
    ///
    /// - Parameter anchors: nach Zeit aufsteigend sortiert.
    /// - Parameter staleIds: Aufnahmen mit hängengebliebenem Fix (`staleFixIds`).
    ///   Sie bleiben Teil ihrer Etappe und zählen ersatzweise zum Bezugspunkt, aber
    ///   sie lösen keine Trennung aus **und beenden keinen laufenden Ausbruch**.
    ///
    ///   Der zweite Teil ist der wesentliche. Vorher setzte ein Standwert mitten in
    ///   einem Ausbruch den Zähler zurück, weil er im Umkreis des alten
    ///   Bezugspunkts liegt — und genau daran zerfiel ein Reisetag mit
    ///   abwechselnden Ankern in ein Dutzend Bruchstücke.
    static func split(_ anchors: [TripScanRow],
                      parameters: TripParameters,
                      staleIds: Set<String> = []) -> [Draft] {
        guard !anchors.isEmpty else { return [] }

        let maxGap = parameters.maxGapDays * 86_400
        var drafts: [Draft] = []
        var current: [TripScanRow] = []
        var base: (lat: Double, lon: Double) = (0, 0)
        /// Anker außerhalb des Radius, die noch nicht als Ausbruch gelten — samt der
        /// Standwerte, die zeitlich zwischen ihnen liegen.
        var pending: [TripScanRow] = []
        /// Wie viele davon *echte* Ausbrüche sind. Nur sie zählen zur Schwelle.
        var breakouts = 0

        func close(_ rows: [TripScanRow]) {
            if let draft = makeDraft(rows, staleIds: staleIds) { drafts.append(draft) }
        }

        func recomputeBase() {
            // Nur solange die Stichprobe noch wächst — danach steht der Bezugspunkt.
            guard current.count <= baseSampleSize else { return }
            let median = position(of: current, staleIds: staleIds)
            base = (median.latitude, median.longitude)
        }

        for row in anchors {
            guard let coordinate = row.coordinate else { continue }

            if current.isEmpty {
                current = [row]
                recomputeBase()
                continue
            }

            let previous = pending.last ?? current[current.count - 1]
            if row.timestamp.timeIntervalSince(previous.timestamp) > maxGap {
                // Die Pause trennt in jedem Fall. Was noch als Ausbruch in der
                // Schwebe hing, gehört zum abgeschlossenen Teil.
                close(current + pending)
                pending = []
                breakouts = 0
                current = [row]
                recomputeBase()
                continue
            }

            if staleIds.contains(row.id) {
                // Ein Standwert belegt nichts — weder einen Ortswechsel noch eine
                // Rückkehr. Er reiht sich dort ein, wo er zeitlich hingehört, damit
                // die Zeitfolge in beiden Listen erhalten bleibt.
                if pending.isEmpty { current.append(row) } else { pending.append(row) }
                recomputeBase()
                continue
            }

            let kilometers = GeoMatcher.haversineMeters(base.lat, base.lon,
                                                        coordinate.latitude,
                                                        coordinate.longitude) / 1_000
            if kilometers <= parameters.radiusKm {
                // Zurück im Umkreis: die Schwebenden waren ein Ausflug, kein Umzug.
                // Anhängen genügt, Sortieren wäre falsch teuer — `pending` und
                // `row` liegen zeitlich hinter allem in `current`.
                current.append(contentsOf: pending)
                pending = []
                breakouts = 0
                current.append(row)
                recomputeBase()
                continue
            }

            pending.append(row)
            breakouts += 1
            if breakouts >= max(1, parameters.breakoutRunLength) {
                close(current)
                current = pending
                pending = []
                breakouts = 0
                recomputeBase()
            }
        }

        close(current + pending)
        return drafts
    }

    /// Führt benachbarte Etappen zusammen, die am selben Ort liegen.
    ///
    /// Nötig wegen des eingefrorenen Bezugspunkts: Eine Tagestour ins Umland und
    /// zurück erzeugt drei Abschnitte — Stadt, Umland, Stadt. Liegen erster und
    /// dritter im selben Umkreis und ist der mittlere ebenfalls nah genug, war es
    /// nie ein Ortswechsel.
    ///
    /// Zusammengeführt wird nur, was **beides** erfüllt: Bezugspunkte innerhalb
    /// des Radius und Zeitlücke innerhalb `maxGapDays`. Die Zeitbedingung ist
    /// wesentlich, sonst verschmölze der zweite Tokio-Aufenthalt einer Reise mit
    /// dem ersten und die Etappe umfasste plötzlich die ganze Reise.
    static func merge(_ drafts: [Draft],
                      parameters: TripParameters,
                      staleIds: Set<String> = []) -> [Draft] {
        guard drafts.count > 1 else { return drafts }

        let maxGap = parameters.maxGapDays * 86_400
        var merged: [Draft] = [drafts[0]]

        for draft in drafts.dropFirst() {
            var last = merged[merged.count - 1]
            let kilometers = GeoMatcher.haversineMeters(last.latitude, last.longitude,
                                                        draft.latitude, draft.longitude) / 1_000
            let gap = draft.start.timeIntervalSince(last.end)

            if kilometers <= parameters.radiusKm && gap <= maxGap {
                // Nur Nachbarn werden zusammengeführt, und die Abschnitte sind
                // überschneidungsfrei — Anhängen erhält die Zeitreihenfolge.
                last.anchors.append(contentsOf: draft.anchors)
                let position = position(of: last.anchors, staleIds: staleIds)
                last.latitude = position.latitude
                last.longitude = position.longitude
                last.end = draft.end
                merged[merged.count - 1] = last
            } else {
                merged.append(draft)
            }
        }

        return merged
    }

    // MARK: - Fotos ohne Ort einsortieren

    /// Welche Etappe ein Foto ohne Koordinate erbt.
    ///
    /// Fällt der Zeitpunkt in eine Etappe, ist die Sache klar. Fällt er in die
    /// Lücke dazwischen, entscheidet die zeitliche Nähe — aber nur, wenn sie
    /// deutlich ist: die entferntere Seite muss mindestens doppelt so weit weg
    /// sein. Bei Gleichstand wird nicht geraten, das Foto bleibt im Rest.
    ///
    /// In jedem Fall gilt `maxGapDays` als Obergrenze. Ohne sie erbte ein Screenshot
    /// vom Juli die Kyoto-Etappe vom April, nur weil sonst nichts näher lag.
    ///
    /// - Parameter drafts: nach Zeit aufsteigend, überschneidungsfrei.
    static func segmentIndex(for timestamp: Date,
                             in drafts: [Draft],
                             parameters: TripParameters) -> Int? {
        guard !drafts.isEmpty else { return nil }

        // Erster Abschnitt, der nicht vor `timestamp` endet.
        var low = 0
        var high = drafts.count
        while low < high {
            let mid = low + (high - low) / 2
            if drafts[mid].end < timestamp { low = mid + 1 } else { high = mid }
        }

        if low < drafts.count, drafts[low].start <= timestamp { return low }

        let maxGap = parameters.maxGapDays * 86_400
        let beforeIndex = low - 1
        let afterIndex = low < drafts.count ? low : nil

        let beforeDistance = beforeIndex >= 0
            ? timestamp.timeIntervalSince(drafts[beforeIndex].end)
            : Double.infinity
        let afterDistance = afterIndex.map { drafts[$0].start.timeIntervalSince(timestamp) }
            ?? Double.infinity

        let (nearIndex, nearDistance, farDistance) = beforeDistance <= afterDistance
            ? (beforeIndex, beforeDistance, afterDistance)
            : (afterIndex ?? -1, afterDistance, beforeDistance)

        guard nearIndex >= 0, nearDistance <= maxGap else { return nil }
        // Eindeutig nur, wenn die andere Seite klar weiter weg ist. `.infinity`
        // erfüllt das von selbst — gibt es nur eine Seite, gibt es keinen Zweifel.
        guard farDistance >= nearDistance * 2 else { return nil }
        return nearIndex
    }

    // MARK: - Etappe bauen

    private static func makeSegment(draft: Draft,
                                    members: [TripScanRow],
                                    home: (lat: Double, lon: Double)?,
                                    parameters: TripParameters,
                                    staleIds: Set<String>,
                                    ignoredAssetIds: Set<String>) -> TripSegment {
        let anchors = draft.anchors
        // Ortsname und Ausdehnung aus den echten Fixes, solange es welche gibt —
        // aus demselben Grund wie beim Median (siehe `position(of:staleIds:)`).
        // Sonst hieße die Alpenroute-Etappe „Toyama" und meldete null Ausdehnung.
        let realAnchors = anchors.filter { !staleIds.contains($0.id) }
        let describing = realAnchors.isEmpty ? anchors : realAnchors
        let coordinates = describing.compactMap(\.coordinate)
        let latitude = draft.latitude
        let longitude = draft.longitude
        let assetIds = members.map(\.id)
        let fingerprint = AssetSetFingerprint.make(assetIds, prefix: "trip")

        let distanceFromHome = home.map {
            HighlightScorer.haversineKm(lat1: latitude, lon1: longitude,
                                        lat2: $0.lat, lon2: $0.lon)
        }

        let reason: TripHiddenReason? = {
            // Vollständig, nicht teilweise: Kommt zu einer verworfenen Etappe ein
            // neues Foto hinzu, ist an diesem Ort etwas Neues passiert — dann darf
            // sie wieder auftauchen.
            if !ignoredAssetIds.isEmpty,
               assetIds.allSatisfy(ignoredAssetIds.contains) { return .ignored }
            if let minimum = parameters.minHomeDistanceKm,
               let distance = distanceFromHome, distance < minimum { return .nearHome }
            if assetIds.count < parameters.minPhotos { return .belowMinPhotos }
            return nil
        }()

        return TripSegment(
            id: fingerprint,
            label: label(for: describing, latitude: latitude, longitude: longitude),
            country: mostCommon(describing.compactMap(\.country)),
            start: members.first?.timestamp ?? draft.start,
            end: members.last?.timestamp ?? draft.end,
            assetIds: assetIds,
            anchorCount: anchors.count,
            inheritedCount: members.count - anchors.count,
            latitude: latitude,
            longitude: longitude,
            spreadKm: GeoMatcher.spreadMeters(of: coordinates) / 1_000,
            distanceFromHomeKm: distanceFromHome,
            hiddenReason: reason
        )
    }

    private static func label(for anchors: [TripScanRow],
                              latitude: Double, longitude: Double) -> String {
        if let city = mostCommon(anchors.compactMap(\.city)) { return city }
        if let country = mostCommon(anchors.compactMap(\.country)) { return country }
        return HighlightScorer.formatCoordinate(lat: latitude, lon: longitude)
    }

    /// Wie weit um den Heimatort herum nach dem Heimatland gefragt wird.
    ///
    /// Großzügig: Es geht um das Land, nicht um den Ort. Ein Wochenende an der
    /// Ostsee liegt 200 km entfernt und ist trotzdem dasselbe Land — die
    /// zusätzlichen Stimmen schaden nicht, sie bestätigen. Erst jenseits davon
    /// beginnt das Ausland regelmäßig mitzuzählen.
    static let homeCountryRadiusKm = 300.0

    /// Die häufigste Landesangabe rund um den Heimatort.
    ///
    /// Nicht einfach die häufigste Landesangabe der ganzen Menge: Beim Aufteilen
    /// eines Reisealbums wäre das das Reiseland — und dann trüge ausgerechnet die
    /// Auslandsreise kein Land im Namen.
    static func homeCountry(anchors: [TripScanRow],
                            home: (lat: Double, lon: Double)?) -> String? {
        guard let home else { return nil }
        let nearby = anchors.filter { row in
            guard let coordinate = row.coordinate else { return false }
            return HighlightScorer.haversineKm(lat1: coordinate.latitude,
                                               lon1: coordinate.longitude,
                                               lat2: home.lat, lon2: home.lon)
                <= homeCountryRadiusKm
        }
        return mostCommon(nearby.compactMap(\.country))
    }

    /// Häufigster Wert, bei Gleichstand alphabetisch.
    ///
    /// Der Gleichstand muss entschieden werden: `max` über ein Dictionary greift
    /// sonst einen beliebigen Eintrag heraus, und dessen Reihenfolge ist zwischen
    /// zwei Läufen unbestimmt. Der Vorschlag hieße bei jedem Scan anders.
    static func mostCommon(_ values: [String]) -> String? {
        var counts: [String: Int] = [:]
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            counts[trimmed, default: 0] += 1
        }
        return counts.max {
            $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value
        }?.key
    }
}
