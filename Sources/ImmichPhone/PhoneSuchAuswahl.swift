import Foundation

/// Was der Reiter „Entdecken“ gerade zeigt: höchstens ein Land, darin höchstens eine
/// Stadt **oder** Region, höchstens ein Jahr **oder** Zeitraum, beliebig viele Personen,
/// dazu Medientyp, Favoriten und ein Freitext für die Bildsuche. **Alles ist optional** —
/// bis September 2026 war das Land Pflicht, und „nur Anna“ ließ sich nicht suchen.
///
/// Reiner Wertetyp — kein SwiftUI, kein Netz. Hier entsteht der `SearchFilter`
/// für Raster, Zählabfragen und Personendurchlauf; alles, was daran lautlos falsch
/// sein kann, ist in `PhoneSuchAuswahlTests` festgenagelt.
///
/// **Die Gleichheit ist die Bedingung für den Cursor-Reset.** Der Such-Cursor ist
/// ein verpackter Offset; `PhonePhotoFeed.setzeAuswahl` lädt nur bei `!=` von vorne.
/// Deshalb liegen die Personen **sortiert** vor: „Anna, Ben" und „Ben, Anna" sind
/// dieselbe Auswahl und dürfen kein Neuladen auslösen.
struct PhoneSuchAuswahl: Hashable, Sendable, Codable {
    private(set) var land: String?
    private(set) var stadt: String?
    private(set) var region: String?
    private(set) var jahr: Int?
    /// Personen-IDs, sortiert. UND-verknüpft (`personIds.all`): „Anna und Ben"
    /// heißt die Fotos, auf denen beide zu sehen sind.
    private(set) var personen: [String] = []

    /// Zeitraum aus der Textsuche („letzten Sommer“). Offene Seiten sind `nil`.
    struct Zeitraum: Hashable, Sendable, Codable {
        let von: Date?
        let bis: Date?
        let label: String
    }
    private(set) var zeitraum: Zeitraum?
    private(set) var typ: AssetType?
    private(set) var nurFavoriten = false
    /// Rest der Textsuche für die Bildsuche (CLIP). Getrimmt; leer = keine Bildsuche.
    private(set) var freitext = ""

    init() {}

    static let leer = PhoneSuchAuswahl()

    /// Nichts gewählt — dann zeigt der Reiter seine Startseite.
    var istLeer: Bool { self == .leer }

    /// Nur ein Land, sonst nichts — der einzige Fall, in dem gezählte Städte in den
    /// Katalog zurückgeschrieben werden dürfen.
    var istNurLand: Bool {
        land != nil && stadt == nil && region == nil && jahr == nil && personen.isEmpty
            && zeitraum == nil && typ == nil && !nurFavoriten && freitext.isEmpty
    }

    static func land(_ name: String) -> PhoneSuchAuswahl {
        var auswahl = PhoneSuchAuswahl()
        auswahl.land = name
        return auswahl
    }

    static func person(_ id: String) -> PhoneSuchAuswahl { PhoneSuchAuswahl.leer.mitPerson(id) }

    static func jahr(_ jahr: Int) -> PhoneSuchAuswahl { PhoneSuchAuswahl.leer.mitJahr(jahr) }

    /// Land setzen, ohne den Rest anzufassen (Textsuche).
    func mitLand(_ name: String) -> PhoneSuchAuswahl { var a = self; a.land = name; return a }

    /// Land samt Stadt und Region entfernen — Personen, Jahr und Rest bleiben.
    func ohneLand() -> PhoneSuchAuswahl {
        var a = self
        a.land = nil; a.stadt = nil; a.region = nil
        return a
    }

    /// Ein Zeitraum verdrängt das Jahr — beides zugleich zeigte einen Chip, den der
    /// Filter ignoriert (``searchFilter(type:)`` nimmt das Jahr).
    func mitZeitraum(_ neu: Zeitraum?) -> PhoneSuchAuswahl {
        var a = self
        a.zeitraum = neu
        if neu != nil { a.jahr = nil }
        return a
    }
    func mitTyp(_ neu: AssetType?) -> PhoneSuchAuswahl { var a = self; a.typ = neu; return a }
    func mitFavoriten(_ neu: Bool) -> PhoneSuchAuswahl { var a = self; a.nurFavoriten = neu; return a }
    func mitFreitext(_ text: String) -> PhoneSuchAuswahl {
        var a = self
        a.freitext = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return a
    }

    static func stadt(_ stadt: String, in land: String) -> PhoneSuchAuswahl {
        var auswahl = PhoneSuchAuswahl.land(land)
        auswahl.stadt = stadt
        return auswahl
    }

    static func region(_ region: String, in land: String) -> PhoneSuchAuswahl {
        var auswahl = PhoneSuchAuswahl.land(land)
        auswahl.region = region
        return auswahl
    }

    /// Tippen auf einen Stadt-Chip. Dieselbe Stadt noch einmal hebt sie auf. Eine
    /// Region weicht: Stadt und Region zugleich wären eine Schnittmenge, die die
    /// Filterleiste nicht darstellt.
    func mitStadt(_ name: String) -> PhoneSuchAuswahl {
        var auswahl = self
        auswahl.stadt = (stadt == name) ? nil : name
        auswahl.region = nil
        return auswahl
    }

    func mitJahr(_ neu: Int) -> PhoneSuchAuswahl {
        var auswahl = self
        auswahl.jahr = (jahr == neu) ? nil : neu
        // Ein Jahr verdrängt den Zeitraum (siehe ``mitZeitraum(_:)``).
        if auswahl.jahr != nil { auswahl.zeitraum = nil }
        return auswahl
    }

    func mitPerson(_ id: String) -> PhoneSuchAuswahl {
        var auswahl = self
        if let index = auswahl.personen.firstIndex(of: id) {
            auswahl.personen.remove(at: index)
        } else {
            auswahl.personen.append(id)
            auswahl.personen.sort()
        }
        return auswahl
    }

    func ohneStadt() -> PhoneSuchAuswahl {
        var auswahl = self
        auswahl.stadt = nil
        return auswahl
    }

    func ohneStadtUndRegion() -> PhoneSuchAuswahl {
        var auswahl = self
        auswahl.stadt = nil
        auswahl.region = nil
        return auswahl
    }

    func ohneJahr() -> PhoneSuchAuswahl {
        var auswahl = self
        auswahl.jahr = nil
        return auswahl
    }

    /// Der Filter für Raster und Zählabfragen. Baut auf
    /// ``SearchFilter/visibleLibrary(type:)`` auf — damit sind `visibility` (nur als
    /// Positivliste, sonst 401) und `trashedAt: isNull` (sonst ist der Papierkorb
    /// dabei) **immer** gesetzt.
    ///
    /// Jede echte Auswahl sucht zusätzlich in den Alben, die andere mit diesem Konto
    /// teilen (``SearchFilter/mitGeteiltenAlben(_:)``). Zwei Ausnahmen:
    /// - ``leer`` ist der Fotos-Reiter — die eigene Zeitleiste, wie in Immich.
    /// - „Nur Favoriten": Der Favoritenstern eines Fotos gehört seinem Eigentümer.
    ///   In einem geteilten Album hieße der Filter „was der andere mag".
    func searchFilter(type: AssetType? = nil, geteilteAlben: [String] = PhoneGeteilteAlben.aktuell) -> SearchFilter {
        let filter = eigenerFilter(type: type)
        guard self != .leer, !nurFavoriten else { return filter }
        return filter.mitGeteiltenAlben(geteilteAlben)
    }

    private func eigenerFilter(type: AssetType?) -> SearchFilter {
        var filter = SearchFilter.visibleLibrary(type: typ ?? type)
        if let land { filter.country = .equals(land) }
        if let stadt { filter.city = .equals(stadt) }
        if let region { filter.state = .equals(region) }
        if let jahr, let fenster = Self.jahresFenster(jahr) {
            filter.takenAt = .between(fenster.von, and: fenster.bis)
        } else if let zeitraum,
                  let bedingung = SearchCondition<String>.dateRange(
                      from: zeitraum.von ?? .distantPast, to: zeitraum.bis ?? .distantFuture) {
            // Nie `.between` direkt: offene Seiten stünden sonst als Jahr 4001 am Server.
            filter.takenAt = bedingung
        }
        if !personen.isEmpty { filter.personIds = .allOf(personen) }
        if nurFavoriten { filter.isFavorite = .equals(true) }
        return filter
    }

    /// `[1. Januar, 1. Januar des Folgejahres)` in **UTC** — `takenAt` vergleicht
    /// `fileCreatedAt` in UTC, nicht die Ortszeit des Fotos.
    static func jahresFenster(_ jahr: Int) -> (von: Date, bis: Date)? {
        var kalender = Calendar(identifier: .gregorian)
        kalender.timeZone = TimeZone(identifier: "UTC")!
        guard let von = kalender.date(from: DateComponents(year: jahr, month: 1, day: 1)),
              let bis = kalender.date(from: DateComponents(year: jahr + 1, month: 1, day: 1))
        else { return nil }
        return (von, bis)
    }
}
