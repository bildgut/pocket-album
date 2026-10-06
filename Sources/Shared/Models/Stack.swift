import Foundation

/// A stack (series) groups related assets. One is the "primary" asset, the rest are children.
struct Stack: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let primaryAssetId: String
    let assets: [Asset]

    /// Human-readable label: primary asset's filename + count
    var displayName: String {
        let primary = assets.first(where: { $0.id == primaryAssetId })
        let baseName = primary?.originalFileName ?? "Serie"
        return "\(baseName) (\(assets.count))"
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: Stack, rhs: Stack) -> Bool {
        lhs.id == rhs.id
    }
}
