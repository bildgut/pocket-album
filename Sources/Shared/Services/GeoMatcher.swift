import Foundation

/// Findet Aufnahmen ohne Koordinaten, die zeitlich zwischen Aufnahmen *mit*
/// Koordinaten liegen, und schlägt eine Koordinate für sie vor.
///
/// Rein und abhängigkeitsfrei — kein SQLite, kein SwiftData, kein Netz, keine
/// Uhr. Alles, was der Abgleich weiß, kommt aus `[GeoScanRow]`. Damit ist der
/// gesamte Algorithmus ohne Umgebung testbar (siehe `GeoMatcherTests`).
enum GeoMatcher {

    // MARK: - Einstiegspunkt

    /// Ein Durchlauf, zwei Modi.
    ///
    /// Paar- und Cluster-Modus teilen sich Filterung, Sortierung und die
    /// Einteilung in Anker und Waisen — sonst könnten beide Ansichten für
    /// dieselbe Bibliothek verschiedene Bestände melden.
    static func scan(rows: [GeoScanRow],
                     parameters: GeoParameters,
                     ignoredIds: Set<String> = []) -> GeoScanResult {

        var partialCount = 0
        var working: [GeoScanRow] = []
        working.reserveCapacity(rows.count)

        for row in rows where !ignoredIds.contains(row.id) {
            if row.hasPartialCoordinate {
                // Weder Anker (halbe Koordinate) noch Waise (Übernehmen würde die
                // vorhandene Hälfte überschreiben). Gezählt, nicht verschluckt.
                partialCount += 1
                continue
            }
            working.append(row)
        }

        // Nach (Zeit, ID) statt nur nach Zeit: bei gleichem Zeitstempel wäre die
        // Reihenfolge sonst von der Eingabe abhängig, und damit auch das Ergebnis.
        working.sort {
            $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp
        }

        let anchorCount = working.count { $0.coordinate != nil }
        let orphanCount = working.count { $0.isOrphan }

        let crowding = timestampCrowding(working)
        let pairResult = pairSuggestions(sorted: working, parameters: parameters,
                                         crowding: crowding)
        let clusterResult = clusters(sorted: working, parameters: parameters,
                                     crowding: crowding)
        let clusteredOrphanIds = Set(clusterResult.kept.flatMap(\.orphanIds))
        let orphanSessionResult = orphanSessions(
            sorted: working,
            clusteredOrphanIds: clusteredOrphanIds,
            parameters: parameters,
            crowding: crowding
        )

        return GeoScanResult(
            pairs: pairResult.kept.sorted(by: suggestionOrder),
            suppressedPairs: pairResult.suppressed.sorted(by: suggestionOrder),
            clusters: clusterResult.kept.sorted(by: clusterOrder),
            suppressedClusters: clusterResult.suppressed.sorted(by: clusterOrder),
            orphanSessions: orphanSessionResult,
            unmatchedOrphans: unmatchedOrphans(
                sorted: working,
                matchedIds: Set(pairResult.kept.map(\.orphanId)),
                suppressedIds: Set(pairResult.suppressed.map(\.orphanId))
            ),
            anchorCount: anchorCount,
            orphanCount: orphanCount,
            partialCoordinateCount: partialCount
        )
    }

    // MARK: - Waisen ohne Vorschlag

    /// Die Waisen, für die der Paar-Modus nichts Übernehmbares hat.
    ///
    /// Maßgeblich ist allein `pairs` — nicht die Cluster: Ein Cluster-Vorschlag
    /// steht und fällt mit dem gewählten Sitzungsfenster, und wer den Regler
    /// bewegt, soll nicht Kandidaten verlieren, die er gerade prüfen wollte.
    /// Steht die Waise in `suppressedPairs`, bleibt sie Kandidat und wird als
    /// solche ausgewiesen.
    static func unmatchedOrphans(sorted: [GeoScanRow],
                                 matchedIds: Set<String>,
                                 suppressedIds: Set<String>) -> [GeoUnmatchedOrphan] {
        // `sorted` ist nach Zeit sortiert, also auch diese Teilmenge.
        let anchors = sorted.filter { $0.coordinate != nil }

        return sorted.compactMap { row in
            guard row.isOrphan, !matchedIds.contains(row.id) else { return nil }
            let nearest = nearestAnchor(to: row.timestamp, in: anchors)
            return GeoUnmatchedOrphan(
                id: row.id,
                timestamp: row.timestamp,
                nearestAnchorGapSeconds: nearest?.gapSeconds,
                nearestAnchorLatitude: nearest?.latitude,
                nearestAnchorLongitude: nearest?.longitude,
                hadSuppressedSuggestion: suppressedIds.contains(row.id)
            )
        }
    }

    /// Der zeitlich nächste Anker, mit Abstand ohne Vorzeichen.
    ///
    /// Binärsuche statt linearem Durchlauf: Bei 155.000 Zeilen wäre das sonst der
    /// einzige quadratische Schritt des Scans.
    /// - Parameter anchors: aufsteigend nach Zeit sortiert, alle mit Koordinate.
    static func nearestAnchor(to timestamp: Date, in anchors: [GeoScanRow])
        -> (gapSeconds: Int, latitude: Double, longitude: Double)? {
        guard !anchors.isEmpty else { return nil }

        // Erste Position, deren Zeit nicht mehr vor `timestamp` liegt.
        var low = 0
        var high = anchors.count
        while low < high {
            let mid = low + (high - low) / 2
            if anchors[mid].timestamp < timestamp { low = mid + 1 } else { high = mid }
        }

        var best: (gap: Double, row: GeoScanRow)?
        if low < anchors.count {
            best = (anchors[low].timestamp.timeIntervalSince(timestamp), anchors[low])
        }
        if low > 0 {
            let gap = timestamp.timeIntervalSince(anchors[low - 1].timestamp)
            if best == nil || gap < best!.gap { best = (gap, anchors[low - 1]) }
        }

        guard let best, let coordinate = best.row.coordinate else { return nil }
        return (Int(best.gap.rounded()), coordinate.latitude, coordinate.longitude)
    }

    /// Beste zuerst; die weiteren Kriterien machen die Reihenfolge eindeutig.
    private static func suggestionOrder(_ a: GeoSuggestion, _ b: GeoSuggestion) -> Bool {
        if a.confidence != b.confidence { return a.confidence > b.confidence }
        if a.orphanTimestamp != b.orphanTimestamp { return a.orphanTimestamp < b.orphanTimestamp }
        return a.orphanId < b.orphanId
    }

    /// Die größte Ausbeute zuerst, dann die verlässlichste.
    private static func clusterOrder(_ a: GeoCluster, _ b: GeoCluster) -> Bool {
        if a.missingCount != b.missingCount { return a.missingCount > b.missingCount }
        if a.confidence != b.confidence { return a.confidence > b.confidence }
        return a.id < b.id
    }

    // MARK: - Sicherheits-Schwelle

    /// Ob ein Eintrag die Schwelle passiert.
    ///
    /// Der einzige Ort, an dem diese Bedingung steht. Sie entscheidet, was ein
    /// einziger Knopfdruck auf den Server schreibt — und das ist auf Servern ohne
    /// Null-Unterstützung unumkehrbar. Eine zweite Fassung derselben Bedingung
    /// wäre eine, die eines Tages nicht mehr mitgeändert wird.
    ///
    /// `.all` lässt alles durch, auch räumlich Markiertes: Ohne Schwelle bleibt
    /// die Liste die heutige.
    static func passes(confidence: Int,
                       plausibility: GeoPlausibility,
                       atOrAbove threshold: GeoConfidenceThreshold) -> Bool {
        guard threshold.isActive else { return true }
        return confidence >= threshold.rawValue && plausibility == .ok
    }

    /// Die Sessions, die eine Schwelle passieren — sicherste zuerst.
    ///
    /// `plausibility == .ok` steht **neben** der Zahl, nicht statt ihrer: Das
    /// Etikett bildet nur den räumlichen Befund ab (siehe Kommentar an seiner
    /// Bildung), die Prüfung hier auch den zeitlichen. Wer eine markierte Session
    /// trotzdem will, hakt sie einzeln an.
    ///
    /// `cap` gehört mit hierher, damit „was gelistet ist" und „was ausgewählt
    /// wird" aus einer einzigen Rechnung stammen. Ein Deckel in der Ansicht und
    /// eine Auswahl im Modell könnten auseinanderlaufen — und dann bestätigte man
    /// Einträge, die man nie gesehen hat.
    static func filter(clusters: [GeoCluster],
                       atOrAbove threshold: GeoConfidenceThreshold,
                       dateFilter: GeoDateFilter = .all,
                       sortOrder: GeoSortOrder = .confidence,
                       now: Date = Date(),
                       cap: Int) -> [GeoCluster] {
        guard threshold.isActive || dateFilter.isActive || sortOrder != .confidence else {
            return Array(clusters.prefix(cap))
        }
        let kept = clusters.filter {
            passes(confidence: $0.confidence, plausibility: $0.plausibility,
                   atOrAbove: threshold)
                && dateFilter.includes($0.end, now: now)
        }
        let sorted: [GeoCluster]
        switch sortOrder {
        case .confidence:
            sorted = kept.sorted(by: threshold.isActive ? confidenceOrder : clusterOrder)
        case .dateNewest:
            sorted = kept.sorted {
                $0.start != $1.start ? $0.start > $1.start : confidenceOrder($0, $1)
            }
        case .dateOldest:
            sorted = kept.sorted {
                $0.start != $1.start ? $0.start < $1.start : confidenceOrder($0, $1)
            }
        case .closestDistance:
            sorted = kept.sorted {
                $0.spatialSpreadMeters != $1.spatialSpreadMeters
                    ? $0.spatialSpreadMeters < $1.spatialSpreadMeters
                    : confidenceOrder($0, $1)
            }
        }
        return Array(sorted.prefix(cap))
    }

    /// Dasselbe für den Paar-Modus. `suggestionOrder` sortiert bereits nach
    /// Konfidenz absteigend — es bleibt derselbe Vergleich wie im Scan.
    static func filter(suggestions: [GeoSuggestion],
                       atOrAbove threshold: GeoConfidenceThreshold,
                       dateFilter: GeoDateFilter = .all,
                       sortOrder: GeoSortOrder = .confidence,
                       now: Date = Date(),
                       cap: Int) -> [GeoSuggestion] {
        guard threshold.isActive || dateFilter.isActive || sortOrder != .confidence else {
            return Array(suggestions.prefix(cap))
        }
        let kept = suggestions.filter {
            passes(confidence: $0.confidence, plausibility: $0.plausibility,
                   atOrAbove: threshold)
                && dateFilter.includes($0.orphanTimestamp, now: now)
        }
        let sorted: [GeoSuggestion]
        switch sortOrder {
        case .confidence:
            sorted = kept.sorted(by: suggestionOrder)
        case .dateNewest:
            sorted = kept.sorted {
                if $0.orphanTimestamp != $1.orphanTimestamp {
                    return $0.orphanTimestamp > $1.orphanTimestamp
                }
                return suggestionOrder($0, $1)
            }
        case .dateOldest:
            sorted = kept.sorted {
                if $0.orphanTimestamp != $1.orphanTimestamp {
                    return $0.orphanTimestamp < $1.orphanTimestamp
                }
                return suggestionOrder($0, $1)
            }
        case .closestDistance:
            sorted = kept.sorted {
                let distA = $0.anchorDistanceMeters ?? Int.max
                let distB = $1.anchorDistanceMeters ?? Int.max
                if distA != distB { return distA < distB }
                if $0.nearestGapSeconds != $1.nearestGapSeconds {
                    return $0.nearestGapSeconds < $1.nearestGapSeconds
                }
                return suggestionOrder($0, $1)
            }
        }
        return Array(sorted.prefix(cap))
    }

    /// Anders als `clusterOrder`: Hier steht die Verlässlichkeit vor der Ausbeute,
    /// denn genau danach hat der Nutzer gefragt.
    private static func confidenceOrder(_ a: GeoCluster, _ b: GeoCluster) -> Bool {
        if a.confidence != b.confidence { return a.confidence > b.confidence }
        if a.missingCount != b.missingCount { return a.missingCount > b.missingCount }
        return a.id < b.id
    }

    /// Filtert und sortiert offene Waisen-Sessions.
    static func filter(orphanSessions: [GeoOrphanSession],
                       dateFilter: GeoDateFilter = .all,
                       sortOrder: GeoSortOrder = .confidence,
                       now: Date = Date(),
                       cap: Int) -> [GeoOrphanSession] {
        guard dateFilter.isActive || sortOrder != .confidence else {
            return Array(orphanSessions.prefix(cap))
        }
        let kept = orphanSessions.filter { dateFilter.includes($0.end, now: now) }
        let sorted: [GeoOrphanSession]
        switch sortOrder {
        case .confidence:
            sorted = kept.sorted(by: orphanSessionOrder)
        case .dateNewest:
            sorted = kept.sorted {
                $0.start != $1.start ? $0.start > $1.start : orphanSessionOrder($0, $1)
            }
        case .dateOldest:
            sorted = kept.sorted {
                $0.start != $1.start ? $0.start < $1.start : orphanSessionOrder($0, $1)
            }
        case .closestDistance:
            sorted = kept.sorted {
                let gapA = $0.nearestAnchorGapSeconds ?? Int.max
                let gapB = $1.nearestAnchorGapSeconds ?? Int.max
                if gapA != gapB { return gapA < gapB }
                return orphanSessionOrder($0, $1)
            }
        }
        return Array(sorted.prefix(cap))
    }

    private static func orphanSessionOrder(_ a: GeoOrphanSession, _ b: GeoOrphanSession) -> Bool {
        if a.count != b.count { return a.count > b.count }
        if a.start != b.start { return a.start > b.start }
        return a.id < b.id
    }

    // MARK: - Offene Waisen-Sessions

    /// Bündelt isolierte Fotos ohne GPS (die in keinem Cluster mit GPS-Ankern sitzen)
    /// nach Aufnahmezeit zu Sessions, damit sie gemeinsam einem Ort zugewiesen werden können.
    static func orphanSessions(sorted: [GeoScanRow],
                               clusteredOrphanIds: Set<String>,
                               parameters: GeoParameters,
                               crowding: [Date: Int] = [:]) -> [GeoOrphanSession] {
        let anchors = sorted.filter { $0.coordinate != nil }
        let plausibleCaptureStart = Date(timeIntervalSince1970: 315_532_800) // 1980-01-01
        let openOrphans = sorted.filter {
            $0.isOrphan && !clusteredOrphanIds.contains($0.id) && $0.timestamp >= plausibleCaptureStart
        }
        guard !openOrphans.isEmpty else { return [] }

        let gap = TimeInterval(parameters.clusterGapMinutes) * 60
        let microGap = TimeInterval(parameters.microGapMinutes) * 60

        var results: [GeoOrphanSession] = []

        for session in split(openOrphans, atGapLongerThan: gap) {
            let groups = session.count > parameters.subSplitThreshold
                ? split(session, atGapLongerThan: microGap)
                : [session]

            for group in groups {
                guard group.count >= 2, let first = group.first, let last = group.last else { continue }

                let crowdedShare = crowding.isEmpty ? 0 : Double(
                    group.count { (crowding[$0.timestamp] ?? 0) >= sharedTimestampFlagThreshold }
                ) / Double(group.count)
                let worstCrowd = group.map { crowding[$0.timestamp] ?? 0 }.max() ?? 0
                let timestampVerdict: GeoPlausibility = crowdedShare > 0.5
                    ? timestampPlausibility(sharedCount: worstCrowd)
                    : .ok
                if timestampVerdict.isSuppressed { continue }

                let startAnchor = nearestAnchor(to: first.timestamp, in: anchors)
                let endAnchor = nearestAnchor(to: last.timestamp, in: anchors)
                let bestAnchor: (gapSeconds: Int, latitude: Double, longitude: Double)?
                switch (startAnchor, endAnchor) {
                case let (s?, e?):
                    bestAnchor = s.gapSeconds <= e.gapSeconds ? s : e
                case let (s?, nil):
                    bestAnchor = s
                case let (nil, e?):
                    bestAnchor = e
                case (nil, nil):
                    bestAnchor = nil
                }

                let orphanIds = group.map(\.id)
                let timeSpreadMinutes = last.timestamp.timeIntervalSince(first.timestamp) / 60

                results.append(GeoOrphanSession(
                    id: AssetSetFingerprint.make(orphanIds, prefix: "orphan-session"),
                    orphanIds: orphanIds,
                    anchorIds: [],
                    start: first.timestamp,
                    end: last.timestamp,
                    timeSpreadMinutes: timeSpreadMinutes,
                    nearestAnchorGapSeconds: bestAnchor?.gapSeconds,
                    nearestAnchorLatitude: bestAnchor?.latitude,
                    nearestAnchorLongitude: bestAnchor?.longitude,
                    plausibility: timestampVerdict
                ))
            }
        }

        return results.sorted(by: orphanSessionOrder)
    }

    // MARK: - Zweifelhafte Zeitstempel

    /// Ab so vielen Aufnahmen auf derselben Sekunde gilt der Zeitstempel als
    /// zweifelhaft.
    ///
    /// Aus der realen Bibliothek abgeleitet: Dubletten desselben Fotos (gleicher
    /// Moment, andere Dateiendung) treten dort zu zweit bis viert auf — das ist
    /// normal. Ab fünf *verschiedenen* Aufnahmen auf derselben Sekunde ist es das
    /// nicht mehr.
    static let sharedTimestampFlagThreshold = 5

    /// Ab so vielen ist es kein Grenzfall mehr, sondern sicher ein Rückfallwert.
    /// Gemessen wurden Sekunden mit 25 bis 186 Aufnahmen.
    static let sharedTimestampSuppressThreshold = 20

    /// Wie viele Aufnahmen sich je Zeitpunkt denselben Zeitstempel teilen.
    ///
    /// Der Grund für diese Prüfung: `fileCreatedAt` ist nicht `dateTimeOriginal`.
    /// Fehlt einer Datei das Aufnahmedatum — bei Scans, Messenger-Bildern und
    /// bereinigten Dateien der Normalfall —, setzt der Server einen Rückfallwert.
    /// Dutzende bis hunderte Aufnahmen aus völlig verschiedenen Anlässen landen
    /// dann auf derselben Sekunde.
    ///
    /// Das ist doppelt gefährlich: Der zeitliche Abstand zwischen ihnen ist null,
    /// also vergibt die Bewertung die *höchste* Konfidenz — und weil die Liste nach
    /// Konfidenz sortiert, stehen genau die wertlosesten Vorschläge oben.
    /// Nachgemessen an einer Bibliothek mit 155 000 Aufnahmen: eine einzelne Sekunde
    /// trug 186 Aufnahmen.
    static func timestampCrowding(_ rows: [GeoScanRow]) -> [Date: Int] {
        var counts: [Date: Int] = [:]
        counts.reserveCapacity(rows.count)
        for row in rows { counts[row.timestamp, default: 0] += 1 }
        return counts
    }

    /// Übersetzt die Häufung in ein Urteil über den Zeitstempel einer Waise.
    static func timestampPlausibility(sharedCount: Int) -> GeoPlausibility {
        guard sharedCount >= sharedTimestampFlagThreshold else { return .ok }
        let detail = GeoImplausibility(reason: .sharedTimestamp,
                                       sharedTimestampCount: sharedCount)
        return sharedCount >= sharedTimestampSuppressThreshold
            ? .suppressed(detail)
            : .flagged(detail)
    }

    // MARK: - Paar-Modus

    /// Für jede Waise der unmittelbar davor und der unmittelbar danach liegende
    /// Anker. Liegen beide in Reichweite, wird zeitgewichtet interpoliert;
    /// liegt nur einer in Reichweite, werden dessen Koordinaten kopiert.
    ///
    /// - Parameter sorted: nach Zeit aufsteigend sortiert.
    /// - Parameter crowding: siehe `timestampCrowding`.
    static func pairSuggestions(sorted: [GeoScanRow],
                                parameters: GeoParameters,
                                crowding: [Date: Int] = [:]) -> (kept: [GeoSuggestion],
                                                                 suppressed: [GeoSuggestion]) {
        let anchors = sorted.filter { $0.coordinate != nil }
        guard !anchors.isEmpty else { return ([], []) }

        let thresholdSeconds = Double(parameters.pairThresholdMinutes) * 60
        var kept: [GeoSuggestion] = []
        var suppressed: [GeoSuggestion] = []

        for row in sorted where row.isOrphan {
            let target = row.timestamp
            let insertion = firstIndex(in: anchors, atOrAfter: target)

            let before = insertion > 0 ? anchors[insertion - 1] : nil
            let after = insertion < anchors.count ? anchors[insertion] : nil

            // Die Schwelle ist inklusiv — sonst hinge das Ergebnis an einer
            // Sekunde Rundung.
            let beforeInRange = before.map {
                target.timeIntervalSince($0.timestamp) <= thresholdSeconds
            } ?? false
            let afterInRange = after.map {
                $0.timestamp.timeIntervalSince(target) <= thresholdSeconds
            } ?? false

            guard let suggestion = suggestion(for: row,
                                              before: beforeInRange ? before : nil,
                                              after: afterInRange ? after : nil,
                                              sharedTimestampCount: crowding[target] ?? 0)
            else { continue }

            if suggestion.plausibility.isSuppressed {
                suppressed.append(suggestion)
            } else {
                kept.append(suggestion)
            }
        }

        return (kept, suppressed)
    }

    /// Erster Index, dessen Zeitstempel **nicht vor** `target` liegt.
    ///
    /// Daraus folgt: `anchors[index - 1].timestamp < target ≤ anchors[index].timestamp`.
    /// Die Spanne einer Interpolation ist deshalb immer echt größer als null.
    private static func firstIndex(in anchors: [GeoScanRow], atOrAfter target: Date) -> Int {
        var low = 0
        var high = anchors.count
        while low < high {
            let mid = low + (high - low) / 2
            if anchors[mid].timestamp < target { low = mid + 1 } else { high = mid }
        }
        return low
    }

    private static func suggestion(for orphan: GeoScanRow,
                                   before: GeoScanRow?,
                                   after: GeoScanRow?,
                                   sharedTimestampCount: Int) -> GeoSuggestion? {
        let target = orphan.timestamp
        let timestampVerdict = timestampPlausibility(sharedCount: sharedTimestampCount)

        if let before, let after,
           let start = before.coordinate, let end = after.coordinate {
            // Zeitgewichtete Interpolation zwischen beiden Ankern.
            let span = after.timestamp.timeIntervalSince(before.timestamp)
            let ratio = span > 0 ? target.timeIntervalSince(before.timestamp) / span : 0

            let deltaToBefore = target.timeIntervalSince(before.timestamp)
            let deltaToAfter = after.timestamp.timeIntervalSince(target)
            let nearest = min(deltaToBefore, deltaToAfter)

            let distance = haversineMeters(start.latitude, start.longitude,
                                           end.latitude, end.longitude)
            let plausibility = worse(pairPlausibility(before: before, after: after),
                                     timestampVerdict)
            let score = pairConfidence(nearestSeconds: nearest,
                                       anchorDistanceMeters: distance,
                                       timestampVerdict: timestampVerdict)

            return GeoSuggestion(
                orphanId: orphan.id,
                orphanTimestamp: target,
                latitude: start.latitude + ratio * (end.latitude - start.latitude),
                longitude: start.longitude + ratio * (end.longitude - start.longitude),
                source: .interpolated(beforeId: before.id, afterId: after.id, ratio: ratio),
                confidence: score,
                label: label(forScore: score, plausibility: plausibility),
                plausibility: plausibility,
                anchorDistanceMeters: Int(distance.rounded()),
                beforeDeltaSeconds: Int(deltaToBefore.rounded()),
                afterDeltaSeconds: Int(deltaToAfter.rounded())
            )
        }

        // Nur eine Seite in Reichweite: Koordinaten kopieren. Es gibt keinen
        // zweiten Punkt, gegen den sich räumlich etwas prüfen ließe — Zeitschwelle
        // und Zeitstempel-Urteil sind hier die einzige Absicherung.
        guard let single = before ?? after, let coordinate = single.coordinate else { return nil }

        let delta = target.timeIntervalSince(single.timestamp)
        let score = pairConfidence(nearestSeconds: abs(delta), anchorDistanceMeters: nil,
                                   timestampVerdict: timestampVerdict)

        let roundedDelta = Int(delta.rounded())
        return GeoSuggestion(
            orphanId: orphan.id,
            orphanTimestamp: target,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            source: .nearestAnchor(id: single.id, deltaSeconds: roundedDelta),
            confidence: score,
            label: label(forScore: score, plausibility: timestampVerdict),
            plausibility: timestampVerdict,
            anchorDistanceMeters: 0,
            beforeDeltaSeconds: roundedDelta >= 0 ? roundedDelta : nil,
            afterDeltaSeconds: roundedDelta < 0 ? abs(roundedDelta) : nil
        )
    }

    /// Das strengere von zwei Urteilen. „Unterdrückt" schlägt „markiert" schlägt „ok".
    static func worse(_ a: GeoPlausibility, _ b: GeoPlausibility) -> GeoPlausibility {
        if a.isSuppressed { return a }
        if b.isSuppressed { return b }
        if a.isFlagged { return a }
        if b.isFlagged { return b }
        return .ok
    }

    /// Zeitliche Nähe, absolut gemessen — nicht relativ zur eingestellten
    /// Schwelle. 30 Sekunden Abstand bleiben 30 Sekunden Abstand, egal wo der
    /// Regler steht; sonst würde ein Verschieben des Reglers alle Bewertungen
    /// umschreiben, ohne dass sich an den Aufnahmen etwas geändert hat.
    ///
    /// - Parameter anchorDistanceMeters: `nil` für einen Einzelanker. Einseitige
    ///   Belege wiegen weniger, weil die Waise auch *außerhalb* der Strecke
    ///   liegen kann.
    /// - Parameter timestampVerdict: Ist der Zeitstempel zweifelhaft, taugt die
    ///   zeitliche Nähe nichts — sie ist dann kein Beleg, sondern ein Artefakt.
    ///   Die Bewertung wird gedeckelt, damit ein solcher Vorschlag nie „Sicher"
    ///   heißen und nie oben in der Liste stehen kann.
    static func pairConfidence(nearestSeconds: Double,
                               anchorDistanceMeters: Double?,
                               timestampVerdict: GeoPlausibility = .ok) -> Int {
        let timeScore = max(0, 100 - (nearestSeconds / 600) * 100)   // 0 ab 10 Minuten

        let raw: Double
        if let distance = anchorDistanceMeters {
            let spreadScore = max(0, 100 - (distance / 5_000) * 100)  // 0 ab 5 km
            raw = timeScore * 0.7 + spreadScore * 0.3
        } else {
            raw = timeScore * 0.75
        }

        let capped = timestampVerdict == .ok ? raw : min(raw, 40)
        return Int(capped.rounded())
    }

    // MARK: - Plausibilität

    /// Passt die Strecke zwischen zwei Ankern zu der Zeit, die dazwischen liegt?
    ///
    /// Die Reihenfolge der Regeln ist wesentlich: die Nahbereichs-Ausnahme steht
    /// zuerst, weil zwei Fixes 50 m auseinander und 2 s auseinander rechnerisch
    /// 90 km/h ergeben — ohne sie gäbe Serienfotografie am selben Ort dauernd
    /// Fehlalarm.
    static func pairPlausibility(before: GeoScanRow, after: GeoScanRow) -> GeoPlausibility {
        guard let start = before.coordinate, let end = after.coordinate else { return .ok }

        let meters = haversineMeters(start.latitude, start.longitude,
                                     end.latitude, end.longitude)
        let kilometers = meters / 1_000
        let seconds = max(1, after.timestamp.timeIntervalSince(before.timestamp))
        let kmh = kilometers / (seconds / 3_600)

        // 1. Nahbereich: über so kurze Strecken sagt die Geschwindigkeit nichts.
        guard kilometers > 1 else { return .ok }

        let detail = GeoImplausibility(reason: .impossibleSpeed,
                                       distanceKm: kilometers,
                                       gapSeconds: Int(seconds.rounded()),
                                       impliedKmh: kmh)

        // 2. Schneller als ein Verkehrsflugzeug: der Zeitstempel ist kaputt oder
        //    die Kamera-Uhr steht in der falschen Zeitzone.
        if kmh > 900 { return .suppressed(detail) }

        // 3. Große Distanz in sehr kurzer Zeit — unabhängig von der Rechnung.
        if kilometers > 100 && seconds < 30 * 60 {
            return .suppressed(GeoImplausibility(reason: .teleport,
                                                 distanceKm: kilometers,
                                                 gapSeconds: Int(seconds.rounded()),
                                                 impliedKmh: kmh))
        }

        // 4. Möglich, aber die interpolierte Mitte ist nicht verlässlich: eine
        //    gerade Linie über 25 km ist keine Ortsangabe, sondern eine Strecke.
        if kmh > 250 || kilometers > 25 { return .flagged(detail) }

        return .ok
    }

    static func clusterPlausibility(spreadMeters: Double,
                                    timeSpreadMinutes: Double) -> GeoPlausibility {
        let kilometers = spreadMeters / 1_000
        let seconds = max(1, timeSpreadMinutes * 60)
        let detail = GeoImplausibility(reason: .clusterSpread,
                                       distanceKm: kilometers,
                                       gapSeconds: Int(seconds.rounded()),
                                       impliedKmh: kilometers / (seconds / 3_600))

        // Der Median von Ankern, die über Kilometer streuen, ist kein Ort mehr,
        // sondern der Schwerpunkt einer Fahrt.
        if spreadMeters > 5_000 { return .suppressed(detail) }

        // Kilometerweite Streuung zählt **ohne** Zeitbedingung. Sie stand vorher nur
        // in der Regel darunter, und die verlangt zusätzlich mehr als zehn Minuten:
        // Eine Session mit vier Kilometern Streuung in acht Minuten fiel dadurch auf
        // `.ok` durch — obwohl sie mit 30 km/h offensichtlicher eine Fahrt ist als
        // die 600 Meter in zwanzig Minuten, die markiert werden.
        //
        // Das ist teuer, weil `.ok` zusammen mit einem Wert ab 85 das Etikett
        // „Sicher" ergibt, und „Magic Select" genau die auswählt (siehe
        // `GeoMatchModel.selectConfidentClusters`). Geschrieben wird auf manchen
        // Servern unumkehrbar.
        //
        // `.flagged` statt `.suppressed`: Der Vorschlag bleibt sichtbar und
        // begründet, er ist nur nicht mehr vorausgewählt.
        if spreadMeters > 1_000 { return .flagged(detail) }

        if spreadMeters > 500 && timeSpreadMinutes > 10 { return .flagged(detail) }
        return .ok
    }

    // MARK: - Cluster-Modus

    /// Zerlegt die Bibliothek in Aufnahme-Sessions und schlägt für jede den
    /// Median ihrer Ankerkoordinaten vor.
    ///
    /// - Parameter sorted: nach Zeit aufsteigend sortiert.
    static func clusters(sorted: [GeoScanRow],
                         parameters: GeoParameters,
                         crowding: [Date: Int] = [:]) -> (kept: [GeoCluster],
                                                          suppressed: [GeoCluster]) {
        guard !sorted.isEmpty else { return ([], []) }

        let gap = TimeInterval(parameters.clusterGapMinutes) * 60
        let microGap = TimeInterval(parameters.microGapMinutes) * 60

        var kept: [GeoCluster] = []
        var suppressed: [GeoCluster] = []

        for session in split(sorted, atGapLongerThan: gap) {
            // Eine überlange Session ist meistens keine: ein durchgehender Tag
            // mit vielen Aufnahmen wird an der feineren Lücke nachgeteilt.
            let groups = session.count > parameters.subSplitThreshold
                ? split(session, atGapLongerThan: microGap)
                : [session]

            for group in groups {
                guard let cluster = makeCluster(group, parameters: parameters,
                                                crowding: crowding) else { continue }
                if cluster.plausibility.isSuppressed {
                    suppressed.append(cluster)
                } else {
                    kept.append(cluster)
                }
            }
        }

        return (kept, suppressed)
    }

    private static func split(_ rows: [GeoScanRow],
                              atGapLongerThan gap: TimeInterval) -> [[GeoScanRow]] {
        var groups: [[GeoScanRow]] = []
        var current: [GeoScanRow] = []

        for row in rows {
            if let last = current.last,
               row.timestamp.timeIntervalSince(last.timestamp) > gap {
                groups.append(current)
                current = []
            }
            current.append(row)
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    private static func makeCluster(_ group: [GeoScanRow],
                                    parameters: GeoParameters,
                                    crowding: [Date: Int]) -> GeoCluster? {
        guard group.count >= parameters.minClusterSize else { return nil }

        let anchors = group.filter { $0.coordinate != nil }
        let orphans = group.filter(\.isOrphan)
        guard !anchors.isEmpty, !orphans.isEmpty else { return nil }

        let gpsPercentage = Double(anchors.count) / Double(group.count) * 100
        guard gpsPercentage >= parameters.minGpsPercentage else { return nil }

        let coordinates = anchors.compactMap(\.coordinate)
        // Median statt Mittelwert: ein einzelner falsch verorteter Anker soll die
        // ganze Session nicht verschieben.
        let medianLatitude = median(coordinates.map(\.latitude))
        let medianLongitude = median(coordinates.map(\.longitude))

        let start = group.first!.timestamp
        let end = group.last!.timestamp
        let timeSpreadMinutes = end.timeIntervalSince(start) / 60
        let spread = spreadMeters(of: coordinates)

        // Sitzt die Mehrheit der Session auf geteilten Zeitstempeln, ist die
        // Session selbst ein Artefakt: Was hier zusammensteht, wurde nicht
        // zusammen aufgenommen, sondern trägt nur denselben Rückfallwert.
        let crowdedShare = crowding.isEmpty ? 0 : Double(
            group.count { (crowding[$0.timestamp] ?? 0) >= sharedTimestampFlagThreshold }
        ) / Double(group.count)
        let worstCrowd = group.map { crowding[$0.timestamp] ?? 0 }.max() ?? 0
        let timestampVerdict: GeoPlausibility = crowdedShare > 0.5
            ? timestampPlausibility(sharedCount: worstCrowd)
            : .ok

        let plausibility = worse(clusterPlausibility(spreadMeters: spread,
                                                     timeSpreadMinutes: timeSpreadMinutes),
                                 timestampVerdict)
        let rawScore = confidenceScore(gpsPercentage: gpsPercentage,
                                       timeSpreadMinutes: timeSpreadMinutes,
                                       spreadMeters: spread)
        let score = timestampVerdict == .ok ? rawScore : min(rawScore, 40)

        return GeoCluster(
            id: clusterFingerprint(group.map(\.id)),
            assetIds: group.map(\.id),
            anchorIds: anchors.map(\.id),
            orphanIds: orphans.map(\.id),
            start: start,
            end: end,
            medianLatitude: medianLatitude,
            medianLongitude: medianLongitude,
            gpsPercentage: Int(gpsPercentage.rounded()),
            spatialSpreadMeters: Int(spread.rounded()),
            timeSpreadMinutes: timeSpreadMinutes,
            confidence: score,
            // „Bewegte Session" beschreibt genau den *räumlichen* Befund. Ein
            // markierter Zeitstempel ist etwas anderes und darf nicht so heißen —
            // deshalb hier die räumliche Prüfung allein, nicht `plausibility`.
            //
            // `isSuppressed` zählt mit: Eine Streuung über fünf Kilometer wird
            // verworfen, ist aber erst recht eine bewegte Session. Ohne das trug
            // eine verworfene Session in der Verworfen-Liste „Wahrscheinlich" —
            // dieselbe Widersprüchlichkeit wie bei den Paaren.
            label: label(forScore: score,
                         isMovingSession: clusterPlausibility(
                            spreadMeters: spread,
                            timeSpreadMinutes: timeSpreadMinutes).isSpatiallyNotable),
            plausibility: plausibility
        )
    }

    /// Diagonale des umschließenden Rechtecks statt aller Paare.
    ///
    /// Ein Alle-gegen-alle-Vergleich ist quadratisch und würde bei einer
    /// durchgehenden Session mit tausenden Aufnahmen Millionen Rechnungen
    /// bedeuten. Über die Ausdehnung einer Aufnahme-Session ist die Diagonale
    /// praktisch deckungsgleich mit dem größten Abstand zweier Anker.
    static func spreadMeters(of coordinates: [(latitude: Double, longitude: Double)]) -> Double {
        guard coordinates.count > 1 else { return 0 }

        var minLatitude = coordinates[0].latitude, maxLatitude = coordinates[0].latitude
        var minLongitude = coordinates[0].longitude, maxLongitude = coordinates[0].longitude
        for coordinate in coordinates.dropFirst() {
            minLatitude = min(minLatitude, coordinate.latitude)
            maxLatitude = max(maxLatitude, coordinate.latitude)
            minLongitude = min(minLongitude, coordinate.longitude)
            maxLongitude = max(maxLongitude, coordinate.longitude)
        }
        return haversineMeters(minLatitude, minLongitude, maxLatitude, maxLongitude)
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }

    /// Stabiler Fingerabdruck über die enthaltenen Assets.
    ///
    /// Die Rechnung steht in `AssetSetFingerprint` — die Etappenerkennung braucht
    /// denselben Abdruck für ihre Ignorierliste, und zwei Kopien einer Hashfunktion
    /// laufen früher oder später auseinander.
    static func clusterFingerprint(_ assetIds: [String]) -> String {
        AssetSetFingerprint.make(assetIds, prefix: "cluster")
    }

    // MARK: - Bewertung

    /// GPS-Dichte, zeitliche Enge und räumliche Enge zu je 40/30/30 Prozent.
    static func confidenceScore(gpsPercentage: Double,
                                timeSpreadMinutes: Double,
                                spreadMeters: Double) -> Int {
        let gpsScore = min(gpsPercentage, 100) * 0.4
        let timeScore = max(0, 100 - (timeSpreadMinutes / 60) * 100) * 0.3
        let spatialScore = max(0, 100 - (spreadMeters / 500) * 100) * 0.3
        return Int((gpsScore + timeScore + spatialScore).rounded())
    }

    static func label(forScore score: Int, isMovingSession: Bool) -> GeoLabel {
        if isMovingSession { return .bewegteSession }
        if score >= 85 { return .sicher }
        if score >= 65 { return .wahrscheinlich }
        return .unsicher
    }

    /// Ein räumlich auffälliger Vorschlag ist nie „sicher", wie gut die Zeit auch passt.
    ///
    /// `isSuppressed` zählt hier mit, nicht nur `isFlagged`: Verworfene Vorschläge
    /// verschwinden nicht, sie stehen unter „Verworfen — unplausible Zeitsprünge",
    /// und `GeoSuggestionRow` zeigt dort dieselbe Konfidenz-Pille wie oben. Ohne
    /// diese Zeile konnte ein wegen unmöglicher Geschwindigkeit verworfenes Paar
    /// dort mit „Sicher" stehen — zwei Kilometer in vier Sekunden ergeben 1 800 km/h
    /// und trotzdem 88 Punkte, weil kurze Strecke und kurze Zeit beide Teilwerte
    /// hochhalten. Ein Etikett, das der Begründung daneben widerspricht, macht
    /// genau die Liste unbrauchbar, die erklären soll, warum hier nichts angeboten
    /// wird.
    ///
    /// Der Zahlenwert bleibt, wie er ist — wie bei `.flagged` auch. Er ist die
    /// Messung, das Etikett ist das Urteil.
    private static func label(forScore score: Int, plausibility: GeoPlausibility) -> GeoLabel {
        if plausibility.isFlagged || plausibility.isSuppressed { return .unsicher }
        return label(forScore: score, isMovingSession: false)
    }

    // MARK: - Geometrie

    /// Großkreisabstand in Metern.
    static func haversineMeters(_ latitude1: Double, _ longitude1: Double,
                                _ latitude2: Double, _ longitude2: Double) -> Double {
        let earthRadius = 6_371_000.0
        let phi1 = latitude1 * .pi / 180
        let phi2 = latitude2 * .pi / 180
        let deltaPhi = (latitude2 - latitude1) * .pi / 180
        let deltaLambda = (longitude2 - longitude1) * .pi / 180

        let a = sin(deltaPhi / 2) * sin(deltaPhi / 2)
            + cos(phi1) * cos(phi2) * sin(deltaLambda / 2) * sin(deltaLambda / 2)
        return 2 * earthRadius * atan2(sqrt(a), sqrt(1 - a))
    }

    // MARK: - Nachbar-Orte (Ortswechsel im Detailblatt)

    /// Findet zeitlich benachbarte GPS-Aufnahmen-Gruppen (auch reine Anker-Gruppen
    /// ohne eigene Waisen), damit falsch zugeordnete Fotos direkt auf den
    /// Nachbarort umgebucht werden können.
    static func alternativeLocations(
        rows: [GeoScanRow],
        aroundStart: Date,
        aroundEnd: Date,
        currentLatitude: Double? = nil,
        currentLongitude: Double? = nil,
        excludingAnchorIds: Set<String> = [],
        maxResults: Int = 8
    ) -> [GeoAlternativeLocation] {
        let anchors = rows
            .filter { $0.coordinate != nil && !excludingAnchorIds.contains($0.id) }
            .sorted {
                $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp
            }
        guard !anchors.isEmpty else { return [] }

        let windowRadius: TimeInterval = 36 * 3_600
        let windowStart = aroundStart.addingTimeInterval(-windowRadius)
        let windowEnd = aroundEnd.addingTimeInterval(windowRadius)

        var candidates = anchors.filter { $0.timestamp >= windowStart && $0.timestamp <= windowEnd }
        var groups = groupAlternativeAnchors(
            candidates,
            aroundStart: aroundStart,
            aroundEnd: aroundEnd,
            currentLatitude: currentLatitude,
            currentLongitude: currentLongitude
        )

        // Falls im ±36-Stunden-Fenster weniger als 3 andere Orte liegen, den Suchradius erweitern.
        if groups.count < 3 && candidates.count < anchors.count {
            let expandedBefore = anchors.filter { $0.timestamp < windowStart }.suffix(80)
            let expandedAfter = anchors.filter { $0.timestamp > windowEnd }.prefix(80)
            candidates = Array(expandedBefore) + candidates + Array(expandedAfter)
            groups = groupAlternativeAnchors(
                candidates,
                aroundStart: aroundStart,
                aroundEnd: aroundEnd,
                currentLatitude: currentLatitude,
                currentLongitude: currentLongitude
            )
        }

        let closest = groups
            .sorted {
                abs($0.deltaSeconds) == abs($1.deltaSeconds)
                    ? $0.start < $1.start
                    : abs($0.deltaSeconds) < abs($1.deltaSeconds)
            }
            .prefix(maxResults)

        return Array(closest)
    }

    private static func groupAlternativeAnchors(
        _ anchors: [GeoScanRow],
        aroundStart: Date,
        aroundEnd: Date,
        currentLatitude: Double?,
        currentLongitude: Double?
    ) -> [GeoAlternativeLocation] {
        guard !anchors.isEmpty else { return [] }

        let maxGapSeconds: TimeInterval = 15 * 60
        let maxStepMeters: Double = 150

        var buckets: [[GeoScanRow]] = []
        var current: [GeoScanRow] = []

        for row in anchors {
            if let last = current.last,
               let lastCoord = last.coordinate,
               let rowCoord = row.coordinate {
                let timeGap = row.timestamp.timeIntervalSince(last.timestamp)
                let dist = haversineMeters(lastCoord.latitude, lastCoord.longitude,
                                           rowCoord.latitude, rowCoord.longitude)
                if timeGap > maxGapSeconds || dist > maxStepMeters {
                    buckets.append(current)
                    current = []
                }
            }
            current.append(row)
        }
        if !current.isEmpty { buckets.append(current) }

        var results: [GeoAlternativeLocation] = []
        for bucket in buckets {
            let coords = bucket.compactMap(\.coordinate)
            guard !coords.isEmpty, let first = bucket.first, let last = bucket.last else { continue }

            let medLat = median(coords.map(\.latitude))
            let medLon = median(coords.map(\.longitude))
            let distFromOriginal: Double
            if let currentLatitude, let currentLongitude {
                distFromOriginal = haversineMeters(currentLatitude, currentLongitude, medLat, medLon)
                // Nur wirklich andere Orte vorschlagen (nicht denselben Standort nochmal).
                guard distFromOriginal >= 60 else { continue }
            } else {
                distFromOriginal = 0
            }

            let deltaSeconds: Int
            if last.timestamp < aroundStart {
                deltaSeconds = Int(last.timestamp.timeIntervalSince(aroundStart).rounded())
            } else if first.timestamp > aroundEnd {
                deltaSeconds = Int(first.timestamp.timeIntervalSince(aroundEnd).rounded())
            } else {
                deltaSeconds = 0
            }

            results.append(GeoAlternativeLocation(
                id: AssetSetFingerprint.make(bucket.map(\.id), prefix: "alt"),
                start: first.timestamp,
                end: last.timestamp,
                latitude: medLat,
                longitude: medLon,
                sampleAnchorIds: Array(bucket.prefix(4).map(\.id)),
                anchorIds: Array(bucket.prefix(24).map(\.id)),
                totalAnchorCount: bucket.count,
                deltaSeconds: deltaSeconds,
                distanceFromOriginalMeters: Int(distFromOriginal.rounded())
            ))
        }

        let sortedByTime = results.sorted {
            abs($0.deltaSeconds) == abs($1.deltaSeconds)
                ? $0.start < $1.start
                : abs($0.deltaSeconds) < abs($1.deltaSeconds)
        }

        // Räumlich nahe Gruppen (< 200 m) zusammenfassen, damit am selben Hotel/Pool
        // nicht fünf fast identische Karten nebeneinander auftauchen.
        var deduplicated: [GeoAlternativeLocation] = []
        let mergeRadiusMeters: Double = 200

        for candidate in sortedByTime {
            if let existingIndex = deduplicated.firstIndex(where: {
                haversineMeters($0.latitude, $0.longitude, candidate.latitude, candidate.longitude) < mergeRadiusMeters
            }) {
                let existing = deduplicated[existingIndex]
                var mergedSamples = existing.sampleAnchorIds
                for id in candidate.sampleAnchorIds where !mergedSamples.contains(id) && mergedSamples.count < 4 {
                    mergedSamples.append(id)
                }
                var mergedAll = existing.anchorIds
                for id in candidate.anchorIds where !mergedAll.contains(id) && mergedAll.count < 24 {
                    mergedAll.append(id)
                }
                deduplicated[existingIndex] = GeoAlternativeLocation(
                    id: existing.id,
                    start: existing.start,
                    end: existing.end,
                    latitude: existing.latitude,
                    longitude: existing.longitude,
                    sampleAnchorIds: mergedSamples,
                    anchorIds: mergedAll,
                    totalAnchorCount: existing.totalAnchorCount + candidate.totalAnchorCount,
                    deltaSeconds: existing.deltaSeconds,
                    distanceFromOriginalMeters: existing.distanceFromOriginalMeters
                )
            } else {
                deduplicated.append(candidate)
            }
        }
        return deduplicated
    }

    // MARK: - Bekannte Foto-Orte aus der Mediathek

    private struct GridCellKey: Hashable {
        let latBin: Int
        let lonBin: Int
    }

    /// Gruppiert vorhandene GPS-Aufnahmen der Bibliothek zu bekannten Foto-Orten (~250 m Radius),
    /// filtert optional nach Orts- oder Ländername und sortiert nach Häufigkeit.
    static func knownPhotoLocations(
        from rows: [GeoKnownLocationRow],
        matching query: String = "",
        limit: Int = 36
    ) -> [GeoKnownPhotoLocation] {
        guard !rows.isEmpty, limit > 0 else { return [] }

        var buckets: [GridCellKey: [GeoKnownLocationRow]] = [:]
        buckets.reserveCapacity(min(rows.count, 4096))
        for row in rows {
            let key = GridCellKey(
                latBin: Int((row.latitude * 250).rounded()),
                lonBin: Int((row.longitude * 250).rounded())
            )
            buckets[key, default: []].append(row)
        }

        let orderedBuckets = buckets.sorted { lhs, rhs in
            if lhs.value.count != rhs.value.count { return lhs.value.count > rhs.value.count }
            if lhs.key.latBin != rhs.key.latBin { return lhs.key.latBin < rhs.key.latBin }
            return lhs.key.lonBin < rhs.key.lonBin
        }

        struct MutablePlace {
            var rows: [GeoKnownLocationRow]
            let latitude: Double
            let longitude: Double
        }

        var places: [MutablePlace] = []
        places.reserveCapacity(orderedBuckets.count)
        var cellToPlaceIndex: [GridCellKey: Int] = [:]
        cellToPlaceIndex.reserveCapacity(orderedBuckets.count)

        for (cellKey, cellRows) in orderedBuckets {
            let lat = median(cellRows.map(\.latitude))
            let lon = median(cellRows.map(\.longitude))

            var targetIndex: Int?
            for dLat in -1...1 {
                for dLon in -2...2 {
                    let neighbor = GridCellKey(latBin: cellKey.latBin + dLat, lonBin: cellKey.lonBin + dLon)
                    if let idx = cellToPlaceIndex[neighbor],
                       haversineMeters(places[idx].latitude, places[idx].longitude, lat, lon) < 250 {
                        targetIndex = idx
                        break
                    }
                }
                if targetIndex != nil { break }
            }

            if let idx = targetIndex {
                places[idx].rows.append(contentsOf: cellRows)
                cellToPlaceIndex[cellKey] = idx
            } else {
                let newIndex = places.count
                places.append(MutablePlace(rows: cellRows, latitude: lat, longitude: lon))
                cellToPlaceIndex[cellKey] = newIndex
            }
        }

        var locations: [GeoKnownPhotoLocation] = []
        locations.reserveCapacity(places.count)

        for place in places {
            var cityCounts: [String: Int] = [:]
            var countryCounts: [String: Int] = [:]
            var searchTexts: Set<String> = []

            for row in place.rows {
                if let rawCity = row.city?.trimmingCharacters(in: .whitespacesAndNewlines), !rawCity.isEmpty {
                    cityCounts[rawCity, default: 0] += 1
                    searchTexts.insert(rawCity.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil))
                }
                if let rawCountry = row.country?.trimmingCharacters(in: .whitespacesAndNewlines), !rawCountry.isEmpty {
                    countryCounts[rawCountry, default: 0] += 1
                    searchTexts.insert(rawCountry.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil))
                    searchTexts.insert(
                        Laendernamen.anzeigename(fuer: rawCountry)
                            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                    )
                }
            }

            let topCity = cityCounts.max {
                $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key
            }?.key
            let topCountry = countryCounts.max {
                $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key
            }?.key

            let sortedByNewest = place.rows.sorted {
                if $0.timestamp != $1.timestamp { return $0.timestamp > $1.timestamp }
                return $0.id < $1.id
            }
            guard let newest = sortedByNewest.first else { continue }

            let allIds = sortedByNewest.map(\.id)
            locations.append(GeoKnownPhotoLocation(
                id: AssetSetFingerprint.make(allIds, prefix: "known"),
                city: topCity,
                country: topCountry.map { Laendernamen.anzeigename(fuer: $0) },
                latitude: place.latitude,
                longitude: place.longitude,
                sampleAnchorIds: Array(allIds.prefix(4)),
                anchorIds: Array(allIds.prefix(24)),
                totalAnchorCount: allIds.count,
                latestTimestamp: newest.timestamp,
                searchTokens: Array(searchTexts).sorted()
            ))
        }

        let sorted = locations.sorted { lhs, rhs in
            if lhs.totalAnchorCount != rhs.totalAnchorCount { return lhs.totalAnchorCount > rhs.totalAnchorCount }
            if lhs.latestTimestamp != rhs.latestTimestamp { return lhs.latestTimestamp > rhs.latestTimestamp }
            return lhs.id < rhs.id
        }
        return filterKnownLocations(sorted, matching: query, limit: limit)
    }

    /// Filtert bereits gruppierte `GeoKnownPhotoLocation`-Orte nach Suchbegriff.
    static func filterKnownLocations(
        _ locations: [GeoKnownPhotoLocation],
        matching query: String,
        limit: Int = 36
    ) -> [GeoKnownPhotoLocation] {
        guard limit > 0 else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Array(locations.prefix(limit))
        }
        let foldedQuery = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let matching = locations.filter { location in
            if location.searchTokens.contains(where: { $0.contains(foldedQuery) }) {
                return true
            }
            return location.displayTitle
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .contains(foldedQuery)
        }
        return Array(matching.prefix(limit))
    }
}
