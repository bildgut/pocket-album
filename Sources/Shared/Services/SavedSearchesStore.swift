import Foundation
import Observation

// MARK: - SavedSearchesStore

/// Persists recent + pinned searches in UserDefaults.
/// Recent searches are capped at 15 entries (oldest evicted first).
@Observable
final class SavedSearchesStore {

    // MARK: Singleton

    static let shared = SavedSearchesStore()

    // MARK: Constants

    private let maxRecent = 15
    private let defaultsKey = "im.savedSearches"

    // MARK: State

    private(set) var searches: [SavedSearch] = []

    var pinned: [SavedSearch]  { searches.filter(\.isPinned) }
    var recent: [SavedSearch]  { searches.filter { !$0.isPinned }.sorted { $0.date > $1.date } }

    // MARK: Init

    private init() {
        load()
    }

    // MARK: API

    /// Record a new search (or bump its date if it already exists).
    func record(query: String, tokens: [SearchToken]) {
        let normalized = query.trimmingCharacters(in: .whitespaces)
        guard !normalized.isEmpty || !tokens.isEmpty else { return }

        // De-duplicate: same query + same token-ids counts as the same search
        let tokenIds = Set(tokens.map(\.id))
        if let existingIndex = searches.firstIndex(where: {
            !$0.isPinned
            && $0.query.lowercased() == normalized.lowercased()
            && Set($0.tokens.map(\.id)) == tokenIds
        }) {
            searches[existingIndex].date = Date()
        } else {
            let entry = SavedSearch(query: normalized, tokens: tokens)
            searches.append(entry)
        }

        // Evict oldest non-pinned entries beyond cap
        let overLimit = recent.count - maxRecent
        if overLimit > 0 {
            let toRemove = recent.suffix(overLimit).map(\.id)
            searches.removeAll { toRemove.contains($0.id) }
        }

        save()
    }

    func pin(_ search: SavedSearch) {
        if let i = searches.firstIndex(where: { $0.id == search.id }) {
            searches[i].isPinned = true
            save()
        }
    }

    func unpin(_ search: SavedSearch) {
        if let i = searches.firstIndex(where: { $0.id == search.id }) {
            searches[i].isPinned = false
            save()
        }
    }

    func remove(_ search: SavedSearch) {
        searches.removeAll { $0.id == search.id }
        save()
    }

    func clearRecent() {
        searches.removeAll { !$0.isPinned }
        save()
    }

    // MARK: Persistence

    private func load() {
        guard let data = AppEnvironment.defaults.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode([SavedSearch].self, from: data)
        else { return }
        searches = decoded
    }

    private func save() {
        if let encoded = try? JSONEncoder().encode(searches) {
            AppEnvironment.defaults.set(encoded, forKey: defaultsKey)
        }
    }
}
