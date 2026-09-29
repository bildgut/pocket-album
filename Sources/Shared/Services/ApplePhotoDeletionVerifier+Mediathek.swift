import Foundation
import Photos

// Der einzige PhotoKit-Teil des Verifiers liegt in einer eigenen Datei: Die
// übrigen Typen aus ApplePhotoDeletionVerdict.swift braucht das SwiftData-Modell
// `ApplePhotoDeletionFinding`, das auch die iOS-App kompiliert — diese Datei ist
// dort ausgeschlossen (project.yml), damit das Binary PhotoKit nicht linkt.
extension ApplePhotoDeletionVerifier {

    /// Vorstufe vor allem anderen: Fotos, die nicht allein dem Nutzer gehören, sind
    /// grundsätzlich tabu — dort zu löschen wirkte für alle Teilnehmenden.
    ///
    /// Zwei verschiedene Dinge, die leicht verwechselt werden:
    /// - `sourceType == .typeCloudShared` ist die **alte iCloud-Fotofreigabe**
    ///   (geteilte Alben, Fotostream). Solche Assets bekommen praktisch nie ein
    ///   Mapping, die Prüfung kostet aber nichts.
    /// - `gehörtZurGemeinsamenMediathek` ist die **gemeinsame Mediathek** ab
    ///   macOS 13. Diese Fotos melden `sourceType == .typeUserLibrary` und sind
    ///   über die öffentliche API nicht erkennbar — deshalb kommt das Signal aus
    ///   `ApplePhotoLibraryScope`. Genau dieser Fall fehlte, weshalb Apples
    ///   Löschdialog „für alle Teilnehmenden löschen" anbot.
    ///
    /// - Parameter gehörtZurGemeinsamenMediathek: `nil` heißt „nicht feststellbar"
    ///   und führt zur Ablehnung — nicht zur Freigabe.
    /// - Returns: `nil`, wenn keine Sonderbehandlung greift und die normale Kette
    ///   entscheiden darf.
    static func mediathekUrteil(
        sourceType: PHAssetSourceType,
        gehörtZurGemeinsamenMediathek: Bool?
    ) -> ApplePhotoDeletionVerdict? {
        if sourceType.contains(.typeCloudShared) { return .inGeteilterMediathek }
        switch gehörtZurGemeinsamenMediathek {
        case .some(true):  return .inGeteilterMediathek
        case .some(false): return nil
        case .none:        return .mediathekNichtPrüfbar
        }
    }
}
