import Foundation

/// Stabiler Fingerabdruck über eine Menge von Asset-IDs.
///
/// Eigene FNV-1a-Rechnung statt `hashValue`: Swifts Hash ist pro Programmlauf
/// zufällig gesalzen. Eine damit gebildete Identität wechselte bei jedem Start —
/// unbrauchbar als Schlüssel einer Ignorierliste, die den Neustart überleben soll.
///
/// Die Eingabe wird sortiert: dieselbe Menge ergibt denselben Abdruck, unabhängig
/// davon, in welcher Reihenfolge ein Scan sie zusammengetragen hat.
enum AssetSetFingerprint {

    static func make(_ assetIds: [String], prefix: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for id in assetIds.sorted() {
            for byte in id.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x100_0000_01b3
            }
            hash ^= 0x2f                                  // Trenner zwischen IDs
            hash = hash &* 0x100_0000_01b3
        }
        return "\(prefix)_\(String(hash, radix: 36))_\(assetIds.count)"
    }
}
