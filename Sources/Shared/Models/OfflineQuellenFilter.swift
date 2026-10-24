import Foundation

/// Suchfilter der regelbasierten Offline-Quellen, die über die strukturierte Suche
/// aufgelöst werden (Spec `docs/superpowers/specs/2026-10-22-ios-offline-quellen-design.md`).
/// „Letzte Tage“ hat seinen Filter in ``ZuletztOffline``, weil er von der Stufe abhängt.
enum OfflineQuellenFilter {
    /// `targetId` des einen Favoriten-Vermerks.
    static let favoritenTargetId = "eigene"

    /// `nil` für Arten, die nicht über eine Suche aufgelöst werden.
    static func filter(kind: OfflinePinKind, targetId: String) -> SearchFilter? {
        var filter = SearchFilter.visibleLibrary(type: nil)
        switch kind {
        case .favoriten:
            filter.isFavorite = .equals(true)
        case .person:
            filter.personIds = .anyOf([targetId])
        case .album, .smartAlbum, .zuletzt:
            return nil
        }
        return filter
    }
}
