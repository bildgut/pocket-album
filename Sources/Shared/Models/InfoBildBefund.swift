import Foundation
import SwiftData

/// Was über ein Bild herausgefunden wurde: vom Vorfilter abgewiesen, ein Foto,
/// ein Screenshot oder ein Dokument samt Unterart.
///
/// Warum in der Datenbank und nicht im ViewModel: Der Erstlauf über die ganze
/// Mediathek dauert Stunden. Ein Neustart darf ihn nicht wiederholen, und die
/// Rubriken müssen sofort nach dem Start gefüllt sein.
///
/// Gespeicherte Namen sind rein ASCII — ein Umlaut in einem gespeicherten
/// Attribut bringt CoreData beim Aufbau des Migrationsplans zum Absturz.
@Model
final class InfoBildBefund {

    /// Ein Befund je Foto.
    @Attribute(.unique) var assetId: String

    /// `"ohne"` (Vorfilter abgewiesen), Rohwert von ``InfoBildArt`` oder
    /// `"refused"` (Sicherheitsfilter). Als String, damit ein neuer Fall keine
    /// Migration braucht.
    var result: String

    /// Rohwert von ``InfoBildUnterart``, nur bei `result == "dokument"`.
    var subtype: String?

    /// Stand des Vorfilters bzw. des Prompts. Ein Befund einer älteren Version
    /// gilt als ungeprüft und wird erneut eingereiht.
    var filterVersion: Int
    var promptVersion: Int

    var checkedAt: Date

    init(assetId: String, result: String, subtype: String?, promptVersion: Int, filterVersion: Int, checkedAt: Date = Date()) {
        self.assetId = assetId
        self.result = result
        self.subtype = subtype
        self.promptVersion = promptVersion
        self.filterVersion = filterVersion
        self.checkedAt = checkedAt
    }

    /// Der Vorfilter hat abgewiesen — das Modell hat das Bild nie gesehen.
    static let ergebnisOhne = "ohne"
    /// Der Sicherheitsfilter hat die Antwort verweigert.
    static let ergebnisAbgelehnt = "refused"
}
