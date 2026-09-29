import Foundation

// MARK: - Search Models

/// DTO für einen Immich Tag (Server ≥ v2.6.0)
struct TagInfo: Codable, Identifiable, Hashable {
    let id: String
    let value: String
    let name: String?

    /// Human-readable label: last path component of `value`.
    /// E.g. `"reise/europa"` → `"europa"`;  `"urlaub"` → `"urlaub"`.
    var displayName: String {
        value.split(separator: "/").last.map(String.init) ?? value
    }
}

