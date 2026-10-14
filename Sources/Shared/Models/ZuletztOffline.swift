import Foundation

/// „Letzte Tage offline“: Die Fotos der letzten N Tage aus der eigenen Bibliothek
/// liegen immer auf dem Gerät (Spec `docs/superpowers/specs/2026-10-14-ios-letzte-tage-offline-design.md`).
///
/// Ein einziger ``OfflinePin`` der Art ``OfflinePinKind/zuletzt`` trägt die
/// Mitgliedschaft; die Tageszahl liegt **nicht** am Vermerk, sondern in
/// `UserDefaults` — so braucht es keine Schemaänderung, und der Vermerk wird beim
/// Ändern der Stufe nicht neu angelegt (die geladenen Dateien bleiben stehen).
///
/// Das Fenster zählt nach **Aufnahmedatum** (`takenAt`): Ein Nachimport alter
/// Fotos ist nicht „neu“. Geteilte Alben bleiben bewusst draußen.
enum ZuletztOffline {
    /// Die wählbaren Stufen; 0 = aus.
    static let stufen = [0, 3, 7, 14, 30]
    static let schluessel = "offline.zuletzt.tage"
    static let targetId = "eigene"
    static var pinId: String { OfflinePin.pinId(kind: .zuletzt, targetId: targetId) }

    /// Vorgabe für die Qualität: 30 Tage mit Videos wären schnell mehrere GB.
    static let vorgabeWahl = OfflineWahl(fotos: .vorschau, videos: .keine, mobilfunk: false)

    /// Gemerkte Stufe; ein Wert, der keine Stufe ist, gilt als aus.
    static func tage(defaults: UserDefaults = AppEnvironment.defaults) -> Int {
        let wert = defaults.integer(forKey: schluessel)
        return stufen.contains(wert) ? wert : 0
    }

    static func setzeTage(_ tage: Int, defaults: UserDefaults = AppEnvironment.defaults) {
        defaults.set(stufen.contains(tage) ? tage : 0, forKey: schluessel)
    }

    /// Beginn des Fensters: Mitternacht in der Gerätezeitzone, `tage − 1` Tage vor
    /// heute. „3 Tage“ heißt also heute und die zwei Tage davor. Über `Calendar`
    /// statt `− tage × 86 400 s`, sonst verrutschte die Grenze an Sommerzeittagen
    /// um eine Stunde.
    static func beginn(tage: Int, jetzt: Date = .now, kalender: Calendar = .current) -> Date? {
        guard tage > 0 else { return nil }
        let heute = kalender.startOfDay(for: jetzt)
        return kalender.date(byAdding: .day, value: -(tage - 1), to: heute)
    }

    /// Der Suchfilter: eigene Bibliothek (ohne Archiv, Papierkorb, Live-Photo-
    /// Bewegtanteile) ab ``beginn(tage:jetzt:kalender:)``. Ohne `albumIds` sucht der
    /// Server nur in Assets des Kontos — genau das ist gewollt.
    static func filter(tage: Int, jetzt: Date = .now, kalender: Calendar = .current) -> SearchFilter? {
        guard let beginn = beginn(tage: tage, jetzt: jetzt, kalender: kalender) else { return nil }
        var filter = SearchFilter.visibleLibrary(type: nil)
        filter.takenAt = .onOrAfter(beginn)
        return filter
    }

    /// Obergrenze der Seiten je Auflösung (je 1000) — eine Schutzschranke gegen
    /// einen Server, der nie aufhört zu blättern, kein erwarteter Fall.
    static let maxSeiten = 50
}
