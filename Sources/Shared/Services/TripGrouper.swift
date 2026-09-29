import Foundation

/// Eine Reise: benachbarte Etappen desselben Landes.
///
/// Die Etappenerkennung schneidet fein — ein Tagesausflug nach Cupertino wird zur
/// eigenen Etappe, auch wenn er mitten in einem zehntägigen San-Francisco-Aufenthalt
/// liegt. Für die Frage „was mache ich damit?" ist das richtig; für die Frage
/// „gehört das zusammen?" ist es zu fein. Diese Klammer beantwortet die zweite.
struct TripGroup: Identifiable, Equatable {
    /// Fingerabdruck über alle Assets der Gruppe — überlebt einen Neustart und
    /// ändert sich, sobald ein Regler den Zuschnitt verschiebt.
    let id: String
    /// Rohwert des Servers, wie `TripSegment.country`. `nil`, wenn die Etappen
    /// kein Land tragen.
    let country: String?
    /// Chronologisch, wie sie der Segmenter geliefert hat.
    let segments: [TripSegment]

    /// Nicht `segments.first!.start`: Etappen dürfen sich überlappen, und der
    /// Cupertino-Abstecher beginnt später, als der San-Francisco-Block endet.
    var start: Date { segments.map(\.start).min() ?? .distantPast }
    var end: Date { segments.map(\.end).max() ?? .distantFuture }
    var assetCount: Int { segments.reduce(0) { $0 + $1.assetCount } }

    /// Eine Gruppe aus einer Etappe ist keine Reise, sondern nur eine Etappe. Die
    /// Ansicht zeigt sie ohne jedes Gruppen-Beiwerk.
    var isSingle: Bool { segments.count == 1 }
}

/// Fasst Etappen zu Reisen zusammen.
///
/// Bewusst hier und nicht im `TripSegmenter`: Der Segmenter arbeitet auf einzelnen
/// Fotos und kennt Radien und Pausen, diese Klammer arbeitet auf seinem Ergebnis und
/// kennt nur Land und Kalender. Zwei Fragen, zwei Stellen — und diese hier ist eine
/// reine Funktion und damit ohne Datenbank testbar.
enum TripGrouper {

    /// Wie lange eine Pause sein darf, ohne die Reise zu beenden.
    ///
    /// Drei Tage, und das ist kein neuer Regler: Die Einstellungsleiste hat schon
    /// vier. Die Zahl trennt Reisen desselben Landes im selben Monat, ohne einen
    /// Zwischenstopp ohne Fotos zu zerreißen. Der feine Zuschnitt bleibt Sache der
    /// „trennenden Pause" in `TripParameters` — die wirkt eine Ebene tiefer.
    static let maxGapDays: Double = 3

    /// Der Schlüssel, unter dem eine von Hand überbrückte Pause gemerkt wird.
    ///
    /// Das **Ende der vorangehenden Reise**, auf die Sekunde. Bewusst nicht die
    /// Gruppen-Id: Die ist ein Fingerabdruck über die Fotos und ändert sich, sobald
    /// ein Regler den Zuschnitt verschiebt — die Verbindung wäre nach jedem
    /// Reglerdreh weg. Das Ende einer Reise bleibt dasselbe Datum.
    static func bridgeKey(_ date: Date) -> Double {
        date.timeIntervalSince1970.rounded()
    }

    /// Etappen desselben Landes, deren Abstand `maxGapDays` nicht überschreitet.
    ///
    /// - Parameter segments: In beliebiger Reihenfolge; die Ausgabe ist chronologisch.
    /// - Parameter bridgedEnds: Von Hand überbrückte Pausen, als `bridgeKey`. Sie
    ///   heben **nur** die Zeitgrenze auf, nicht die Landesgrenze: Ein Klick sagt
    ///   „diese Pause gehört noch zur Reise", nicht „Land spielt keine Rolle".
    static func group(_ segments: [TripSegment],
                      maxGapDays: Double = TripGrouper.maxGapDays,
                      bridgedEnds: Set<Double> = []) -> [TripGroup] {
        let sorted = segments.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
        let maxGap = maxGapDays * 86_400

        var groups: [[TripSegment]] = []
        // Getrennt vom letzten Segment geführt, weil sich Etappen überlappen dürfen:
        // Maßgeblich ist das Ende der **Gruppe**, nicht das des Vorgängers. Sonst
        // risse ein kurzer Abstecher die Reise auseinander, obwohl der Hauptaufenthalt
        // noch läuft.
        var currentEnd: Date?

        for segment in sorted {
            let sameCountry = groups.last.map { passtZusammen($0, segment) } ?? false
            let inTime = currentEnd.map {
                segment.start.timeIntervalSince($0) <= maxGap || bridgedEnds.contains(bridgeKey($0))
            } ?? false

            if sameCountry, inTime, !groups.isEmpty {
                groups[groups.count - 1].append(segment)
                currentEnd = max(currentEnd ?? segment.end, segment.end)
            } else {
                groups.append([segment])
                currentEnd = segment.end
            }
        }

        return groups.map { makeGroup($0) }
    }

    // MARK: - Intern

    /// Gehört die Etappe zum selben Land wie die Gruppe?
    ///
    /// Zwei `nil` gelten **nicht** als gleich: Etappen ohne Landesangabe haben nichts
    /// gemeinsam außer der fehlenden Angabe. Sie zu verschmelzen hieße, eine Reise zu
    /// behaupten, für die es keinen Beleg gibt.
    private static func passtZusammen(_ group: [TripSegment], _ segment: TripSegment) -> Bool {
        guard let country = group.first?.country, let other = segment.country else { return false }
        return country == other
    }

    private static func makeGroup(_ segments: [TripSegment]) -> TripGroup {
        let assetIds = segments.flatMap(\.assetIds)
        return TripGroup(id: AssetSetFingerprint.make(assetIds, prefix: "reise"),
                         country: segments.first?.country,
                         segments: segments)
    }
}
