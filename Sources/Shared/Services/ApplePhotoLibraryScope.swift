import Foundation
import ObjectiveC.runtime
import Photos

/// Sagt, ob ein `PHAsset` zur **gemeinsamen iCloud-Mediathek** gehört.
///
/// Das ist keine Stilfrage, sondern der einzige verfügbare Weg: Photos.framework
/// hat für die gemeinsame Mediathek (macOS 13+) **keine öffentliche API**. Der
/// naheliegende Kandidat `PHAssetSourceType.typeCloudShared` meint etwas anderes —
/// die alte iCloud-Fotofreigabe (geteilte Alben, Fotostream). Fotos aus der
/// gemeinsamen Mediathek kommen als `.typeUserLibrary` zurück und sind über die
/// öffentliche Schnittstelle von eigenen Fotos nicht zu unterscheiden.
///
/// Warum das trotzdem hier steht: Löschen in der gemeinsamen Mediathek wirkt für
/// **alle Teilnehmenden**. Ohne diese Unterscheidung kann die Löschprüfung nicht
/// verantwortet werden — und ein Lauf ohne sie darf gar nicht erst starten
/// (siehe `istVerfügbar`).
///
/// Die App wird nicht über den App Store verteilt; die Nutzung einer privaten
/// Property ist deshalb kein Freigabe-, sondern ein Haltbarkeitsrisiko: Apple kann
/// das Symbol jederzeit entfernen. Genau dafür meldet `istVerfügbar` ehrlich `false`,
/// statt stillschweigend auf „gehört mir" zurückzufallen.
enum ApplePhotoLibraryScope {

    /// Private, schreibgeschützte `BOOL`-Property auf `PHAsset` (verifiziert gegen
    /// das macOS-26-SDK: `TB,R,N,V_participatesInLibraryScope`).
    private static let teilnahmeProperty = "participatesInLibraryScope"

    /// Privater Getter, der den Mediathek-Bereich als Zahl liefert. Entscheidet
    /// **nichts** — steht nur im Log, damit sich bei einem unerwarteten Ergebnis
    /// (etwa: alle Fotos gelten plötzlich als geteilt) erkennen lässt, ob die
    /// Bedeutung von `participatesInLibraryScope` sich geändert hat.
    private static let bereichGetter = "bundleScope"

    /// Ob die Erkennung auf diesem System überhaupt möglich ist. Einmal ermittelt —
    /// die Objective-C-Klassenstruktur ändert sich zur Laufzeit nicht.
    static let istVerfügbar: Bool = class_getProperty(PHAsset.self, teilnahmeProperty) != nil

    /// - Returns: `true`/`false` für die Zugehörigkeit zur gemeinsamen Mediathek,
    ///   `nil`, wenn die Frage auf diesem System nicht beantwortbar ist. `nil` heißt
    ///   ausdrücklich **nicht** „gehört mir" — Aufrufer müssen den Fall als
    ///   Löschsperre behandeln.
    static func gehörtZurGemeinsamenMediathek(_ asset: PHAsset) -> Bool? {
        guard istVerfügbar else { return nil }
        return (asset.value(forKey: teilnahmeProperty) as? NSNumber)?.boolValue
    }

    /// Reiner Diagnosewert, siehe `bereichGetter`. `nil`, wenn der Getter fehlt.
    static func bereich(_ asset: PHAsset) -> Int? {
        guard asset.responds(to: NSSelectorFromString(bereichGetter)) else { return nil }
        return (asset.value(forKey: bereichGetter) as? NSNumber)?.intValue
    }
}
