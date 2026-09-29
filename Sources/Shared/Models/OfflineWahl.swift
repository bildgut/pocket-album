import Foundation

/// Welche Fassung eines Assets im Offline-Speicher liegt.
///
/// Steht **im Dateinamen**, nicht in einem eigenen Feld: `CachedAsset.localFilePath`
/// gilt überall als Original (Mac: RAW-Entwicklung, Export; iOS: Teilen). Ein zweites
/// Feld hätte eine Schemaänderung gebraucht, und jeder Leser, der es vergäße, verschickte
/// eine Vorschau als Original. Der Name trägt die Fassung dorthin mit, wo der Pfad ist.
enum OfflineFassung: String, Codable, Sendable, CaseIterable {
    case original, vorschau, klein

    /// `2024-01/abc.vorschau.jpg` → `.vorschau`. Ohne erkannten Zusatz: Original —
    /// so hießen alle Dateien, bevor es Fassungen gab.
    static func aus(pfad: String) -> OfflineFassung {
        let teile = (pfad as NSString).lastPathComponent.split(separator: ".")
        guard teile.count >= 3,
              let fassung = OfflineFassung(rawValue: String(teile[teile.count - 2])),
              fassung != .original
        else { return .original }
        return fassung
    }

    func dateiname(assetId: String, endung: String) -> String {
        let basis = self == .original ? assetId : "\(assetId).\(rawValue)"
        return endung.isEmpty ? basis : "\(basis).\(endung)"
    }

    /// Gehört die Datei zu diesem Asset, gleich in welcher Fassung? Vergleicht den Teil
    /// vor dem **ersten** Punkt — `deletingPathExtension` ließe bei `a1.vorschau.jpg`
    /// `a1.vorschau` übrig und fände die Datei beim Aufräumen nicht.
    static func gehoert(dateiname: String, zu assetId: String) -> Bool {
        dateiname.split(separator: ".", maxSplits: 1).first.map(String.init) == assetId
    }

    /// Endung einer Vorschau aus dem `Content-Type`. Immich liefert JPEG oder WebP,
    /// je nach Servereinstellung; alles andere wird als JPEG abgelegt.
    static func endung(contentType: String?) -> String {
        let typ = contentType?.split(separator: ";").first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        return typ == "image/webp" ? "webp" : "jpg"
    }
}

/// Was der Nutzer beim Offline-Speichern eines Albums gewählt hat.
struct OfflineWahl: Codable, Equatable, Sendable {
    enum Fotos: String, Codable, Sendable, CaseIterable { case vorschau, original }
    enum Videos: String, Codable, Sendable, CaseIterable { case keine, klein, original }

    var fotos: Fotos = .vorschau
    var videos: Videos = .klein
    /// Darf dieses Album auch über eine teure Verbindung laden?
    var mobilfunk: Bool = false

    /// Welche Fassung geladen werden soll; `nil` = gar keine.
    func ziel(istVideo: Bool) -> OfflineFassung? {
        if istVideo {
            switch videos {
            case .keine: return nil
            case .klein: return .klein
            case .original: return .original
            }
        }
        return fotos == .original ? .original : .vorschau
    }

    /// Reicht eine vorhandene Fassung? Ein Original reicht immer — es wird nie
    /// gegen eine kleinere getauscht.
    func reicht(_ vorhanden: OfflineFassung, istVideo: Bool) -> Bool {
        guard let ziel = ziel(istVideo: istVideo) else { return true }
        return vorhanden == .original || vorhanden == ziel
    }
}

/// Größenschätzung vor dem Offline-Speichern. Angezeigt immer mit „≈“.
enum OfflineSchaetzung {
    struct Eintrag: Equatable, Sendable {
        var istVideo: Bool
        var bytes: Int64?
        var sekunden: Double?
    }

    static let fotoVorschau: Int64 = 350_000
    static let fotoOhneGroesse: Int64 = 4_000_000
    static let videoOriginalJeSekunde: Double = 2_000_000
    static let videoKleinJeSekunde: Double = 300_000
    static let videoKleinOhneLaufzeit: Int64 = 15_000_000
    /// Weder Größe noch Laufzeit bekannt — die Spec schweigt dazu; grob 50 s Original.
    static let videoOriginalOhneAngaben: Int64 = 100_000_000

    static func bytes(_ eintraege: [Eintrag], wahl: OfflineWahl) -> Int64 {
        eintraege.reduce(0) { $0 + bytes($1, wahl: wahl) }
    }

    static func bytes(_ e: Eintrag, wahl: OfflineWahl) -> Int64 {
        let sekunden = e.sekunden.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        guard e.istVideo else {
            return wahl.fotos == .original ? (e.bytes ?? fotoOhneGroesse) : fotoVorschau
        }
        switch wahl.videos {
        case .keine:
            return 0
        case .klein:
            return sekunden.map { Int64($0 * videoKleinJeSekunde) } ?? videoKleinOhneLaufzeit
        case .original:
            return e.bytes ?? sekunden.map { Int64($0 * videoOriginalJeSekunde) } ?? videoOriginalOhneAngaben
        }
    }

    /// Höchstens 90 % des freien Platzes. Unbekannter Platz sperrt nicht.
    static func passt(bytes: Int64, frei: Int64?) -> Bool {
        guard let frei else { return true }
        return Double(bytes) <= Double(frei) * 0.9
    }
}
