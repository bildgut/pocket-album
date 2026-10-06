import Foundation
import SwiftData

// MARK: - Art des Pins

enum OfflinePinKind: String, Codable, CaseIterable, Sendable {
    /// Ein echtes Immich-Album (``CachedAlbum``).
    case album
    /// Ein lokales Smart Album (``SmartAlbum``).
    case smartAlbum

    var label: String {
        switch self {
        case .album:      return "Album"
        case .smartAlbum: return "Smart Album"
        }
    }

    var iconName: String {
        switch self {
        case .album:      return "rectangle.stack"
        case .smartAlbum: return "wand.and.stars"
        }
    }
}

// MARK: - Modell

/// Ein „offline vorhalten"-Vermerk — die einzige Quelle der Wahrheit dafür, welche
/// Originale dauerhaft auf der Platte bleiben müssen.
///
/// Bewusst eine eigene Entity statt eines Flags an ``SmartAlbum``: Ein zusätzliches
/// Feld an einem bestehenden `@Model` ändert dessen Checksumme, und die
/// Schema-Versionen V1–V8 referenzieren die Live-Klasse. Sie bräuchten dann alle eine
/// eingefrorene Kopie, sonst startet die App mit „Duplicate version checksums
/// detected" gar nicht mehr. Eine neue, leer startende Entity ist dagegen exakt das
/// Muster der Migrationen V4→V5 bis V7→V8: reine Lightweight-Migration.
///
/// Der zweite Grund ist inhaltlich: Beide Album-Arten teilen sich damit einen
/// Code-Pfad, und die aufgelöste Mitgliedschaft — bei Smart Alben regelbasiert und
/// veränderlich — gehört an den Vermerk, nicht an das Album.
@Model
final class OfflinePin {
    #Index<OfflinePin>([\.pinId])

    /// `"album:<albumId>"` bzw. `"smart:<uuid>"`. Zusammengesetzt, damit ein normales
    /// und ein Smart Album mit gleicher ID-Zeichenfolge sich nicht in die Quere kommen.
    @Attribute(.unique) var pinId: String
    var kindRaw: String
    /// `CachedAlbum.albumId` bzw. `SmartAlbum.id.uuidString`.
    var targetId: String
    /// Zuletzt bekannter Name — damit die Einstellungen einen Pin auch dann benennen
    /// können, wenn das Album gerade nicht geladen ist.
    var displayName: String
    /// JSON-kodierte `[String]` der aufgelösten Mitgliedschaft.
    var assetIdsData: Data
    var pinnedAt: Date
    /// Wann die Mitgliedschaft zuletzt erfolgreich aufgelöst wurde.
    var lastResolvedAt: Date?
    /// Wann zuletzt alle Dateien vollständig auf der Platte lagen.
    var lastCompletedAt: Date?
    /// Klartext des letzten Problems (Auflösung oder Download). `nil` = alles gut.
    var lastError: String?

    init(kind: OfflinePinKind, targetId: String, displayName: String, assetIds: [String] = []) {
        self.pinId = Self.pinId(kind: kind, targetId: targetId)
        self.kindRaw = kind.rawValue
        self.targetId = targetId
        self.displayName = displayName
        self.assetIdsData = (try? JSONEncoder().encode(assetIds)) ?? Data("[]".utf8)
        self.pinnedAt = Date()
    }

    static func pinId(kind: OfflinePinKind, targetId: String) -> String {
        switch kind {
        case .album:      return "album:\(targetId)"
        case .smartAlbum: return "smart:\(targetId)"
        }
    }

    var kind: OfflinePinKind {
        get { OfflinePinKind(rawValue: kindRaw) ?? .album }
        set { kindRaw = newValue.rawValue }
    }

    var assetIds: [String] {
        get { (try? JSONDecoder().decode([String].self, from: assetIdsData)) ?? [] }
        set { assetIdsData = (try? JSONEncoder().encode(newValue)) ?? Data("[]".utf8) }
    }
}
