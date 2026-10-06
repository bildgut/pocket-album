import Foundation
import SwiftData

/// Welche Datei das Teilenblatt bekommt.
///
/// Geteilt wird das **Original** — wer teilt, will die Datei, nicht ein
/// bildschirmgroßes JPEG. Liegt offline nur eine Vorschau oder die kleine
/// Videofassung, holt der Server das Original; scheitert das (kein Netz), wird
/// die lokale Fassung geteilt statt einer Fehlermeldung.
enum PhoneTeilenWeg: Equatable {
    case lokal(URL)
    case server(ersatz: URL?)
    case nichts

    /// - Parameter originalName: Asset-ID → `originalFileName`. Lokale Dateien
    ///   tragen interne Namen (`<uuid>.heic`, `<uuid>.vorschau.jpg`); geteilt wird
    ///   deshalb eine gleichnamige Kopie (harter Link) in einem `Teilen-`-Ordner.
    ///   Liefert die Quelle `nil` oder scheitert das Anlegen, bleibt die Datei selbst.
    static func bestimme(lokal: URL?, hatServer: Bool,
                         originalName: (String) -> String? = nameAusStore) -> PhoneTeilenWeg {
        let benannt = lokal.map { benenne($0, originalName: originalName) }
        if let lokal, let benannt, OfflineFassung.aus(pfad: lokal.lastPathComponent) == .original {
            return .lokal(benannt)
        }
        if hatServer { return .server(ersatz: benannt) }
        if let benannt { return .lokal(benannt) }
        return .nichts
    }

    private static func benenne(_ url: URL, originalName: (String) -> String?) -> URL {
        let assetId = String(url.lastPathComponent.prefix { $0 != "." })
        guard let name = originalName(assetId) else { return url }
        return PhoneTeilenAblage.benannteKopie(von: url, originalName: name) ?? url
    }

    /// `originalFileName` aus dem Store. Eigener Context — die Ansicht reicht
    /// keinen herein.
    static func nameAusStore(_ assetId: String) -> String? {
        var d = FetchDescriptor<CachedAsset>(predicate: #Predicate { $0.assetId == assetId })
        d.fetchLimit = 1
        let name = (try? ModelContext(PhoneModelContainer.shared).fetch(d).first)?.originalFileName
        return name?.isEmpty == false ? name : nil
    }
}
