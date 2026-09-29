import Foundation

/// Findet Assets, die dasselbe Motiv zeigen — als exakte Dublette oder als
/// ähnliche Aufnahme.
///
/// Rein und abhängigkeitsfrei — kein SQLite, kein SwiftData, kein Netz, keine
/// Uhr. Alles, was die Suche weiß, kommt aus `[DupeScanRow]`. Damit ist der
/// gesamte Algorithmus ohne Umgebung testbar (siehe `DuplicateMatcherTests`).
///
/// Vorbild und Aufbau: `GeoMatcher`.
enum DuplicateMatcher {

    // MARK: - Feste Regeln des Modus „Dubletten"
    //
    // Bewusst nicht über `DupeParameters` regelbar: Dubletten wandern in den
    // Papierkorb, und ein aufgeweichter Schwellwert löscht dort echte Fotos.
    // Was hier steht, soll bei jedem Nutzer dasselbe finden.

    /// Praktisch deckungsgleiche Vorschau.
    static let exactThumbhashDistance = 60
    /// Deckungsgleich genug, wenn zusätzlich die Dateinamen zusammengehören —
    /// fängt dieselbe Aufnahme als HEIC und als JPEG, deren Bytezahl auseinandergeht.
    static let relatedNameThumbhashDistance = 120
    /// Toleranz beim Seitenverhältnis im strengen Modus.
    static let exactAspectTolerance = 0.02
    /// Toleranz beim Seitenverhältnis im lockeren Modus.
    static let similarAspectTolerance = 0.05
    /// „Gleiche Sekunde" — Immich rundet Zeitstempel je nach Quelle unterschiedlich.
    static let sameTimestampToleranceSeconds = 2
    /// Zulässiger Laufzeitunterschied, damit zwei Videos als dieselbe Datei gelten.
    static let videoDurationToleranceMs = 1_000
    /// Raster der Zeit-Buckets. Nachbarbuckets werden mitverglichen, damit ein
    /// Paar an der Rasterkante nicht durchfällt.
    static let timeBucketSeconds = 60
    /// Wie weit eine Regel gerissen sein darf, um noch unter „Verworfen" zu
    /// erscheinen statt ganz zu verschwinden.
    static let suppressionSlack = 1.2

    // MARK: - Einstiegspunkt

    /// Ein Durchlauf, zwei Modi.
    ///
    /// Beide Modi teilen sich Zeilenaufbereitung, Bucketbildung und
    /// Keeper-Bewertung — sonst könnten die zwei Ansichten für dieselbe
    /// Bibliothek verschiedene Bestände melden.
    static func scan(
        rows: [DupeScanRow],
        parameters: DupeParameters,
        ignoredPairs: Set<String> = []
    ) -> DupeScanResult {

        guard !rows.isEmpty else { return .empty }

        // Nach (Zeit, ID) statt nur nach Zeit: bei gleichem Zeitstempel wäre die
        // Reihenfolge sonst von der Eingabe abhängig, und damit auch das Ergebnis.
        let sorted = rows.sorted {
            $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp
        }
        var byId: [String: DupeScanRow] = [:]
        byId.reserveCapacity(sorted.count)
        for row in sorted { byId[row.id] = row }

        var rowsWithoutThumbhash = 0
        for row in sorted where row.thumbhash == nil { rowsWithoutThumbhash += 1 }

        var nameRootCache: [String: String] = [:]
        let buckets = makeBuckets(sorted, nameRootCache: &nameRootCache)

        var candidateCount = 0
        var skippedBuckets = 0

        var exactPairs: [(String, String)] = []
        var similarPairs: [(String, String)] = []
        var nearMisses: [(String, String, String)] = []   // a, b, Begründung

        var seen = Set<String>()

        for bucket in buckets {
            guard bucket.count >= 2 else { continue }
            // Der Schutz gegen n²: ein Bucket mit 5.000 Zeilen ergäbe 12,5 Mio.
            // Vergleiche. Übersprungen und gezählt — nicht still verworfen.
            guard bucket.count <= parameters.maxBucketSize else {
                skippedBuckets += 1
                continue
            }

            for i in bucket.indices {
                for j in (i + 1)..<bucket.count {
                    let a = bucket[i]
                    let b = bucket[j]
                    let key = DupeIgnoredPair.key(a.id, b.id)
                    guard !seen.contains(key) else { continue }
                    seen.insert(key)
                    candidateCount += 1

                    guard !ignoredPairs.contains(key) else { continue }

                    switch classify(a, b, parameters: parameters) {
                    case .exact:
                        exactPairs.append((a.id, b.id))
                        // Eine Dublette ist auch eine ähnliche Aufnahme. Ohne das
                        // fehlten im lockeren Modus ausgerechnet die sichersten Funde.
                        similarPairs.append((a.id, b.id))
                    case .similar:
                        similarPairs.append((a.id, b.id))
                    case .nearMiss(let reason):
                        nearMisses.append((a.id, b.id, reason))
                    case .no:
                        break
                    }
                }
            }
        }

        let exactGroups = buildGroups(
            from: exactPairs, mode: .exact, byId: byId, ignoredPairs: ignoredPairs
        )
        let similarGroups = buildGroups(
            from: similarPairs, mode: .similar, byId: byId, ignoredPairs: ignoredPairs
        )

        // Knappe Treffer erscheinen nur, wenn sie nicht ohnehin schon in einer
        // regulären Gruppe stecken — sonst stünde dasselbe Paar zweimal da.
        let placed = Set(exactGroups.flatMap(\.assetIds) + similarGroups.flatMap(\.assetIds))
        var suppressed: [DupeSuppressedGroup] = []
        var suppressedSeen = Set<String>()
        for (aId, bId, reason) in nearMisses {
            guard !placed.contains(aId), !placed.contains(bId) else { continue }
            let key = DupeIgnoredPair.key(aId, bId)
            guard suppressedSeen.insert(key).inserted else { continue }
            guard let group = makeGroup(
                assetIds: [aId, bId], mode: .similar, byId: byId
            ) else { continue }
            suppressed.append(DupeSuppressedGroup(group: group, reason: reason))
        }
        suppressed.sort { $0.group.id < $1.group.id }

        return DupeScanResult(
            exactGroups: exactGroups,
            similarGroups: similarGroups,
            suppressed: suppressed,
            scannedRows: sorted.count,
            candidatePairCount: candidateCount,
            skippedOversizedBuckets: skippedBuckets,
            rowsWithoutThumbhash: rowsWithoutThumbhash
        )
    }

    // MARK: - Buckets

    /// Kandidatenpaare entstehen über fünf Buckets statt über n² Vergleiche.
    ///
    /// Jeder Bucket fängt einen anderen Fall:
    /// 1. **Identität** (Typ + Bytezahl + Maße) — dieselbe Datei, unabhängig davon,
    ///    wann sie importiert wurde. Ohne jede Zeitschranke.
    /// 2. **Checksum** — aus demselben Grund ohne Zeitschranke: Ein Reimport
    ///    findet sein Gegenstück über die Server-Checksum, egal wie weit die
    ///    Aufnahmezeiten auseinanderliegen.
    /// 3. **Dateinamen-Wurzel** — `IMG_1234.HEIC` und `IMG_1234 (1).jpg`.
    /// 4. **Zeitfenster** — Serien und Bursts, die weder Name noch Größe verbindet.
    /// 5. **Byte-gleicher Thumbhash** — Reimports, bei denen sonst nichts mehr
    ///    übereinstimmt (siehe Kommentar an der Bucketbildung).
    private static func makeBuckets(
        _ rows: [DupeScanRow],
        nameRootCache: inout [String: String]
    ) -> [[DupeScanRow]] {

        var identity: [String: [DupeScanRow]] = [:]
        var byChecksum: [String: [DupeScanRow]] = [:]
        var byName: [String: [DupeScanRow]] = [:]
        var byTime: [Int: [DupeScanRow]] = [:]
        var byThumbhash: [[UInt8]: [DupeScanRow]] = [:]

        for row in rows {
            if let key = row.identityKey {
                identity[key, default: []].append(row)
            }
            if let checksum = row.checksum {
                byChecksum[checksum, default: []].append(row)
            }
            let root = cachedRoot(row.fileName, cache: &nameRootCache)
            if !root.isEmpty {
                byName[root, default: []].append(row)
            }
            byTime[row.timestamp / timeBucketSeconds, default: []].append(row)
            // 5. **Byte-gleicher Thumbhash** — fängt Reimports, bei denen sonst
            // nichts mehr übereinstimmt: neu geschriebene Datei (andere Checksum,
            // andere Bytezahl), umbenannt und mit verschobener Aufnahmezeit.
            // Bewusst exakte Gleichheit statt Abstandssuche: Nachbarschaft über
            // 25-Byte-Hashes wäre n², und die knappen Fälle fängt weiterhin der
            // Namens- oder Zeit-Bucket.
            if let hash = row.thumbhash {
                byThumbhash[hash, default: []].append(row)
            }
        }

        var out: [[DupeScanRow]] = []
        out.append(contentsOf: identity.values)
        out.append(contentsOf: byChecksum.values)
        out.append(contentsOf: byName.values)
        out.append(contentsOf: byThumbhash.values)

        // Zeit-Buckets samt Nachbarn, damit ein Paar an der Rasterkante
        // (Sekunde 59 und Sekunde 61) nicht auseinanderfällt.
        for (bucket, group) in byTime {
            if let next = byTime[bucket + 1] {
                out.append(group + next)
            } else {
                out.append(group)
            }
        }
        return out
    }

    private static func cachedRoot(_ name: String, cache: inout [String: String]) -> String {
        if let hit = cache[name] { return hit }
        let root = filenameRoot(name)
        cache[name] = root
        return root
    }

    // MARK: - Paarprüfung

    enum Classification: Equatable {
        case exact
        case similar
        /// Eine Regel knapp gerissen — wird gezählt und auf Wunsch angezeigt.
        case nearMiss(String)
        case no
    }

    /// Die vollständigen Regeln beider Modi an genau einer Stelle.
    static func classify(
        _ a: DupeScanRow,
        _ b: DupeScanRow,
        parameters: DupeParameters
    ) -> Classification {

        guard a.id != b.id else { return .no }
        // Ein Foto und sein Live-Photo-Video sind kein Duplikat.
        guard a.type == b.type else { return .no }

        let timeDelta = abs(a.timestamp - b.timestamp)
        let related = namesRelated(a.fileName, b.fileName)
        let aspectDelta = aspectDelta(a, b)

        // --- Modus „Dubletten" ---

        // Regel 0: dieselbe Checksum ⇒ byte-identische Datei. Keine weitere
        // Absicherung nötig — identische Bytes zeigen identische Bilder. Und wie
        // Regel 1 bewusst ohne Zeitschranke (Reimports).
        let checksumsComparable = a.checksum != nil && b.checksum != nil
        if checksumsComparable, a.checksum == b.checksum {
            return .exact
        }

        // Regel 1: dieselbe Datei. Bewusst ohne jede Zeitschranke — genau hier
        // verliert die Web-Vorlage Reimports, die Monate auseinanderliegen.
        //
        // Die Bytezahl allein trägt diese Aussage **nicht**. Bei JPEG macht die
        // Kompression jedes Bild anders groß, bei RAW nicht: Zwei Aufnahmen
        // derselben Kamera sind dort praktisch immer gleich groß und gleich groß
        // dimensioniert. Ohne die Vorschauprüfung erklärt die Regel darum
        // beliebige RAW-Paare für dieselbe Datei — und weil Union-Find
        // transitiv arbeitet, verschmilzt eine einzige solche Kante zwei
        // vollständig fremde Aufnahmeserien zu einer Gruppe.
        //
        // Dieselbe Datei zeigt dasselbe Bild. Also muss auch die Vorschau passen.
        //
        // Nur erreichbar, wenn keine der beiden Checksums vorliegt: Sind beide
        // vorhanden und ungleich, ist „dieselbe Datei" durch Regel 0 bereits
        // widerlegt — Größe und Maße dürfen das nicht überstimmen. Sind beide
        // vorhanden und gleich, hat Regel 0 schon geliefert.
        if !checksumsComparable,
           let keyA = a.identityKey, keyA == b.identityKey, durationsMatch(a, b),
           previewsAgree(a, b, related: related, timeDelta: timeDelta) {
            return .exact
        }

        // Regeln 2 und 3 beruhen auf der Vorschau — und die ist bei Videos das
        // Startbild. Ein Zuschnitt vom Ende her lässt es unangetastet: Abstand 0,
        // gleiches Seitenverhältnis, unveränderte Aufnahmezeit, und der Name ist
        // eine Fassung des Originals. Beide Regeln erklärten die zwei damit für
        // dieselbe Datei, obwohl aus einer Stunde Video zwölf Sekunden geworden
        // waren — und der Verlierer einer Dublettengruppe wandert in den
        // Papierkorb.
        //
        // Regel 1 kennt diese Absicherung längst; sie fehlte nur hier. Eine
        // abweichende Laufzeit ist ein **Beleg für verschiedenen Inhalt**, den
        // keine Vorschau überstimmen darf. `durationsMatch` schweigt zu Bildern
        // und zu fehlenden Laufzeiten — es verwirft ausschließlich, was
        // nachweislich nicht zusammenpasst. Der HDR/SDR-Fall aus Apple Fotos
        // (`FullSizeRender` neben dem Original) hat dieselbe Laufzeit und bleibt
        // deshalb ein Fund.
        //
        // Als Dublette fällt das Paar damit weg, aus dem Blick gerät es nicht:
        // Unter „Ähnliche Aufnahmen" steht es weiter, und dort entscheidet der
        // Nutzer selbst.
        let laufzeitPasst = durationsMatch(a, b)

        // Regel 2: deckungsgleiche Vorschau bei praktisch gleichem Zuschnitt,
        // abgesichert durch Name oder Aufnahmezeit.
        if laufzeitPasst, let dist = thumbhash(a, b, maxDistance: relatedNameThumbhashDistance) {
            let aspectOK = aspectDelta.map { $0 <= exactAspectTolerance } ?? false
            if dist <= exactThumbhashDistance, aspectOK,
               related || timeDelta <= sameTimestampToleranceSeconds {
                return .exact
            }
            // Regel 3: verwandte Namen erlauben mehr Abstand — dieselbe Aufnahme
            // in einem anderen Format hat eine merklich andere Vorschau.
            //
            // „Anderes Format" heißt HEIC statt JPEG, nicht anderer Zuschnitt: Eine
            // Formatwandlung lässt das Seitenverhältnis unberührt. Weichen die
            // Seitenverhältnisse **nachweislich** voneinander ab, ist es nicht
            // dieselbe Datei, sondern ein Ausschnitt — und `IMG_1234.jpg` neben
            // `IMG_1234_crop.jpg` trägt genau die Namensverwandtschaft, die diese
            // Regel großzügig macht. Als Dublette gemeldet, ginge einer von beiden
            // in den Papierkorb.
            //
            // Bewusst `?? true` statt `?? false` wie in Regel 2: Fehlen die Maße,
            // bleibt es beim bisherigen Verhalten. Ausgeschlossen wird nur, was
            // *bekanntermaßen* nicht zusammenpasst — kein Fund geht dadurch
            // verloren, den die Daten stützen.
            let aspectKnownGood = aspectDelta.map { $0 <= exactAspectTolerance } ?? true
            if related, aspectKnownGood, dist <= relatedNameThumbhashDistance {
                return .exact
            }
        }

        // --- Modus „Ähnliche Aufnahmen" ---

        guard let dist = thumbhash(
            a, b, maxDistance: Int(Double(parameters.similarityDistance) * suppressionSlack)
        ) else {
            return .no
        }
        guard let aspectDelta else { return .no }

        let aspectOK = aspectDelta <= similarAspectTolerance
        let timeOK = timeDelta <= parameters.timeWindowSeconds
        let distOK = dist <= parameters.similarityDistance

        if aspectOK, timeOK, distOK { return .similar }

        // Praktisch deckungsgleiche Vorschau bei gleichem Zuschnitt: dasselbe
        // Bild, auch wenn jede andere Angabe auseinanderläuft — der Fall des
        // umbenannten Reimports mit verschobener Aufnahmezeit (Bucket 5). Für
        // den Papierkorb fehlt der zweite Beleg (Name oder Aufnahmesekunde,
        // siehe Regel 2), aber unsichtbar bleiben darf so ein Paar nicht:
        // Unter „Ähnliche Aufnahmen" entscheidet der Nutzer selbst.
        if dist <= exactThumbhashDistance, aspectDelta <= exactAspectTolerance {
            return .similar
        }

        // Knapp daneben: genau eine Bedingung gerissen, und die nur wenig.
        if aspectOK, timeOK, dist <= Int(Double(parameters.similarityDistance) * suppressionSlack) {
            return .nearMiss("Vorschau-Abstand \(dist) statt \(parameters.similarityDistance)")
        }
        if aspectOK, distOK,
           timeDelta <= Int(Double(parameters.timeWindowSeconds) * suppressionSlack) {
            return .nearMiss("\(timeDelta) s auseinander statt \(parameters.timeWindowSeconds) s")
        }
        return .no
    }

    private static func aspectDelta(_ a: DupeScanRow, _ b: DupeScanRow) -> Double? {
        guard let ra = a.aspectRatio, let rb = b.aspectRatio else { return nil }
        return abs(ra - rb)
    }

    /// Zeigen zwei Zeilen dasselbe Bild?
    ///
    /// Die Absicherung der Identitätsregel. Byte-gleiche Dateien haben denselben
    /// Thumbhash, der Abstand ist dann 0 — die Schranke ist also großzügig und
    /// verwirft nur, was sichtbar verschieden ist.
    ///
    /// Fehlt bei einer der beiden die Vorschau, kann die Frage nicht beantwortet
    /// werden. Dann muss ein anderer Beleg her: derselbe Dateiname oder dieselbe
    /// Aufnahmesekunde. Ohne beides bleibt es bei „nein" — lieber eine echte
    /// Dublette übersehen als zwei fremde Serien verschmelzen.
    private static func previewsAgree(
        _ a: DupeScanRow, _ b: DupeScanRow, related: Bool, timeDelta: Int
    ) -> Bool {
        guard let dist = thumbhash(a, b, maxDistance: exactThumbhashDistance) else {
            return related || timeDelta <= sameTimestampToleranceSeconds
        }
        return dist <= exactThumbhashDistance
    }

    /// Videos gelten nur als dieselbe Datei, wenn auch die Laufzeit passt.
    /// Fehlt sie bei einem der beiden, entscheidet allein die Identitätsregel.
    private static func durationsMatch(_ a: DupeScanRow, _ b: DupeScanRow) -> Bool {
        guard a.type == .video else { return true }
        guard let da = a.durationMs, let db = b.durationMs else { return true }
        return abs(da - db) <= videoDurationToleranceMs
    }

    private static func thumbhash(
        _ a: DupeScanRow, _ b: DupeScanRow, maxDistance: Int
    ) -> Int? {
        guard let ha = a.thumbhash, let hb = b.thumbhash else { return nil }
        let dist = thumbhashDistance(ha, hb, maxDistance: maxDistance)
        return dist == Int.max ? nil : dist
    }

    // MARK: - Thumbhash

    /// L1-Abstand über die dekodierten Thumbhash-Bytes, mit Früh-Abbruch.
    ///
    /// Kein echter Hamming-Abstand: Immichs Thumbhash ist ein kompaktes
    /// Vorschaubild, kein Bit-Hash. Die Bytes taxieren Helligkeit und Farbe, ihre
    /// Beträge sind damit aussagekräftiger als ihre Bits.
    ///
    /// Unterschiedlich lange Hashes — verschiedene Thumbhash-Fassungen des Servers —
    /// ergeben `Int.max` statt eines Absturzes oder eines erfundenen Vergleichs.
    static func thumbhashDistance(
        _ a: [UInt8], _ b: [UInt8], maxDistance: Int = .max
    ) -> Int {
        guard a.count == b.count, !a.isEmpty else { return .max }
        var total = 0
        for i in a.indices {
            total += abs(Int(a[i]) - Int(b[i]))
            if total > maxDistance { return total }
        }
        return total
    }

    // MARK: - Dateinamen

    private static let uuidPattern = try? NSRegularExpression(
        pattern: "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}",
        options: .caseInsensitive
    )
    private static let trailingVariantPattern = try? NSRegularExpression(
        pattern: "[ _-]*(edited|bearbeitet|original|copy|kopie|final|new|old|v[0-9]{1,2})$",
        options: .caseInsensitive
    )
    private static let parenCounterPattern = try? NSRegularExpression(
        pattern: "[ _-]*\\([0-9]{1,3}\\)$"
    )
    /// Ein vorangestelltes Datum — `20000808-` oder `2000-08-08 ` — stammt vom
    /// Import-Werkzeug, nicht von der Kamera. Eng auf Jahreszahlen 19xx/20xx
    /// begrenzt: Eine beliebige achtstellige Zahl ist oft selbst der Name.
    private static let leadingDatePattern = try? NSRegularExpression(
        pattern: "^(19|20)[0-9]{2}(-?)[0-9]{2}\\2[0-9]{2}[ _-]"
    )

    /// Die gemeinsame Wurzel zweier Fassungen derselben Datei.
    ///
    /// `IMG_1234 (1).jpg`, `IMG_1234_edited.HEIC` und `IMG_1234.jpg` ergeben alle
    /// `img_1234`. Schrumpft das Ergebnis unter drei Zeichen, gilt der volle Name
    /// ohne Endung — eine Wurzel wie `a` verbände sonst hunderte fremde Dateien.
    static func filenameRoot(_ fileName: String) -> String {
        var name = (fileName as NSString).deletingPathExtension
        guard !name.isEmpty else { return "" }

        // Apple-Exporte hängen eine UUID an den Originalnamen. Sie unterscheidet
        // gerade die Kopien, die hier zusammengehören sollen.
        name = replacingMatches(uuidPattern, in: name, with: "")

        // Umbenannte Reimports: `20000808-urlaub2k_46.jpg` neben
        // `urlaub2k_46.jpg` ist dieselbe Aufnahme, einmal mit Datums-Präfix.
        name = replacingMatches(leadingDatePattern, in: name, with: "")

        var previous: String
        repeat {
            previous = name
            name = replacingMatches(parenCounterPattern, in: name, with: "")
            name = replacingMatches(trailingVariantPattern, in: name, with: "")
        } while name != previous

        name = name.trimmingCharacters(in: CharacterSet(charactersIn: " _-"))
        let lowered = name.lowercased()
        guard lowered.count >= 3 else {
            return (fileName as NSString).deletingPathExtension.lowercased()
        }
        return lowered
    }

    private static func replacingMatches(
        _ regex: NSRegularExpression?, in text: String, with template: String
    ) -> String {
        guard let regex else { return text }
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: template
        )
    }

    /// Gehen zwei Dateinamen auf dieselbe Aufnahme zurück?
    ///
    /// Verlangt wird, dass eine Wurzel die andere als Präfix enthält. Das allein
    /// trennt schon `IMG_0932` von `IMG_0987` — beide sind gleich lang, keine ist
    /// Präfix der anderen.
    ///
    /// Die Ziffernprüfung fängt den Fall, den die Präfixregel durchlässt:
    /// `IMG_123` *ist* ein Präfix von `IMG_1234`, und das sind zwei verschiedene
    /// Aufnahmen. Liegen die Zähler weit auseinander, gehören die Dateien nicht
    /// zusammen.
    static func namesRelated(_ a: String, _ b: String) -> Bool {
        let rootA = filenameRoot(a)
        let rootB = filenameRoot(b)
        guard !rootA.isEmpty, !rootB.isEmpty else { return false }
        guard rootA.hasPrefix(rootB) || rootB.hasPrefix(rootA) else { return false }
        if rootA == rootB { return true }

        // Der längere Name muss **hinter** dem kürzeren etwas anderes anfangen als ein
        // weiteres Wort. „urlaub" und „urlaubsfoto" sind keine zwei Fassungen derselben
        // Datei, sondern zwei Dateien — und das ist hier teuer: Ein „verwandter Name"
        // lockert die Dublettenschwelle von `exactThumbhashDistance` (60) auf
        // `relatedNameThumbhashDistance` (120). Zwei verschiedene Fotos derselben
        // Szene rutschten damit von „ähnlich" auf „Dublette", und die Verlierer einer
        // Dublettengruppe wandern in den Papierkorb.
        //
        // Trennzeichen und Ziffern bleiben erlaubt: `img_1234` ↔ `img_1234_x` ist der
        // Normalfall, und `img_1234` ↔ `img_12345` fängt gleich darunter der
        // Ziffernvergleich ab.
        let laenger = rootA.count > rootB.count ? rootA : rootB
        let kuerzer = rootA.count > rootB.count ? rootB : rootA
        let rest = laenger.dropFirst(kuerzer.count)
        if let ersteImRest = rest.first, ersteImRest.isLetter { return false }

        if let numA = numericSuffix(rootA), let numB = numericSuffix(rootB) {
            return abs(numA - numB) <= 5
        }
        return true
    }

    /// Die abschließende Ziffernfolge eines Namens, falls vorhanden.
    static func numericSuffix(_ root: String) -> Int? {
        let digits = root.reversed().prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        return Int(String(digits.reversed()))
    }

    // MARK: - Gruppierung

    private static func buildGroups(
        from pairs: [(String, String)],
        mode: DupeMode,
        byId: [String: DupeScanRow],
        ignoredPairs: Set<String>
    ) -> [DupeGroup] {

        let components = unionFind(pairs: pairs, ignoredPairs: ignoredPairs)
        var groups: [DupeGroup] = []
        for ids in components where ids.count >= 2 {
            if let group = makeGroup(assetIds: ids, mode: mode, byId: byId) {
                groups.append(group)
            }
        }
        // Größter Gewinn zuerst; bei Gleichstand der Fingerabdruck, damit zweimal
        // Scannen zweimal dieselbe Reihenfolge ergibt.
        groups.sort {
            $0.reclaimableBytes == $1.reclaimableBytes
                ? $0.id < $1.id
                : $0.reclaimableBytes > $1.reclaimableBytes
        }
        return groups
    }

    /// Union-Find mit Pfadverkürzung und Rang.
    ///
    /// Transitivität ist hier die Pointe: Findet die Suche A≈B und B≈C, gehören
    /// alle drei in eine Gruppe — sonst müsste der Nutzer dasselbe Motiv zweimal
    /// entscheiden. Ignorierte Paare werden nicht vereinigt; eine dadurch
    /// zerfallende Gruppe ist das gewünschte Ergebnis.
    static func unionFind(
        pairs: [(String, String)], ignoredPairs: Set<String> = []
    ) -> [[String]] {

        var parent: [String: String] = [:]
        var rank: [String: Int] = [:]

        func find(_ x: String) -> String {
            var root = x
            while let p = parent[root], p != root { root = p }
            // Pfadverkürzung: alle besuchten Knoten direkt an die Wurzel hängen.
            var cursor = x
            while let p = parent[cursor], p != root {
                parent[cursor] = root
                cursor = p
            }
            return root
        }

        func union(_ a: String, _ b: String) {
            let ra = find(a)
            let rb = find(b)
            guard ra != rb else { return }
            let rankA = rank[ra] ?? 0
            let rankB = rank[rb] ?? 0
            if rankA < rankB {
                parent[ra] = rb
            } else if rankA > rankB {
                parent[rb] = ra
            } else {
                parent[rb] = ra
                rank[ra] = rankA + 1
            }
        }

        for (a, b) in pairs {
            if parent[a] == nil { parent[a] = a }
            if parent[b] == nil { parent[b] = b }
            guard !ignoredPairs.contains(DupeIgnoredPair.key(a, b)) else { continue }
            union(a, b)
        }

        var components: [String: [String]] = [:]
        for node in parent.keys {
            components[find(node), default: []].append(node)
        }
        return components.values.map { $0.sorted() }
    }

    private static func makeGroup(
        assetIds: [String], mode: DupeMode, byId: [String: DupeScanRow]
    ) -> DupeGroup? {

        let rows = assetIds.compactMap { byId[$0] }
        guard rows.count >= 2 else { return nil }

        // Absteigend nach Punkten; bei Gleichstand die ältere Aufnahme, dann die
        // kleinere ID. Ohne diese zwei Stufen hinge der Keeper an der zufälligen
        // Reihenfolge aus dem Union-Find.
        // Die Punkte einmal je Zeile, nicht je Vergleich: `keeperScore` sieht mit
        // `among` die ganze Gruppe und liefe sonst quadratisch in der Sortierung.
        let scores = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, keeperScore($0, among: rows)) })
        let ranked = rows.sorted { lhs, rhs in
            let sl = scores[lhs.id] ?? 0
            let sr = scores[rhs.id] ?? 0
            if sl != sr { return sl > sr }
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            return lhs.id < rhs.id
        }
        let keeper = ranked[0]

        var reasons: DupeMatchReason = []
        let checksums = Set(ranked.compactMap(\.checksum))
        if checksums.count == 1, ranked.allSatisfy({ $0.checksum != nil }) {
            reasons.insert(.identicalChecksum)
        }
        let identityKeys = Set(ranked.compactMap(\.identityKey))
        if identityKeys.count == 1, ranked.allSatisfy({ $0.identityKey != nil }) {
            reasons.insert(.identicalSizeAndDimensions)
        }
        if ranked.dropFirst().allSatisfy({ namesRelated(keeper.fileName, $0.fileName) }) {
            reasons.insert(.relatedFilename)
        }
        let timestamps = ranked.map(\.timestamp)
        let span = (timestamps.max() ?? 0) - (timestamps.min() ?? 0)
        if span <= sameTimestampToleranceSeconds {
            reasons.insert(.sameTimestamp)
        } else if span <= timeBucketSeconds {
            reasons.insert(.closeInTime)
        }
        if let hash = keeper.thumbhash {
            let worst = ranked.dropFirst().map { row -> Int in
                guard let other = row.thumbhash else { return .max }
                return thumbhashDistance(hash, other)
            }.max() ?? Int.max
            if worst <= exactThumbhashDistance { reasons.insert(.nearIdenticalThumbhash) }
        }

        let reclaimable = ranked.dropFirst().reduce(0) { $0 + ($1.fileSize ?? 0) }

        return DupeGroup(
            id: groupFingerprint(assetIds),
            mode: mode,
            assetIds: ranked.map(\.id),
            suggestedKeeperId: keeper.id,
            reasons: reasons,
            confidence: confidenceScore(reasons: reasons, mode: mode),
            timeSpanSeconds: span,
            reclaimableBytes: reclaimable
        )
    }

    /// Stabiler Fingerabdruck über die enthaltenen Assets.
    ///
    /// Eigene FNV-1a-Rechnung statt `hashValue`: Swifts Hash ist pro Programmlauf
    /// zufällig gesalzen, die Gruppen-Identität würde bei jedem Start wechseln —
    /// und mit ihr die Auswahl und jeder Keeper-Override.
    static func groupFingerprint(_ assetIds: [String]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for id in assetIds.sorted() {
            for byte in id.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x100_0000_01b3
            }
            hash ^= 0x2f                                  // Trenner zwischen IDs
            hash = hash &* 0x100_0000_01b3
        }
        return "dupe_\(String(hash, radix: 36))_\(assetIds.count)"
    }

    // MARK: - Bewertung

    /// Wie sicher die Gruppe ist, 0…100.
    static func confidenceScore(reasons: DupeMatchReason, mode: DupeMode) -> Int {
        var score = mode == .exact ? 60 : 40
        if reasons.contains(.identicalChecksum) { score += 40 }
        if reasons.contains(.identicalSizeAndDimensions) { score += 35 }
        if reasons.contains(.nearIdenticalThumbhash) { score += 20 }
        if reasons.contains(.relatedFilename) { score += 15 }
        if reasons.contains(.sameTimestamp) { score += 10 }
        else if reasons.contains(.closeInTime) { score += 5 }
        return min(100, score)
    }

    // MARK: - Keeper
    //
    // Genau eine Formel, an genau einer Stelle. Die Web-Vorlage bewertet an drei
    // Orten unterschiedlich — dort gewinnt je nach Ansicht ein anderes Foto, und
    // eine der drei Formeln übergeht Favoriten vollständig.

    static let keeperWeightFavorite = 150.0
    static let keeperWeightEdited = 40.0
    /// Apples flachgerechneter Export wiegt weniger als eine echte
    /// Bearbeitungsfassung — siehe `isFlattenedRender`.
    static let keeperWeightRender = 20.0
    static let keeperWeightGPS = 15.0
    static let keeperMaxMegapixels = 24.0
    static let keeperMaxSizeMB = 10.0
    static let keeperWeightExif = 5.0
    /// Muss `keeperWeightEdited` samt vollem Auflösungsvorsprung überwiegen: Die
    /// Bearbeitung hängt bei Video Boost am Platzhalter, nicht am Ergebnis.
    static let keeperWeightBundleMain = 60.0
    /// Deckel für die Bitrate in MB/s. 4K-HDR liegt bei rund 10, der Deckel lässt
    /// darüber noch Luft, ohne dass ein einzelner Ausreißer alles andere erdrückt.
    static let keeperMaxBitrateMBps = 20.0
    /// Ab welchem Pixelverhältnis ein Geschwister als *die* höher aufgelöste
    /// Fassung gilt und der Bearbeitungsbonus entfällt.
    static let keeperResolutionGapFactor = 2.0

    /// Ein Dateibündel der Pixel-Kamera: mehrere Dateien zu **einer** Aufnahme,
    /// verbunden über den Namensstamm.
    ///
    /// Die Pixel-Kamera legt bei einigen Betriebsarten mehrere Dateien an und
    /// nummeriert sie im Namen durch:
    ///
    /// ```
    /// PXL_20250809_133921523.VB-01.COVER.mp4   ← lokaler Platzhalter
    /// PXL_20250809_133921523.VB-02.MAIN.mp4    ← Ergebnis aus der Cloud
    /// PXL_20250809_133921523.RAW-01.COVER.jpg  ← das angezeigte JPEG
    /// PXL_20250809_133921523.RAW-02.ORIGINAL.dng
    /// ```
    ///
    /// `COVER` ist jeweils die Fassung, die die Galerie sofort anzeigen kann,
    /// während die eigentliche Aufnahme noch verarbeitet wird oder in einem
    /// Format vorliegt, das sich nicht direkt darstellen lässt. Google
    /// dokumentiert die Suffixe nicht — die Bedeutung ergibt sich aus dem
    /// RAW-Fall, wo sie sich aus den Dateitypen selbst ablesen lässt.
    ///
    /// Ausgewertet wird deshalb **nur die Nummer**, nicht das Rollenwort: Sie
    /// steht in beiden Betriebsarten für dieselbe Reihenfolge, und ein
    /// unbekanntes viertes Rollenwort bricht die Regel damit nicht.
    struct PixelBundle: Equatable, Sendable {
        /// Der gemeinsame Stamm, z. B. `PXL_20250809_133921523`.
        let base: String
        /// Die Betriebsart, z. B. `VB` (Video Boost) oder `RAW`.
        let mode: String
        /// Position im Bündel. Die höhere Nummer trägt das Endergebnis.
        let sequence: Int
    }

    static func pixelBundle(_ fileName: String) -> PixelBundle? {
        let bereich = NSRange(fileName.startIndex..<fileName.endIndex, in: fileName)
        guard let treffer = bundlePattern.firstMatch(in: fileName, range: bereich),
              let base = Range(treffer.range(at: 1), in: fileName),
              let mode = Range(treffer.range(at: 2), in: fileName),
              let seq = Range(treffer.range(at: 3), in: fileName),
              let nummer = Int(fileName[seq])
        else { return nil }
        return PixelBundle(
            base: String(fileName[base]),
            mode: String(fileName[mode]).uppercased(),
            sequence: nummer
        )
    }

    /// `<Stamm>.<KÜRZEL>-<NN>.<Rolle>` — der Punkt vor dem Kürzel und der Punkt
    /// dahinter sind beide nötig. Ohne sie träfe das Muster auch `urlaub-01.jpg`,
    /// und jede durchnummerierte Serie geriete unter die Bündelregel.
    private static let bundlePattern: NSRegularExpression =
        try! NSRegularExpression(pattern: #"^(.+)\.([A-Za-z]+)-(\d+)\."#)

    /// - Parameter group: Alle Zeilen der Gruppe, `row` eingeschlossen. Leer, wenn
    ///   eine einzelne Zeile für sich bewertet wird — dann entfallen die Regeln,
    ///   die einen Vergleich brauchen.
    static func keeperScore(_ row: DupeScanRow, among group: [DupeScanRow] = []) -> Double {
        var score = 0.0
        // Eine Favoritenmarkierung ist eine bewusste Entscheidung des Nutzers und
        // schlägt jede Messgröße.
        if row.isFavorite { score += keeperWeightFavorite }
        // Reihenfolge zählt: Ein `FullSizeRender` trägt auch „edited" im Sinne
        // von „bearbeitet", soll aber den kleineren Bonus bekommen.
        if isFlattenedRender(row.fileName) {
            score += keeperWeightRender
        } else if isEditedVersion(row.fileName), !isOutresolvedBy(row, in: group) {
            score += keeperWeightEdited
        }
        if leadsBundle(row, in: group) { score += keeperWeightBundleMain }
        score += min(row.megapixels ?? 0, keeperMaxMegapixels)
        if row.hasCoordinates { score += keeperWeightGPS }
        score += min(sizeMeasure(row), keeperMaxSizeMB)
        score += row.exifCompleteness * keeperWeightExif
        return score
    }

    /// Der Größenterm — bei Videos die Bitrate, sonst die Dateigröße.
    ///
    /// Die absolute Dateigröße misst bei Videos die falsche Sache: Sie wächst mit
    /// der Laufzeit, nicht mit der Qualität, und der Deckel von 10 MB ist um zwei
    /// Größenordnungen zu niedrig — 61 MB und 453 MB liefen beide dagegen und
    /// waren nicht mehr zu unterscheiden. Bytes pro Sekunde trennt beides sauber.
    private static func sizeMeasure(_ row: DupeScanRow) -> Double {
        let bytes = Double(row.fileSize ?? 0)
        guard row.type == .video, let ms = row.durationMs, ms > 0 else {
            return bytes / 1_000_000
        }
        let proSekunde = bytes / (Double(ms) / 1_000) / 1_000_000
        // Auf denselben Wertebereich gebracht wie der Fototerm, damit ein Deckel
        // für beide reicht.
        return min(proSekunde, keeperMaxBitrateMBps) / keeperMaxBitrateMBps * keeperMaxSizeMB
    }

    /// Ob ein Geschwister aus demselben Bündel eine höhere Nummer trägt — dann ist
    /// `row` der Platzhalter und das Geschwister das Ergebnis.
    private static func leadsBundle(_ row: DupeScanRow, in group: [DupeScanRow]) -> Bool {
        guard let eigen = pixelBundle(row.fileName) else { return false }
        let geschwister = group.compactMap { other -> PixelBundle? in
            guard other.id != row.id, let b = pixelBundle(other.fileName),
                  b.base == eigen.base, b.mode == eigen.mode
            else { return nil }
            return b
        }
        // Ohne Geschwister im selben Bündel sagt die Nummer nichts aus.
        guard !geschwister.isEmpty else { return false }
        return geschwister.allSatisfy { $0.sequence < eigen.sequence }
    }

    /// Ob ein Geschwister deutlich mehr Pixel hat.
    ///
    /// Der Bonus für „bearbeitet" ist mit 40 Punkten größer als der gesamte
    /// mögliche Auflösungsvorsprung (Deckel 24) — ohne diese Ausnahme konnte
    /// **keine** Fassung je einen `_edited`-Geschwister schlagen, gleich wie klein
    /// dieser war. Das trifft genau den Fall, in dem die Bearbeitung an einer
    /// Vorschaufassung hängt statt am Original.
    ///
    /// Der Bonus entfällt hier, statt in einen Malus zu kippen: Bei gleicher
    /// Auflösung — dem Normalfall eines Exports — bleibt die Bearbeitung vorn,
    /// denn sie ist dort die einzige Fassung, die sie überhaupt enthält.
    private static func isOutresolvedBy(_ row: DupeScanRow, in group: [DupeScanRow]) -> Bool {
        guard let eigen = row.megapixels, eigen > 0 else { return false }
        return group.contains { other in
            guard other.id != row.id, let fremd = other.megapixels else { return false }
            return fremd >= eigen * keeperResolutionGapFactor
        }
    }

    /// Ob der Dateiname eine Bearbeitungsfassung ankündigt.
    ///
    /// Als **eigenständiges Wort**, nicht als Teilzeichenkette — und das ist hier kein
    /// Feinschliff, sondern kehrt die Aussage um: „un**bearbeitet**" enthält
    /// „bearbeitet" und bekäme sonst den Bonus von 40 Punkten, den die echte
    /// Bearbeitung verdient. Wer seine Originale so benennt, verlöre damit genau die
    /// bearbeitete Fassung — der Duplikat-Finder legt die Verlierer in den Papierkorb.
    /// Im Englischen dasselbe mit „Cr**edited**", „acc**redited**".
    ///
    /// „Wort" heißt hier: nicht von einem **Buchstaben** umgeben. Unterstrich und
    /// Bindestrich müssen zählen — „IMG_1234_edited.jpg" ist der Normalfall, und
    /// `\b` würde dort nicht greifen, weil `_` in Regex als Wortzeichen gilt.
    ///
    /// Dieselbe Überlegung steht schon bei `WebOriginDetector.filenamePatterns`: Dort
    /// wurden unverankerte Teilzeichenketten wie „download" verworfen, weil sie echte
    /// Fotos trafen. Hier war sie noch nicht angewandt.
    static func isEditedVersion(_ fileName: String) -> Bool {
        let lowered = fileName.lowercased()
        let bereich = NSRange(lowered.startIndex..<lowered.endIndex, in: lowered)
        return editedWordPatterns.contains {
            $0.firstMatch(in: lowered, range: bereich) != nil
        }
    }

    /// Vorkompiliert: `keeperScore` ruft `isEditedVersion` je Zeile einer Gruppe auf.
    private static let editedWordPatterns: [NSRegularExpression] =
        ["edited", "bearbeitet"].map { wort in
            // Force-try: Compile-Zeit-Konstanten aus dieser Datei.
            try! NSRegularExpression(pattern: "(?<!\\p{L})\(wort)(?!\\p{L})")
        }

    /// Apples `<UUID>_L0_001-FullSizeRender.mov` — das gerenderte Ergebnis einer
    /// Bearbeitung in Apple Fotos.
    ///
    /// Es ist eine Bearbeitung, aber eine **flachgerechnete**: Bei HDR-Videos
    /// liegt hier die SDR-Fassung, während die HDR-Fassung daneben steht. Die
    /// Dateigröße hilft nicht weiter — sie ist sogar irreführend, weil der
    /// SDR-Re-Encode mit hoher Bitrate *größer* ausfällt als das besser
    /// komprimierende HEVC-10-bit-Original.
    ///
    /// Deshalb ein **kleinerer Bonus statt eines Malus**. Ein Malus verkehrte den
    /// zweiten Fall ins Gegenteil: Steht der Render neben dem *unbearbeiteten*
    /// Original, ist er die einzige Fassung, die die Bearbeitung überhaupt
    /// enthält, und muss gewinnen. Mit 20 gegen 40 gewinnt er gegen das nackte
    /// Original und verliert gegen eine benannte Bearbeitungsfassung — beides
    /// richtig, ohne dass die Formel die Gruppe kennen müsste.
    static func isFlattenedRender(_ fileName: String) -> Bool {
        fileName.lowercased().contains("fullsizerender")
    }

    /// Bis zu drei Klartext-Gründe, warum dieses Exemplar bleibt.
    ///
    /// Bewusst aus dem Vergleich mit den anderen abgeleitet und nicht aus den
    /// Punkten: „höchste Auflösung" ist nachprüfbar, „87 Punkte" ist es nicht.
    static func keeperReasons(keeper: DupeScanRow, others: [DupeScanRow]) -> [String] {
        guard !others.isEmpty else { return [] }
        var out: [String] = []

        if keeper.isFavorite, !others.contains(where: \.isFavorite) {
            out.append("als Favorit markiert")
        }
        if leadsBundle(keeper, in: [keeper] + others) {
            out.append("Hauptfassung der Kamera-Aufnahme")
        }
        if isEditedVersion(keeper.fileName), !others.contains(where: { isEditedVersion($0.fileName) }) {
            out.append("bearbeitete Fassung")
        }
        if let mp = keeper.megapixels {
            let best = others.compactMap(\.megapixels).max() ?? 0
            if mp > best * 1.05 {
                out.append(String(format: "höchste Auflösung (%.1f MP)", mp))
            }
        }
        if keeper.hasCoordinates, !others.contains(where: \.hasCoordinates) {
            out.append("einziges mit Koordinaten")
        }
        if let size = keeper.fileSize {
            let best = others.compactMap(\.fileSize).max() ?? 0
            if Double(size) > Double(best) * 1.05 {
                out.append(String(format: "größte Datei (%.1f MB)", Double(size) / 1_000_000))
            }
        }
        if keeper.exifCompleteness > (others.map(\.exifCompleteness).max() ?? 0) {
            out.append("vollständigste Aufnahmedaten")
        }

        if out.isEmpty { return ["bester Gesamtwert"] }
        return Array(out.prefix(3))
    }
}
