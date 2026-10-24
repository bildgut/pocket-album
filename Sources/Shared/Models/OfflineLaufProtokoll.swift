import Foundation

/// Ein Offline-Lauf in Zahlen — für die Diagnose, wenn das Laden stockt.
///
/// Beantwortet vier Fragen, die aus dem Fortschrittsbalken nicht abzulesen sind:
/// **Wo** geht die Zeit hin (Auflösung der Quellen gegen Laden, Verbindungsaufbau
/// gegen Übertragung), **warum** startet und endet ein Lauf, **was** schlägt fehl
/// und **in welcher Lage** (Netz, Gerät) lief er.
///
/// Alles Neue ist optional: Ältere Einträge im Speicher müssen weiter lesbar bleiben.
struct OfflineLaufEintrag: Codable, Equatable, Sendable {
    enum Ende: String, Codable, Sendable {
        /// Alles geladen, was fehlte.
        case fertig
        /// Nach der Auflösung gab es nichts zu laden.
        case nichtsZuTun
        /// Ein Album/Quelle hielt an, weil das Netz als teuer oder eingeschränkt galt.
        case netzTeuer
        /// Abbruch von außen (Abmelden, Ablauf der Hintergrundzeit, Freigeben).
        case abgebrochen
        /// Gar nicht erst begonnen: getaktetes Netz.
        case uebersprungenNetz
        /// Es gab keinen Vermerk.
        case keinVermerk
    }

    /// Zusammenfassung der Dateien eines Laufs.
    struct Messung: Codable, Equatable, Sendable {
        var dateienOk = 0
        var bytes: Int64 = 0
        var durchsatzKBs: Double?
        var gesamtMedian: Double?
        var gesamtP90: Double?
        var gesamtMax: Double?
        var ueber30s = 0
        var ttfbMedian: Double?
        var ttfbP90: Double?
        var verbindungMedian: Double?
        var neueVerbindungen = 0
        var wiederverwendet = 0
        var protokolle: [String: Int] = [:]
        var wiederholte = 0
        var zeitueberschreitungen = 0
        var fehlerArten: [String: Int] = [:]
        /// Wie viele Dateien in der 1., 2., 3. … Minute des Ladens fertig wurden.
        var proMinute: [Int] = []
        var teuerDateien = 0
        var mobilfunkDateien = 0
    }

    var start: Date
    var ende: Ende = .fertig
    /// Dauer der Mitgliedschafts-Auflösung (alle Quellen), Sekunden.
    var aufloesungSek: Double?
    /// Dauer des Ladens, Sekunden.
    var ladeSek: Double?
    var geplant = 0
    var geladen = 0
    var fehler = 0
    /// Galt das Netz beim Start als teuer/eingeschränkt?
    var netzTeuerBeiStart = false
    var erzwungen = false
    /// Der erste Fehlertext des Laufs (gekürzt) — meist reicht einer.
    var ersterFehler: String?

    // Seit Build 16
    var ausloeser: String?
    var abbruchGrund: String?
    var netzStart: String?
    var netzEnde: String?
    var netzWechsel: Int?
    var geraet: String?
    /// „Favoriten: 1200 Dateien (Auflösung 4 s)“
    var quellen: [String]?
    var fassungen: String?
    var messung: Messung?

    /// Die Kopfzeile, in der sich Läufe vergleichen lassen.
    func zeile(sprache: Locale = .current) -> String {
        let f = DateFormatter()
        f.locale = sprache
        f.setLocalizedDateFormatFromTemplate("MMMdHms")
        var teile = [f.string(from: start), Self.endeText(ende)]
        if let aufloesungSek { teile.append("Auflösung \(Self.sek(aufloesungSek))") }
        if geplant > 0 || geladen > 0 || fehler > 0 {
            var laden = "\(geladen)/\(geplant) geladen"
            if let ladeSek { laden += " in \(Self.sek(ladeSek))" }
            if fehler > 0 { laden += ", \(fehler) fehlgeschlagen" }
            teile.append(laden)
        }
        if netzTeuerBeiStart { teile.append("Netz: teuer/eingeschränkt") }
        if erzwungen { teile.append("erzwungen") }
        if let ersterFehler { teile.append("Fehler: \(ersterFehler)") }
        return teile.joined(separator: " · ")
    }

    /// Weitere Zeilen, nur was bekannt ist.
    func details() -> [String] {
        var z: [String] = []
        var anlass: [String] = []
        if let ausloeser { anlass.append("Auslöser: \(ausloeser)") }
        if let abbruchGrund { anlass.append("Abbruch: \(abbruchGrund)") }
        if !anlass.isEmpty { z.append(anlass.joined(separator: " · ")) }

        if netzStart != nil || netzEnde != nil {
            var n = "Netz: \(netzStart ?? "?") → \(netzEnde ?? "?")"
            if let netzWechsel { n += " · \(netzWechsel) Wechsel im Lauf" }
            z.append(n)
        }
        if let geraet { z.append("Gerät: \(geraet)") }
        if let fassungen { z.append("Fassungen: \(fassungen)") }
        if let quellen, !quellen.isEmpty { z.append("Quellen: " + quellen.joined(separator: "; ")) }

        if let m = messung {
            var datei: [String] = []
            if let med = m.gesamtMedian { datei.append("Median \(Self.sek(med))") }
            if let p90 = m.gesamtP90 { datei.append("P90 \(Self.sek(p90))") }
            if let max = m.gesamtMax { datei.append("längste \(Self.sek(max))") }
            if m.ueber30s > 0 { datei.append("\(m.ueber30s) über 30 s") }
            if !datei.isEmpty { z.append("Je Datei: " + datei.joined(separator: ", ")) }

            var kopf: [String] = []
            if let t = m.ttfbMedian { kopf.append("erstes Byte Median \(Self.sek(t))") }
            if let t = m.ttfbP90 { kopf.append("P90 \(Self.sek(t))") }
            if let v = m.verbindungMedian { kopf.append("Verbindungsaufbau Median \(Self.sek(v))") }
            if m.neueVerbindungen + m.wiederverwendet > 0 {
                kopf.append("\(m.neueVerbindungen) neue / \(m.wiederverwendet) wiederverwendete Verbindungen")
            }
            if !m.protokolle.isEmpty { kopf.append(Self.zaehlung(m.protokolle)) }
            if !kopf.isEmpty { z.append("Anfang: " + kopf.joined(separator: ", ")) }

            if m.bytes > 0 {
                var d = "Daten: " + ByteCountFormatter.string(fromByteCount: m.bytes, countStyle: .file)
                if let kbs = m.durchsatzKBs { d += String(format: " · %.0f KB/s im Schnitt", kbs) }
                z.append(d)
            }
            if !m.proMinute.isEmpty {
                z.append("Fertig je Minute: " + m.proMinute.map(String.init).joined(separator: ", "))
            }
            var probleme: [String] = []
            if m.wiederholte > 0 { probleme.append("\(m.wiederholte) Dateien mehrfach versucht") }
            if m.zeitueberschreitungen > 0 { probleme.append("\(m.zeitueberschreitungen) Zeitüberschreitungen") }
            if m.teuerDateien > 0 { probleme.append("\(m.teuerDateien) über teures Netz") }
            if m.mobilfunkDateien > 0 { probleme.append("\(m.mobilfunkDateien) über Mobilfunk") }
            if !m.fehlerArten.isEmpty { probleme.append("Fehler: " + Self.zaehlung(m.fehlerArten)) }
            if !probleme.isEmpty { z.append(probleme.joined(separator: " · ")) }
        }
        return z
    }

    /// `h2 ×30, http/1.1 ×2`, größte Zahl zuerst.
    static func zaehlung(_ werte: [String: Int]) -> String {
        werte.sorted { ($1.value, $0.key) < ($0.value, $1.key) }
            .map { "\($0.key) ×\($0.value)" }
            .joined(separator: ", ")
    }

    /// Kopfzeile plus Einzelheiten, für Anzeige und Export.
    func text(sprache: Locale = .current) -> String {
        ([zeile(sprache: sprache)] + details().map { "   " + $0 }).joined(separator: "\n")
    }

    static func endeText(_ ende: Ende) -> String {
        switch ende {
        case .fertig: "fertig"
        case .nichtsZuTun: "nichts zu laden"
        case .netzTeuer: "angehalten (Netz teuer)"
        case .abgebrochen: "abgebrochen"
        case .uebersprungenNetz: "übersprungen (Netz)"
        case .keinVermerk: "kein Vermerk"
        }
    }

    /// Sekunden kurz: `4 s`, `2 min 5 s`; unter 10 s mit einer Nachkommastelle.
    static func sek(_ wert: Double) -> String {
        guard wert.isFinite, wert >= 0 else { return "?" }
        if wert < 10 { return String(format: "%.1f s", wert) }
        let s = Int(wert.rounded())
        return s < 60 ? "\(s) s" : "\(s / 60) min \(s % 60) s"
    }
}

/// Die letzten Läufe, neueste zuletzt. Bewusst klein gehalten.
struct OfflineLaufProtokoll: @unchecked Sendable {
    static let schluessel = "offline.laufprotokoll.v1"
    static let hoechstens = 30

    let defaults: UserDefaults

    init(defaults: UserDefaults = AppEnvironment.defaults) {
        self.defaults = defaults
    }

    var eintraege: [OfflineLaufEintrag] {
        defaults.data(forKey: Self.schluessel)
            .flatMap { try? JSONDecoder().decode([OfflineLaufEintrag].self, from: $0) } ?? []
    }

    func haengeAn(_ eintrag: OfflineLaufEintrag) {
        var alle = eintraege
        alle.append(eintrag)
        if alle.count > Self.hoechstens { alle.removeFirst(alle.count - Self.hoechstens) }
        defaults.set(try? JSONEncoder().encode(alle), forKey: Self.schluessel)
    }

    func leere() {
        defaults.removeObject(forKey: Self.schluessel)
    }

    /// Zum Kopieren und Weitergeben: neueste zuerst, mit Kopf zur App.
    func text(sprache: Locale = .current, kopf: String? = nil) -> String {
        let laeufe = eintraege.reversed().map { $0.text(sprache: sprache) }.joined(separator: "\n\n")
        return [kopf, laeufe].compactMap { $0 }.joined(separator: "\n\n")
    }
}
