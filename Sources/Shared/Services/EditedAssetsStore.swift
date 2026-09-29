import Foundation

/// Welche Assets serverseitig bearbeitet sind (Drehung, Belichtung, Beschnitt …).
///
/// **Warum es das braucht.** Immich hält zu einem bearbeiteten Asset zwei Fassungen
/// bereit und liefert die bearbeitete nur auf ausdrückliche Nachfrage:
///
/// ```
/// …/thumbnail?size=thumbnail              444x250   (Original, unverändert)
/// …/thumbnail?size=thumbnail&edited=true  250x445   (gedreht)
/// ```
///
/// Ohne `edited=true` bleibt das Raster nach einer Drehung dauerhaft beim alten Bild —
/// nachgemessen am 06.09.2026: byte-identisch nach 18 Sekunden, nach zehn Minuten und
/// über einen App-Neustart hinweg. Cache-Räumen hilft dagegen nicht, denn der Server
/// selbst liefert unter dieser URL weiterhin das Unbearbeitete.
///
/// **Warum nicht einfach immer `edited=true`.** Der Parameter gehört zum Cache-Schlüssel.
/// Ihn an jede Kachel-URL zu hängen entwertete den kompletten Thumbnail-Cache (5 GB) in
/// einem Rutsch und lüde bei 113.000 Fotos alles neu. Bearbeitete Assets sind dagegen
/// eine Handvoll — die passen in eine Menge im Speicher.
///
/// **Woher die Markierungen kommen:** aus `CachedAssetEdit` beim Start, aus dem
/// Sync-Stream (`AssetEditsV1`, auch für Bearbeitungen aus Web und Telefon — siehe
/// `applySyncEditResults`), aus dem `isEdited`-Feld beim Öffnen eines Fotos und sofort
/// beim eigenen Drehen.
final class EditedAssetsStore: @unchecked Sendable {

    /// Gemeinsame Instanz. `ImmichAPIClient` fragt sie bei jedem `thumbnailURL`,
    /// Tests reichen stattdessen eine eigene Instanz herein.
    static let shared = EditedAssetsStore()

    private let lock = NSLock()
    private var ids: Set<String> = []

    init() {}

    func contains(_ assetId: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return ids.contains(assetId)
    }

    func mark(_ assetId: String) {
        lock.lock()
        defer { lock.unlock() }
        ids.insert(assetId)
    }

    func mark<S: Sequence>(contentsOf assetIds: S) where S.Element == String {
        lock.lock()
        defer { lock.unlock() }
        ids.formUnion(assetIds)
    }

    /// Ersetzt den gesamten Bestand — für das einmalige Einlesen beim Start.
    func replaceAll<S: Sequence>(_ assetIds: S) where S.Element == String {
        lock.lock()
        defer { lock.unlock() }
        ids = Set(assetIds)
    }

    /// Wenn die letzte Bearbeitung entfernt wurde — etwa beim Zurückdrehen auf 0°.
    /// Bliebe die Markierung stehen, hinge `edited=true` an einer URL, hinter der es
    /// nichts Bearbeitetes mehr gibt.
    func unmark(_ assetId: String) {
        lock.lock()
        defer { lock.unlock() }
        ids.remove(assetId)
    }

    /// Beim Abmelden: sonst hinge die Markierung eines fremden Kontos in den URLs.
    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        ids.removeAll()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return ids.count
    }
}
