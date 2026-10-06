import Foundation
import SwiftData

/// Was vor einer Datumskorrektur im Bild stand.
///
/// Anders als beim GPS-Abgleich ist diese Übernahme **umkehrbar**: dort scheitert
/// das Zurück daran, dass der Server `null` ablehnt; hier wird nie `null`
/// geschrieben, sondern immer ein konkreter Wert zurück.
///
/// Der alte Wert wird wörtlich so gesichert, wie der Server ihn geliefert hat —
/// nicht als `Date`. Ein Umweg über `Date` verlöre den UTC-Versatz des Bildes, und
/// genau der muss beim Zurückschreiben wieder derselbe sein.
///
/// Bewusst in SwiftData statt in UserDefaults: das ist Nutzer-Historie, aus nichts
/// rekonstruierbar, und wächst mit jeder Übernahme.
///
/// `assetId` ist eindeutig: wird ein Bild zweimal korrigiert, ersetzt der neue
/// Eintrag den alten. Das ist gewollt — die Rücknahme führt dann auf den Stand vor
/// der *letzten* Korrektur zurück, nicht auf den Urzustand. Eine vollständige
/// Historie wäre eine andere Zusage, die die Oberfläche nicht macht.
@Model
final class DateFixUndoEntry {
    @Attribute(.unique) var assetId: String
    var previousDateTimeOriginal: String
    var newDateTimeOriginal: String
    /// Titel der Gruppe zum Zeitpunkt der Übernahme — zum Beschriften des Knopfs.
    var groupTitle: String
    /// Alle Bilder einer Übernahme teilen sich diesen Wert.
    var batchId: String
    var appliedAt: Date

    init(assetId: String,
         previousDateTimeOriginal: String,
         newDateTimeOriginal: String,
         groupTitle: String,
         batchId: String,
         appliedAt: Date = Date()) {
        self.assetId = assetId
        self.previousDateTimeOriginal = previousDateTimeOriginal
        self.newDateTimeOriginal = newDateTimeOriginal
        self.groupTitle = groupTitle
        self.batchId = batchId
        self.appliedAt = appliedAt
    }
}
