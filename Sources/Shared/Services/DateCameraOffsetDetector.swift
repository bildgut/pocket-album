import Foundation

/// Detektor B: die Uhr einer Kamera lief über einen Zeitraum um einen festen Betrag
/// falsch.
///
/// Die Analyse-Einheit ist **(Kamera, zusammenhängender Lauf)** über die ganze
/// Bibliothek — nie ein Album. Das ist der Bruch mit der Vorgängerfassung: die
/// zerteilte ein Album an Zeitlücken von zwölf Stunden, also faktisch nach Tagen,
/// und erklärte den größten Tag zur Wahrheit. Jede mehrtägige Reise ergab so
/// zwangsläufig den Vorschlag, einen Tag auf einen anderen zu schieben.
///
/// Der Beweis besteht hier aus drei voneinander unabhängigen Teilen:
///
/// 1. **Vorher getrennt** — der Lauf liegt von jeder anderen Kamera zeitlich
///    getrennt. Eine Kamera, die innerhalb eines gemischten Ereignisses fotografiert,
///    erfüllt das nie, und genau daran scheitern die alten Fehlvorschläge.
/// 2. **Nachher verzahnt** — erst die Verschiebung bringt den Lauf mit den anderen
///    Kameras zur Deckung. Das ist der eigentliche Beleg.
/// 3. **Über den ganzen Lauf derselbe Betrag** — jedes Drittel des Laufs wählt für
///    sich denselben Kandidaten.
///
/// Dazu kommt, dass der Suchraum nur benennbare Formen enthält: halbe Stunden, ganze
/// Tage, ganze Jahre. **Ein Versatz von +2,21 Tagen liegt nicht auf dem Gitter und
/// kann gar nicht entstehen.**
///
/// ## Was dieser Detektor nicht findet
///
/// Bedingung (1) zieht eine Grenze, die man kennen muss: ein Uhrfehler, der
/// **kleiner ist als das tägliche Aufnahmefenster**, lässt den Lauf schon vorher mit
/// den anderen Kameras überlappen. Zwei Kameras auf derselben Feier, eine davon zwei
/// Stunden verstellt, erfüllt „vorher getrennt" nicht und wird hier nicht gefunden.
///
/// Das ist bewusst so. Dieselbe Überlappung erzeugt nämlich auch das Gegenteil —
/// zwei gleichzeitig benutzte Geräte —, und die beiden Fälle sind an der Verzahnung
/// allein nicht zu unterscheiden. Die Vorgängerfassung hat genau hier geraten und
/// vorgeschlagen, 725 Aufnahmen eines zweiten Telefons um 193 Tage zu verschieben.
/// Lieber eine benannte Lücke als ein geratener Befund: für den Zeitzonenfall
/// innerhalb eines Ereignisses ist `DateTimezoneDetector` zuständig, der gegen die
/// Sonne misst statt gegen eine andere Kamera.
///
/// Gefunden wird damit die Defektform, die an der echten Bibliothek tatsächlich
/// überwiegt: eine Kamera, deren Datum auf ein anderes Jahr zurückgesetzt war.
///
/// Rein und abhängigkeitsfrei.
enum DateCameraOffsetDetector {

    // MARK: - Schwellen

    /// Ab dieser Lücke beginnt ein neuer Lauf.
    ///
    /// Vierzehn Tage — bewusst weit über jeder Übernachtungs- oder Wochenendlücke.
    /// Ein Lauf darf **niemals** nach Tagen zerfallen; genau das war der Fehler der
    /// Vorgängerfassung mit ihren zwölf Stunden.
    static let runGap: TimeInterval = 14 * 86400

    /// So viele Aufnahmen muss ein Lauf haben.
    static let minRunSize = 15

    /// So lang muss ein Lauf sein.
    ///
    /// An der echten Bibliothek gemessen und **nachträglich ergänzt**: ohne diese
    /// Bedingung bestand die Mehrzahl der Befunde aus Läufen eines einzigen Tages,
    /// die irgendein Kandidat auf irgendeinen anderen belegten Tag schob („+1 d",
    /// „+6 d", „−22 d"). Ein einzelner Tag hat zu wenig Gestalt, als dass seine
    /// Deckung mit einem anderen Tag etwas bedeuten könnte — das war die
    /// Tagesverschiebung der Vorgängerfassung in neuer Form.
    ///
    /// Über mehrere Tage hinweg muss dagegen auch der *Rhythmus* passen: die Lücken
    /// zwischen den Nächten, die Länge der Tage. Das trifft man nicht zufällig.
    static let minRunSpan: TimeInterval = 2 * 86400

    /// So nah muss eine Fremdkamera-Aufnahme liegen, um als Nachbar zu gelten.
    ///
    /// Fünf Minuten, nicht eine Stunde. Ebenfalls an der echten Bibliothek
    /// nachgeschärft: bei einer Stunde findet in einer dicht belegten Bibliothek
    /// praktisch jede verschobene Aufnahme einen Nachbarn, und „Verzahnung" misst
    /// dann nur noch, wie voll die Bibliothek ist. Fünf Minuten verlangen, dass
    /// **dieselben Momente** fotografiert wurden — und das ist die Aussage, um die
    /// es geht.
    static let neighbourWindow: TimeInterval = 300

    /// So getrennt muss der Lauf **vor** der Verschiebung liegen.
    static let disjointBefore = 0.05

    /// So verzahnt muss er **danach** liegen.
    static let interleavedAfter = 0.60

    /// Um so viel muss die Verzahnung besser werden.
    static let minimumImprovement = 0.5

    /// So viele Kandidaten dürfen die Verzahnungsschwelle höchstens erreichen.
    ///
    /// Der Kern der Nachschärfung: erreichen *viele* Versätze eine hohe Verzahnung,
    /// ist die Deckung nicht kennzeichnend, sondern Zufall — dann sagt sie nur, dass
    /// die Bibliothek in jenem Zeitraum dicht belegt ist. Ein echter Uhrfehler hat
    /// **einen** Versatz, der passt, und sonst keinen.
    ///
    /// Zwei sind erlaubt, weil ein Jahresversatz in beiden Längen (365 und 366 Tage)
    /// im Gitter steht und beide treffen können.
    static let maximumMatchingCandidates = 2

    /// So viel größer als der Lauf muss der Bezug sein.
    ///
    /// Ohne diese Bedingung ist die Aussage symmetrisch und damit wertlos: stehen
    /// sich nur zwei Kameras gegenüber, liegt **jede** von beiden getrennt von der
    /// anderen und kommt durch die Gegenverschiebung mit ihr zur Deckung. Beide
    /// bekämen einen Befund, und das Werkzeug behauptete, die richtig gestellte
    /// Kamera sei falsch — der Nara-Schaden in Reinform.
    ///
    /// Erst wenn der Bezug die *Bibliothek* ist und nicht die Gegenkamera, bedeutet
    /// „danach verzahnt" etwas: der Lauf fügt sich dann in einen dicht belegten
    /// Zeitraum ein, statt nur zu einer einzelnen anderen Kamera zu passen.
    static let minimumReferenceRatio = 4.0

    /// So viele Zeitpunkte werden je Lauf höchstens ausgewertet.
    ///
    /// Der Verzahnungsanteil ist ein Anteil; er lässt sich an einer gleichmäßigen
    /// Stichprobe genauso gut schätzen wie an allen Zeilen, und der Suchraum wird je
    /// Lauf mehrere hundert Mal durchlaufen. Betrifft nur die *Messung* — betroffen
    /// sind immer alle Aufnahmen des Laufs.
    static let sampleLimit = 400

    // MARK: - Kandidaten

    /// Das Gitter der benennbaren Formen.
    ///
    /// Dass „benennbare Form" eine Eigenschaft des **Suchraums** ist und kein
    /// nachträglicher Filter, ist der Kern: ein krummer Versatz kann nicht entstehen,
    /// er muss nicht aussortiert werden.
    static func candidateOffsets() -> [TimeInterval] {
        var offsets: Set<TimeInterval> = []

        // Zeitzonen und Uhrfehler: halbe Stunden bis ±14 h.
        for halfHours in 1...28 {
            let seconds = TimeInterval(halfHours) * 1800
            offsets.insert(seconds)
            offsets.insert(-seconds)
        }
        // Ein verstelltes Datum: ganze Tage bis ±31.
        for days in 1...31 {
            let seconds = TimeInterval(days) * 86400
            offsets.insert(seconds)
            offsets.insert(-seconds)
        }
        // Ein nie gestelltes Jahr: ganze Jahre bis ±30, in beiden Längen.
        for years in 1...30 {
            for yearLength in [365.0, 366.0] {
                let seconds = TimeInterval(years) * yearLength * 86400
                offsets.insert(seconds)
                offsets.insert(-seconds)
            }
        }

        // Sortiert, damit die Auswertung reihenfolgeunabhängig ist.
        return offsets.sorted()
    }

    // MARK: - Läufe

    /// Ein zusammenhängender Abschnitt der Aufnahmen einer Kamera.
    struct Run: Sendable, Equatable {
        let cameraKey: String
        let cameraLabel: String
        let rows: [DateScanRow]
    }

    /// Zerteilt die Aufnahmen jeder Kamera in Läufe.
    static func runs(in scan: DateLibraryScan, excluding claimed: Set<String>) -> [Run] {
        var result: [Run] = []

        for cameraKey in scan.cameraKeys {
            let rows = (scan.byCamera[cameraKey] ?? []).filter { !claimed.contains($0.id) }
            guard !rows.isEmpty else { continue }

            var current: [DateScanRow] = [rows[0]]
            func close() {
                guard current.count >= minRunSize else { return }
                let span = current[current.count - 1].timestamp
                    .timeIntervalSince(current[0].timestamp)
                guard span >= minRunSpan else { return }
                result.append(Run(cameraKey: cameraKey,
                                  cameraLabel: current[0].cameraLabel ?? cameraKey,
                                  rows: current))
            }

            for row in rows.dropFirst() {
                if row.timestamp.timeIntervalSince(current[current.count - 1].timestamp) > runGap {
                    close()
                    current = [row]
                } else {
                    current.append(row)
                }
            }
            close()
        }
        return result
    }

    // MARK: - Erkennung

    static func findings(in scan: DateLibraryScan, excluding claimed: Set<String>) -> [DateFinding] {
        let candidates = candidateOffsets()

        // Der Bezug hängt nur an der Kamera, nicht am Lauf. Ihn je Lauf neu aus
        // 156 000 Zeilen aufzubauen war der teuerste Teil des Durchlaufs — eine
        // Kamera mit zehn Läufen baute ihn zehnmal.
        var referenceCache: [String: [TimeInterval]] = [:]

        return runs(in: scan, excluding: claimed)
            .compactMap { run in
                let reference: [TimeInterval]
                if let cached = referenceCache[run.cameraKey] {
                    reference = cached
                } else {
                    reference = scan.timestampsExcluding(cameraKey: run.cameraKey)
                    referenceCache[run.cameraKey] = reference
                }
                return finding(for: run, reference: reference, candidates: candidates)
            }
            .sorted { a, b in
                a.assetIds.count == b.assetIds.count
                    ? a.id < b.id
                    : a.assetIds.count > b.assetIds.count
            }
    }

    private static func finding(for run: Run,
                                reference: [TimeInterval],
                                candidates: [TimeInterval]) -> DateFinding? {
        guard !reference.isEmpty else { return nil }

        // (0) Der Bezug muss die Bibliothek sein, nicht die Gegenkamera. Sonst wäre
        // die Aussage symmetrisch und das Werkzeug entschiede per Münzwurf, welche
        // der beiden Kameras falsch geht.
        guard Double(reference.count) >= minimumReferenceRatio * Double(run.rows.count)
        else { return nil }

        let times = sample(run.rows).map(\.timestamp.timeIntervalSince1970)

        // (1) Vorher getrennt. Ein Lauf, der schon verzahnt ist, hat keinen Uhrfehler
        // — er lief einfach parallel zu einer anderen Kamera. Diese eine Bedingung
        // erledigt die Fehlvorschläge der Vorgängerfassung an der Wurzel.
        let before = DateLibraryScan.interleaveFraction(
            times: times, against: reference, offset: 0, window: neighbourWindow)
        guard before <= disjointBefore else { return nil }

        // (2) Nachher verzahnt.
        guard let best = bestCandidate(times: times, reference: reference, candidates: candidates),
              best.fraction >= interleavedAfter,
              best.fraction - before >= minimumImprovement else { return nil }

        // (2a) Und zwar kennzeichnend: passt mehr als eine Handvoll Versätze, ist die
        // Deckung Zufall und sagt nur, wie voll die Bibliothek dort ist.
        guard best.matchingCandidates <= maximumMatchingCandidates else { return nil }

        // (3) Über den ganzen Lauf derselbe Betrag: jedes Drittel wählt für sich
        // denselben Kandidaten. Aussagekräftiger als eine Varianzzahl auf Residuen —
        // ein Uhrfehler verschiebt einen Block starr, er zieht ihn nicht auseinander.
        guard thirdsAgree(on: best.offset, run: run, reference: reference, candidates: candidates)
        else { return nil }

        // (4) Ortszeit: die Verschiebung darf es nicht schlechter machen.
        let longitudes = run.rows.compactMap(\.longitude)
        if let zone = DateLocalTime.utcOffsetHours(longitudes: longitudes) {
            let timestamps = run.rows.map(\.timestamp)
            let nightBefore = DateLocalTime.nightFraction(timestamps, utcOffsetHours: zone)
            let nightAfter = DateLocalTime.nightFraction(timestamps,
                                                         shiftedBy: best.offset,
                                                         utcOffsetHours: zone)
            guard nightAfter <= nightBefore else { return nil }
        }

        let evidence = CameraClockEvidence(
            cameraLabel: run.cameraLabel,
            runStart: run.rows[0].timestamp,
            runEnd: run.rows[run.rows.count - 1].timestamp,
            offset: best.offset,
            shape: DateStatistics.shape(of: best.offset),
            interleaveBefore: before,
            interleaveAfter: best.fraction,
            referenceCount: reference.count
        )

        return DateFinding(
            id: "clock:\(run.cameraKey)#\(Int(run.rows[0].timestamp.timeIntervalSince1970))",
            kind: .cameraClock(evidence),
            assetIds: run.rows.map(\.id),
            timestamps: run.rows.map(\.timestamp),
            repair: .uniformOffset(best.offset),
            referenceIds: [],
            referenceTimestamps: [],
            title: title(for: run, offset: best.offset)
        )
    }

    private static func title(for run: Run, offset: TimeInterval) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateFormat = "MMMM yyyy"
        let start = formatter.string(from: run.rows[0].timestamp)
        return "\(run.cameraLabel) — ab \(start)"
    }

    // MARK: - Kandidatensuche

    private struct Best {
        let offset: TimeInterval
        let fraction: Double
        /// Wie viele Kandidaten die Verzahnungsschwelle erreicht haben.
        var matchingCandidates: Int = 0
    }

    private static func bestCandidate(times: [TimeInterval],
                                      reference: [TimeInterval],
                                      candidates: [TimeInterval]) -> Best? {
        var best: Best?

        // Der Bezug ist sortiert: liegt der verschobene Lauf ganz außerhalb seines
        // Zeitraums, ist die Verzahnung null und die Binärsuche über alle Zeilen
        // umsonst. Das spart die Mehrzahl der Jahres-Kandidaten.
        guard let referenceLow = reference.first, let referenceHigh = reference.last,
              let low = times.min(), let high = times.max() else { return nil }

        var matching = 0

        for offset in candidates {
            if high + offset < referenceLow - neighbourWindow
                || low + offset > referenceHigh + neighbourWindow {
                if best == nil { best = Best(offset: offset, fraction: 0) }
                continue
            }

            let fraction = DateLibraryScan.interleaveFraction(
                times: times, against: reference, offset: offset, window: neighbourWindow)
            if fraction >= interleavedAfter { matching += 1 }

            guard let current = best else {
                best = Best(offset: offset, fraction: fraction)
                continue
            }
            if isBetter(offset: offset, fraction: fraction, than: current) {
                best = Best(offset: offset, fraction: fraction)
            }
        }

        guard var result = best else { return nil }
        result.matchingCandidates = matching
        return result
    }

    /// Höhere Verzahnung gewinnt; bei Gleichstand der kleinere Betrag, dann die
    /// halbe Stunde vor Tag und Jahr.
    ///
    /// Die Gleichstandsregeln sind kein Beiwerk: ohne sie hinge das Ergebnis an der
    /// Reihenfolge des Kandidatengitters.
    private static func isBetter(offset: TimeInterval,
                                 fraction: Double,
                                 than current: Best) -> Bool {
        if fraction != current.fraction { return fraction > current.fraction }
        if abs(offset) != abs(current.offset) { return abs(offset) < abs(current.offset) }
        return offset < current.offset
    }

    private static func thirdsAgree(on offset: TimeInterval,
                                    run: Run,
                                    reference: [TimeInterval],
                                    candidates: [TimeInterval]) -> Bool {
        let rows = run.rows
        guard rows.count >= 3 else { return false }

        let size = rows.count / 3
        for index in 0..<3 {
            let lower = index * size
            let upper = index == 2 ? rows.count : (index + 1) * size
            let slice = Array(rows[lower..<upper])
            let times = sample(slice).map(\.timestamp.timeIntervalSince1970)

            guard let best = bestCandidate(times: times,
                                           reference: reference,
                                           candidates: candidates),
                  best.offset == offset else { return false }
        }
        return true
    }

    /// Eine gleichmäßige Stichprobe, falls der Lauf sehr groß ist.
    private static func sample(_ rows: [DateScanRow]) -> [DateScanRow] {
        guard rows.count > sampleLimit else { return rows }
        let step = Double(rows.count) / Double(sampleLimit)
        return (0..<sampleLimit).map { rows[Int(Double($0) * step)] }
    }
}
