import Foundation

/// Findet deutsche Zeitangaben in einer Wortliste — „letzten Sommer", „seit 2020",
/// „im Januar 2024", „vor zwei Jahren" — und macht daraus Such-Chips.
///
/// Bewusst regelbasiert statt über ein Sprachmodell: Apples lokales Modell lieferte
/// den wörtlichen Zeitausdruck zuverlässig, **rechnete** aber falsch („letzten Sommer"
/// → 2025-06-01…2026-09-22) und blockierte harmlose Familiensätze per Sicherheitsfilter
/// (Proben vom 15.09.2026, Spec `2026-09-15-natuerliche-suche-design.md`).
///
/// Festlegungen, die man beim Lesen der Ergebnisse kennen muss:
/// - **Ortszeit.** Tagesgrenzen über `SmartAlbumEvaluator.dayRange`, nicht UTC.
/// - **Ohne Jahr** („im August", „letzten Sommer") gilt das jüngste Vorkommen, das
///   **vor `now` endet**; „diesen Sommer" das des laufenden Jahres.
/// - **Jahreszeiten meteorologisch**; der Winter trägt das Jahr seines Dezembers.
/// - **Die Jahreszahl steht im Chip**, damit eine andere Lesart sofort auffällt.
/// - „vor zwei Jahren" ist das Kalenderjahr, „bis 2018" schließt 2018 ein, „vor 2018" nicht.
///
/// Rein rechnend; `now` und `calendar` kommen von außen, damit Tests stabil sind.
enum Zeitausdruck {

    struct Treffer: Equatable {
        /// Indizes in der Wortliste, einschließlich führender Präpositionen.
        let woerter: Range<Int>
        let token: SearchToken
    }

    static func finde(in woerter: [String], now: Date, calendar: Calendar) -> [Treffer] {
        let w = woerter.map(normalisiert)
        let kontext = Kontext(now: now, cal: calendar)
        var treffer: [Treffer] = []
        var i = 0
        while i < w.count {
            if let (ende, token) = ausdruck(ab: i, in: w, kontext) {
                treffer.append(Treffer(woerter: i..<ende, token: token))
                i = ende
            } else {
                i += 1
            }
        }
        return treffer
    }

    // MARK: Wortlisten

    private static let praepositionen: Set<String> = ["im", "in", "am", "an", "um", "vom", "zu", "zum", "den", "dem"]
    /// Volle Monatsnamen gelten als Monat auch ohne Jahr dahinter.
    private static let monatsVollnamen: [String: Int] = [
        "januar": 1, "janner": 1, "februar": 2, "marz": 3, "april": 4, "mai": 5, "juni": 6,
        "juli": 7, "august": 8, "september": 9, "oktober": 10, "november": 11, "dezember": 12,
    ]
    /// Kurzformen sind nur mit folgender Jahreszahl eindeutig ein Monat — ohne Jahr
    /// verschluckt „Jan" sonst jeden Vornamen Jan.
    private static let monatsKurzformen: [String: Int] = [
        "jan": 1, "feb": 2, "mar": 3, "apr": 4, "jun": 6, "jul": 7,
        "aug": 8, "sep": 9, "sept": 9, "okt": 10, "nov": 11, "dez": 12,
    ]
    private static let monate: [String: Int] = monatsVollnamen.merging(monatsKurzformen) { voll, _ in voll }
    /// Höchstens ein Artikelwort zwischen Richtungswort und Kern — „seit dem Sommer
    /// 2023" bleibt offen, statt dass „dem" den geschlossenen Kern einleitet.
    private static let richtungsArtikel: Set<String> = ["dem", "den", "der", "zum", "zur", "im"]
    private static let monatsnamen = ["Januar", "Februar", "März", "April", "Mai", "Juni", "Juli",
                                      "August", "September", "Oktober", "November", "Dezember"]
    private static let zahlwoerter: [String: Int] = [
        "ein": 1, "einem": 1, "einer": 1, "zwei": 2, "drei": 3, "vier": 4, "funf": 5, "sechs": 6,
        "sieben": 7, "acht": 8, "neun": 9, "zehn": 10, "elf": 11, "zwolf": 12,
    ]
    private static let diese: Set<String> = ["dieses", "diesem", "diesen", "dieser", "diese"]
    private static let letzte: Set<String> = ["letztes", "letzten", "letzter", "letzte", "letztem",
                                              "voriges", "vorigen", "voriger", "vorige", "vorigem",
                                              "vergangenes", "vergangenen", "vergangener", "vergangene"]
    private static let vorletzte: Set<String> = ["vorletztes", "vorletzten", "vorletzter", "vorletzte", "vorletztem"]

    private enum Wiederkehrend {
        case monat(Int), jahreszeit(Jahreszeit), fest(Fest)
    }
    private enum Jahreszeit: String { case fruehling = "Frühling", sommer = "Sommer", herbst = "Herbst", winter = "Winter" }
    private enum Fest: String { case weihnachten = "Weihnachten", silvester = "Silvester", ostern = "Ostern" }

    private static func wiederkehrend(_ wort: String) -> Wiederkehrend? {
        if let m = monate[wort] { return .monat(m) }
        switch wort {
        case "fruhling", "fruhjahr": return .jahreszeit(.fruehling)
        case "sommer": return .jahreszeit(.sommer)
        case "herbst": return .jahreszeit(.herbst)
        case "winter": return .jahreszeit(.winter)
        case "weihnachten": return .fest(.weihnachten)
        case "silvester": return .fest(.silvester)
        case "ostern": return .fest(.ostern)
        default: return nil
        }
    }

    // MARK: Zeitraum

    private struct Kontext {
        let now: Date
        let cal: Calendar
        var jahr: Int { cal.component(.year, from: now) }
    }

    /// Ein aufgelöster Kern, bevor Richtung und Präpositionen dazukommen.
    private struct Spanne {
        var from: Date
        /// `distantFuture` markiert intern ein offenes Ende („letzte 30 Tage").
        var to: Date
        var label: String
        /// Gesetzt, wenn die Spanne genau ein Kalenderjahr ist und als `.year` erscheinen soll.
        var jahr: Int? = nil
        /// Gesetzt, wenn die Spanne genau ein Tag ist und als `.date` erscheinen soll.
        var tag: Date? = nil

        var token: SearchToken {
            if let jahr { return .year(jahr) }
            if let tag { return .date(tag) }
            return .dateRange(from: from, to: to == .distantFuture ? nil : to, label: label)
        }
    }

    private static func tage(_ k: Kontext, _ y1: Int, _ m1: Int, _ d1: Int, _ y2: Int, _ m2: Int, _ d2: Int) -> (Date, Date)? {
        guard let a = gueltig(k, y1, m1, d1), let b = gueltig(k, y2, m2, d2) else { return nil }
        return (k.cal.startOfDay(for: a), SmartAlbumEvaluator.dayRange(for: b, calendar: k.cal).to)
    }

    /// Ein Datum nur, wenn der Kalender es nicht verschiebt („30. Februar" → nil).
    private static func gueltig(_ k: Kontext, _ y: Int, _ m: Int, _ d: Int) -> Date? {
        guard let date = k.cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12)) else { return nil }
        let c = k.cal.dateComponents([.year, .month, .day], from: date)
        return (c.year == y && c.month == m && c.day == d) ? date : nil
    }

    private static func tageImMonat(_ k: Kontext, _ y: Int, _ m: Int) -> Int {
        guard let d = gueltig(k, y, m, 1) else { return 28 }
        return k.cal.range(of: .day, in: .month, for: d)?.count ?? 28
    }

    private static func jahresSpanne(_ k: Kontext, _ y: Int) -> Spanne? {
        guard let (a, b) = tage(k, y, 1, 1, y, 12, 31) else { return nil }
        return Spanne(from: a, to: b, label: "\(y)", jahr: y)
    }

    private static func monatsSpanne(_ k: Kontext, _ y: Int, _ m: Int) -> Spanne? {
        guard let (a, b) = tage(k, y, m, 1, y, m, tageImMonat(k, y, m)) else { return nil }
        return Spanne(from: a, to: b, label: "\(monatsnamen[m - 1]) \(y)")
    }

    /// Das Vorkommen im Ankerjahr `y`. Der Winter trägt das Jahr seines Dezembers.
    private static func vorkommen(_ was: Wiederkehrend, _ y: Int, _ k: Kontext) -> Spanne? {
        switch was {
        case .monat(let m):
            return monatsSpanne(k, y, m)
        case .jahreszeit(let j):
            let bereich: (Int, Int, Int, Int, Int, Int)
            switch j {
            case .fruehling: bereich = (y, 3, 1, y, 5, 31)
            case .sommer:    bereich = (y, 6, 1, y, 8, 31)
            case .herbst:    bereich = (y, 9, 1, y, 11, 30)
            case .winter:    bereich = (y, 12, 1, y + 1, 2, tageImMonat(k, y + 1, 2))
            }
            guard let (a, b) = tage(k, bereich.0, bereich.1, bereich.2, bereich.3, bereich.4, bereich.5) else { return nil }
            let label = j == .winter
                ? "Winter \(y)/\(String(format: "%02d", (y + 1) % 100))"
                : "\(j.rawValue) \(y)"
            return Spanne(from: a, to: b, label: label)
        case .fest(let f):
            let bereich: (Date, Date)?
            switch f {
            case .weihnachten: bereich = tage(k, y, 12, 24, y, 12, 26)
            case .silvester:   bereich = tage(k, y, 12, 31, y + 1, 1, 1)
            case .ostern:
                let (m, d) = ostersonntag(y)
                guard let sonntag = gueltig(k, y, m, d),
                      let freitag = k.cal.date(byAdding: .day, value: -2, to: sonntag),
                      let montag = k.cal.date(byAdding: .day, value: 1, to: sonntag)
                else { return nil }
                bereich = (k.cal.startOfDay(for: freitag), SmartAlbumEvaluator.dayRange(for: montag, calendar: k.cal).to)
            }
            guard let (a, b) = bereich else { return nil }
            return Spanne(from: a, to: b, label: "\(f.rawValue) \(y)")
        }
    }

    /// Gregorianischer Ostersonntag (Algorithmus nach Gauß/Meeus).
    private static func ostersonntag(_ y: Int) -> (monat: Int, tag: Int) {
        let a = y % 19, b = y / 100, c = y % 100
        let d = b / 4, e = b % 4, f = (b + 8) / 25, g = (b - f + 1) / 3
        let h = (19 * a + b - d - g + 15) % 30
        let i = c / 4, kk = c % 4
        let l = (32 + 2 * e + 2 * i - h - kk) % 7
        let m = (a + 11 * h + 22 * l) / 451
        let monat = (h + l - 7 * m + 114) / 31
        let tag = (h + l - 7 * m + 114) % 31 + 1
        return (monat, tag)
    }

    /// Das `nummer`-te Vorkommen, das vor `now` **endet** (1 = jüngstes).
    private static func vergangenes(_ was: Wiederkehrend, nummer: Int, _ k: Kontext) -> Spanne? {
        var gefunden = 0
        for y in stride(from: k.jahr + 1, through: k.jahr - 3, by: -1) {
            guard let s = vorkommen(was, y, k), s.to < k.now else { continue }
            gefunden += 1
            if gefunden == nummer { return s }
        }
        return nil
    }

    // MARK: Grammatik

    private static func jahreszahl(_ wort: String) -> Int? {
        guard wort.count == 4, let y = Int(wort), (1900...2100).contains(y) else { return nil }
        return y
    }

    private static func anzahl(_ wort: String) -> Int? {
        if let n = Int(wort), (1...999).contains(n) { return n }
        return zahlwoerter[wort]
    }

    /// Ganzer Ausdruck ab `i`: bis zu zwei führende Präpositionen, dann Richtung/Spanne/Kern.
    private static func ausdruck(ab i: Int, in w: [String], _ k: Kontext) -> (Int, SearchToken)? {
        var start = i
        var versuche = [i]
        while start < w.count, praepositionen.contains(w[start]), versuche.count < 3 {
            start += 1
            versuche.append(start)
        }
        // Längste Form zuerst: mit allen Präpositionen probieren, sonst mit weniger.
        for s in versuche.reversed() {
            if let (ende, token) = richtung(ab: s, in: w, k) { return (ende, token) }
        }
        return nil
    }

    private static func richtung(ab i: Int, in w: [String], _ k: Kontext) -> (Int, SearchToken)? {
        guard i < w.count else { return nil }
        let wort = w[i]

        // von X bis Y / zwischen X und Y — ein offenes Ende taugt nicht als Ziel
        // („letzte 30 Tage" darf hier nicht zum geschlossenen Kern werden).
        if wort == "von" || wort == "zwischen",
           let (e1, a) = kern(ab: i + 1, in: w, k), e1 < w.count,
           w[e1] == (wort == "von" ? "bis" : "und"),
           let (e2, b) = kern(ab: e1 + 1, in: w, k), b.to != .distantFuture, a.from <= b.to {
            return (e2, .dateRange(from: a.from, to: b.to, label: "\(a.label)–\(b.label)"))
        }

        if ["seit", "ab", "nach", "bis", "vor"].contains(wort) {
            // „vor zwei Jahren" ist relativ, nicht „vor dem Jahr …".
            if wort == "vor", let treffer = relativVor(ab: i, in: w, k) { return treffer }
            // Höchstens ein Artikelwort zwischen Richtungswort und Kern überspringen —
            // „seit dem Sommer 2023" bleibt offen, „dem" gehört zum verbrauchten Bereich.
            var kernStart = i + 1
            if kernStart < w.count, richtungsArtikel.contains(w[kernStart]) {
                kernStart += 1
            }
            guard let (ende, s) = kern(ab: kernStart, in: w, k) else { return nil }
            switch wort {
            case "seit", "ab":
                return (ende, .dateRange(from: s.from, to: nil, label: "seit \(s.label)"))
            case "nach":
                // Ein offener Kern hat kein „Ende", ab dem „nach" anfangen könnte.
                guard s.to != .distantFuture else { return nil }
                let danach = k.cal.startOfDay(for: s.to.addingTimeInterval(1))
                return (ende, .dateRange(from: danach, to: nil, label: "nach \(s.label)"))
            case "bis":
                // Sonst ginge das interne distantFuture-Ende als „lte 4001" an den Server.
                guard s.to != .distantFuture else { return nil }
                return (ende, .dateRange(from: nil, to: s.to, label: "bis \(s.label)"))
            default: // vor
                return (ende, .dateRange(from: nil, to: s.from.addingTimeInterval(-0.001), label: "vor \(s.label)"))
            }
        }

        if let (ende, s) = kern(ab: i, in: w, k) { return (ende, s.token) }
        return nil
    }

    /// „vor N Jahren/Monaten/Wochen/Tagen" — Kalenderjahr bzw. Monat, Woche, Tag.
    private static func relativVor(ab i: Int, in w: [String], _ k: Kontext) -> (Int, SearchToken)? {
        guard i + 2 < w.count, let n = anzahl(w[i + 1]) else { return nil }
        switch w[i + 2] {
        case "jahr", "jahren":
            return jahresSpanne(k, k.jahr - n).map { (i + 3, $0.token) }
        case "monat", "monaten":
            guard let d = k.cal.date(byAdding: .month, value: -n, to: k.now) else { return nil }
            let c = k.cal.dateComponents([.year, .month], from: d)
            guard let y = c.year, let m = c.month else { return nil }
            return monatsSpanne(k, y, m).map { (i + 3, $0.token) }
        case "woche", "wochen":
            guard let d = k.cal.date(byAdding: .day, value: -7 * n, to: k.now) else { return nil }
            return wochenSpanne(k, d).map { (i + 3, $0.token) }
        case "tag", "tagen":
            guard let d = k.cal.date(byAdding: .day, value: -n, to: k.now) else { return nil }
            return (i + 3, .date(k.cal.startOfDay(for: d)))
        default:
            return nil
        }
    }

    private static func wochenSpanne(_ k: Kontext, _ d: Date) -> Spanne? {
        // Wochenbeginn fest Montag — die App ist fest deutsch; unter dem Kalender des
        // Aufrufers mit US-Region wäre „letzte Woche" sonst Sonntag–Samstag.
        var montagsKalender = k.cal
        montagsKalender.firstWeekday = 2
        guard let woche = montagsKalender.dateInterval(of: .weekOfYear, for: d),
              let sonntag = montagsKalender.date(byAdding: .day, value: 6, to: woche.start) else { return nil }
        let tagMonat = formatter(k, "dd.MM.")
        let voll = formatter(k, "dd.MM.yyyy")
        return Spanne(from: woche.start, to: SmartAlbumEvaluator.dayRange(for: sonntag, calendar: k.cal).to,
                      label: "\(tagMonat.string(from: woche.start))–\(voll.string(from: sonntag))")
    }

    /// Auf `en_US_POSIX` gepinnt wie `SearchToken.dayFormatter` — sonst stünde unter
    /// einem buddhistischen Kalender 2569 im Chip.
    private static func formatter(_ k: Kontext, _ muster: String) -> DateFormatter {
        let f = DateFormatter()
        f.calendar = k.cal
        f.timeZone = k.cal.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = muster
        return f
    }

    /// Der Kern ohne Richtung. Liefert das Ende (exklusiver Index) und die Spanne.
    private static func kern(ab i: Int, in w: [String], _ k: Kontext) -> (Int, Spanne)? {
        guard i < w.count else { return nil }
        let wort = w[i]
        let naechstes = i + 1 < w.count ? w[i + 1] : nil

        // 2018-2020 / 2018–2020 als ein Wort
        let teile = wort.split(whereSeparator: { $0 == "-" || $0 == "–" }).map(String.init)
        if teile.count == 2, let a = jahreszahl(teile[0]), let b = jahreszahl(teile[1]), a <= b,
           let sa = jahresSpanne(k, a), let sb = jahresSpanne(k, b) {
            return (i + 1, Spanne(from: sa.from, to: sb.to, label: "\(a)–\(b)"))
        }

        // 2020
        if let y = jahreszahl(wort), let s = jahresSpanne(k, y) { return (i + 1, s) }

        // Jahr 2020
        if wort == "jahr", let n = naechstes, let y = jahreszahl(n), let s = jahresSpanne(k, y) {
            return (i + 2, s)
        }

        // Januar 2024 / Sommer 2023 / Weihnachten 2019 / August (ohne Jahr)
        if let was = wiederkehrend(wort) {
            if let n = naechstes, let y = jahreszahl(n) {
                return vorkommen(was, y, k).map { (i + 2, $0) }
            }
            // Kurzformen wie „Jan" sind ohne Jahr kein Monat — sonst wäre eine Person
            // „Jan" in Sätzen nie auffindbar.
            if monatsKurzformen[wort] != nil { return nil }
            // „Februar 30": Eine Zahl, die kein Jahr ist, macht den Ausdruck ungültig.
            if let n = naechstes, Int(n) != nil { return nil }
            return vergangenes(was, nummer: 1, k).map { (i + 1, $0) }
        }

        // gestern / heute / vorgestern
        let tagOffset: Int? = ["heute": 0, "gestern": -1, "vorgestern": -2][wort]
        if let off = tagOffset, let d = k.cal.date(byAdding: .day, value: off, to: k.now) {
            let tag = SmartAlbumEvaluator.dayRange(for: d, calendar: k.cal)
            return (i + 1, Spanne(from: tag.from, to: tag.to, label: "", tag: tag.from))
        }

        // letzte 30 Tage / letzten 2 Wochen / letzten 3 Monate (offenes Ende)
        if letzte.contains(wort), let n = naechstes.flatMap(anzahl), i + 2 < w.count {
            let einheit: (Calendar.Component, Int, String)?
            switch w[i + 2] {
            case "tag", "tage", "tagen":       einheit = (.day, n, n == 1 ? "Tag" : "Tage")
            case "woche", "wochen":            einheit = (.day, 7 * n, n == 1 ? "Woche" : "Wochen")
            case "monat", "monate", "monaten": einheit = (.month, n, n == 1 ? "Monat" : "Monate")
            default:                           einheit = nil
            }
            if let (komp, wert, name) = einheit,
               let d = k.cal.date(byAdding: komp, value: -wert, to: k.now) {
                return (i + 3, Spanne(from: k.cal.startOfDay(for: d), to: .distantFuture, label: "letzte \(n) \(name)"))
            }
        }

        // dieses/letztes/vorletztes + Jahr/Monat/Woche/Wiederkehrendes
        let nummer: Int? = diese.contains(wort) ? 0 : letzte.contains(wort) ? 1 : vorletzte.contains(wort) ? 2 : nil
        if let nummer, let n = naechstes {
            switch n {
            case "jahr", "jahres":
                return jahresSpanne(k, k.jahr - nummer).map { (i + 2, $0) }
            case "monat", "monats":
                guard let d = k.cal.date(byAdding: .month, value: -nummer, to: k.now) else { return nil }
                let c = k.cal.dateComponents([.year, .month], from: d)
                guard let y = c.year, let m = c.month else { return nil }
                return monatsSpanne(k, y, m).map { (i + 2, $0) }
            case "woche":
                guard let d = k.cal.date(byAdding: .day, value: -7 * nummer, to: k.now) else { return nil }
                return wochenSpanne(k, d).map { (i + 2, $0) }
            default:
                guard let was = wiederkehrend(n) else { return nil }
                if nummer == 0 { return vorkommen(was, k.jahr, k).map { (i + 2, $0) } }
                return vergangenes(was, nummer: nummer, k).map { (i + 2, $0) }
            }
        }
        return nil
    }

    private static func normalisiert(_ wort: String) -> String {
        var s = wort.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "de_DE"))
        while let last = s.last, ".,;:!?".contains(last) { s.removeLast() }
        return s
    }
}
