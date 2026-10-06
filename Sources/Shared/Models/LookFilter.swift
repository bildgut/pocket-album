import Foundation

/// Die Chips über dem Look-Raster. `schwarzweiss`, `kraeftig` und `gedaempft` schneiden
/// quer durch die Familien und leiten sich aus Eigenschaften des Looks ab — sie werden
/// nicht als weiteres Feld gepflegt.
enum LookChip: String, CaseIterable, Sendable, Identifiable {
    case alle, fuji, leica, analog, kino, landschaft, vintage, urban, community, schwarzweiss, kraeftig, gedaempft

    var id: String { rawValue }

    var titel: String {
        switch self {
        case .alle: return "Alle"
        case .fuji: return "Fuji"
        case .leica: return "Leica"
        case .analog: return "Analog"
        case .kino: return "Kino"
        case .landschaft: return "Landschaft"
        case .vintage: return "Vintage"
        case .urban: return "Urban"
        case .community: return "Community"
        case .schwarzweiss: return "S/W"
        case .kraeftig: return "Kräftig"
        case .gedaempft: return "Gedämpft"
        }
    }
}

/// Reine Funktion, keine Ansicht: Die Auswahl lag sonst in einem privaten
/// Rechen-Property des Panels und wäre unprüfbar — dieselbe Lehre wie bei
/// `PhoneAlbumSections`.
enum LookFilter {

    /// Ab dieser Sättigung gilt ein farbiger Look als „kräftig" …
    static let kraeftigAb: Double = 1.15
    /// … und bis zu dieser als „gedämpft". Dazwischen ist er keins von beiden.
    static let gedaempftBis: Double = 0.9

    static func sichtbare(katalog: [FilmLook], chip: LookChip) -> [FilmLook] {
        switch chip {
        case .alle:
            return katalog
        case .fuji:
            return katalog.filter { $0.familie == .fuji }
        case .leica:
            return katalog.filter { $0.familie == .leica }
        case .analog:
            return katalog.filter { $0.familie == .analog }
        case .kino:
            return katalog.filter { $0.familie == .kino }
        case .landschaft:
            return katalog.filter { $0.familie == .landschaft }
        case .vintage:
            return katalog.filter { $0.familie == .vintage }
        case .urban:
            return katalog.filter { $0.familie == .urban }
        case .community:
            return katalog.filter { $0.familie == .community }
        case .schwarzweiss:
            return katalog.filter(\.istSchwarzweiss)
        case .kraeftig:
            return katalog.filter { !$0.istSchwarzweiss && $0.saettigung >= kraeftigAb }
        case .gedaempft:
            return katalog.filter { !$0.istSchwarzweiss && $0.saettigung <= gedaempftBis }
        }
    }
}
