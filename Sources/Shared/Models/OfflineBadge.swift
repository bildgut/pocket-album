import Foundation

/// Sichtbarer Offline-Zustand eines Albums, abgeleitet aus seinem `OfflinePin`.
/// Reiner Wertetyp, damit die Ableitung ohne Oberfläche testbar ist; die Wahrheit
/// bleibt im Vermerk, die Ansicht spiegelt sie nur.
enum OfflineBadge: Equatable, Sendable {
    /// Kein Vermerk — das Album kommt aus der Cloud.
    case cloud
    /// Vermerkt, aber noch kein abgeschlossener Lauf (oder wartet auf WLAN).
    case pending
    /// Vermerkt und vollständig geladen.
    case offline
    /// Vermerkt, letzter Lauf mit Fehler.
    case failed

    static func from(pin: OfflinePin?) -> OfflineBadge {
        guard let pin else { return .cloud }
        if pin.lastError != nil { return .failed }
        return pin.lastCompletedAt == nil ? .pending : .offline
    }

    var symbolName: String {
        switch self {
        case .cloud:   return "icloud"
        case .pending: return "arrow.down.circle"
        case .offline: return "checkmark.circle.fill"
        case .failed:  return "exclamationmark.triangle"
        }
    }

    var label: String {
        switch self {
        case .cloud:   return "In der Cloud"
        case .pending: return "Wird geladen"
        case .offline: return "Offline verfügbar"
        case .failed:  return "Laden fehlgeschlagen"
        }
    }
}
