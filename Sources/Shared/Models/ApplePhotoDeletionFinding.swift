import Foundation
import SwiftData

/// Der aktuelle Befund zu genau einem Apple-Photos-Foto aus dem letzten Löschlauf,
/// der es geprüft hat.
///
/// Der Grund für diese Tabelle ist eine Erfahrung, kein Feature: Der erste
/// vollständige Nachhol-Abgleich lief über 60 Stunden und hinterließ nur Zähler —
/// „583 Live Photos unvollständig" ohne jede Angabe, *welche*. Jede Folgeaktion
/// hätte den ganzen Lauf wiederholen müssen, um ein paar hundert Fotos
/// wiederzufinden. Mit dem Journal wird daraus eine Abfrage.
///
/// Genau ein Eintrag je Foto: Ein zweiter Lauf überschreibt den Befund. Eine
/// Historie wäre für die einzige interessante Frage — „was ist heute noch offen" —
/// wieder eine Aggregation.
@Model
final class ApplePhotoDeletionFinding {
    /// `PHAsset.localIdentifier`. Dieselbe Identität wie in
    /// `ApplePhotosAssetMapping`, damit sich beide ohne Umweg schneiden lassen.
    @Attribute(.unique) var localIdentifier: String
    var immichAssetId: String
    /// `ApplePhotoDeletionVerdict.journalSchlüssel` — bewusst als String, damit ein
    /// Wert aus einer älteren Fassung lesbar bleibt, statt die Migration zu belasten.
    var verdictRaw: String
    /// Nur zur Anzeige; `nil`, wenn das Foto zum Zeitpunkt der Prüfung gar nicht
    /// mehr in der Bibliothek stand.
    var dateiname: String?
    /// Bewusst Englisch/ASCII, nicht `geprüftAm`: Ein Umlaut in einem gespeicherten
    /// SwiftData-Attribut lässt CoreData beim Erzeugen des On-Disk-Modells hart
    /// abstürzen (unkatchbare `NSInvalidArgumentException`, kein Swift-`Error`) —
    /// reproduziert und isoliert beim Bau dieser Tabelle. Deshalb gilt projektweit:
    /// gespeicherte `@Model`-Properties heißen ASCII, wie auch anderswo
    /// (`uploadedAt`, `updatedAt`, `createdAt`).
    var checkedAt: Date

    init(
        localIdentifier: String,
        immichAssetId: String,
        verdictRaw: String,
        dateiname: String? = nil,
        checkedAt: Date = Date()
    ) {
        self.localIdentifier = localIdentifier
        self.immichAssetId = immichAssetId
        self.verdictRaw = verdictRaw
        self.dateiname = dateiname
        self.checkedAt = checkedAt
    }

    /// `nil`, wenn der gespeicherte Schlüssel aus einer Fassung stammt, die diese
    /// Version nicht kennt.
    var verdict: ApplePhotoDeletionVerdict? {
        ApplePhotoDeletionVerdict(journalSchlüssel: verdictRaw)
    }
}
