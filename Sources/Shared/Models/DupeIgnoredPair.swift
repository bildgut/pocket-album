import Foundation
import SwiftData

enum DupeIgnoreReason: String, Sendable {
    /// Der Nutzer hat entschieden: diese zwei sind kein Duplikat.
    case notDuplicate
    /// Die Gruppe wurde gestapelt und ist damit erledigt.
    case stacked
}

/// Asset-Paare, die die Duplikatsuche nicht mehr zusammen anbietet.
///
/// Bewusste Abweichung von `GeoIgnoredAsset`, das auf die **Asset-ID** schlüsselt:
/// Dort ist die Aussage „für dieses Foto keine Koordinate mehr vorschlagen", und
/// die gilt fürs Foto allein. Hier lautet die Aussage „diese zwei gehören nicht
/// zusammen" — eine Beziehung. Auf die Asset-ID geschlüsselt verbannte ein
/// einziges „kein Duplikat" das Foto aus allen künftigen Gruppen, auch aus
/// richtigen.
///
/// Ein Gruppen-Fingerabdruck wiederum scheidet aus demselben Grund aus wie beim
/// GPS-Abgleich: Er wechselt, sobald ein Asset hinzukommt oder wegfällt. Das
/// Paar ist die einzige Einheit, die jede Neugruppierung überlebt — die
/// Union-Find-Phase vereinigt ignorierte Paare schlicht nicht, und die Gruppe
/// zerfällt von selbst richtig.
///
/// Wie `GeoIgnoredAsset` gehört das in SwiftData und nicht in UserDefaults:
/// Nutzer-Absicht, aus nichts rekonstruierbar, wächst auf tausende Einträge.
@Model
final class DupeIgnoredPair {
    /// `"\(min(a, b))|\(max(a, b))"` — die Reihenfolge der beiden IDs darf keine
    /// Rolle spielen, sonst gäbe es zwei Einträge für dieselbe Aussage.
    @Attribute(.unique) var pairKey: String
    var assetIdA: String
    var assetIdB: String
    var ignoredAt: Date
    /// Rohwert von `DupeIgnoreReason` — SwiftData speichert keine Enums direkt.
    var reasonRaw: String

    var reason: DupeIgnoreReason {
        DupeIgnoreReason(rawValue: reasonRaw) ?? .notDuplicate
    }

    init(
        assetIdA: String,
        assetIdB: String,
        ignoredAt: Date = Date(),
        reason: DupeIgnoreReason = .notDuplicate
    ) {
        let key = Self.key(assetIdA, assetIdB)
        self.pairKey = key
        self.assetIdA = min(assetIdA, assetIdB)
        self.assetIdB = max(assetIdA, assetIdB)
        self.ignoredAt = ignoredAt
        self.reasonRaw = reason.rawValue
    }

    /// Der kanonische Schlüssel eines ungeordneten Paares.
    static func key(_ a: String, _ b: String) -> String {
        a < b ? "\(a)|\(b)" : "\(b)|\(a)"
    }
}
