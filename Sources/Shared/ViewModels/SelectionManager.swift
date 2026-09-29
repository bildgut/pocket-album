import Foundation

/// Manages multi-selection state for the photo grid.
@Observable
@MainActor
final class SelectionManager {
    var selectedIds: Set<String> = []
    var lastSelectedId: String?

    var count: Int { selectedIds.count }
    var isEmpty: Bool { selectedIds.isEmpty }

    func isSelected(_ id: String) -> Bool {
        selectedIds.contains(id)
    }

    /// Toggle selection on ⌘+click
    func toggleSelection(_ id: String) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else {
            selectedIds.insert(id)
        }
        lastSelectedId = id
    }

    /// Range select on Shift+click
    func rangeSelect(to id: String, in assets: [Asset]) {
        guard let lastId = lastSelectedId,
              let lastIndex = assets.firstIndex(where: { $0.id == lastId }),
              let targetIndex = assets.firstIndex(where: { $0.id == id }) else {
            toggleSelection(id)
            return
        }

        let range = min(lastIndex, targetIndex)...max(lastIndex, targetIndex)
        for i in range {
            selectedIds.insert(assets[i].id)
        }
        lastSelectedId = id
    }

    func selectAll(_ assets: [Asset]) {
        selectedIds = Set(assets.map(\.id))
    }

    func clearSelection() {
        selectedIds.removeAll()
        lastSelectedId = nil
    }

    func selectedAssets(from assets: [Asset]) -> [Asset] {
        assets.filter { selectedIds.contains($0.id) }
    }
}
