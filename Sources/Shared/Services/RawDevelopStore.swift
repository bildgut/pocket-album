import Foundation
import SwiftData

/// Fassade für den persistierten Entwicklungsstand des RAW-Develop-Moduls.
///
/// Hält das `ModelContext`-Handling aus den ViewModels heraus, die auf ``RawDevelopState``
/// und ``DevelopPreset`` zugreifen — dieselbe Aufteilung wie bei den anderen
/// SwiftData-Fassaden im Projekt (z. B. `OfflinePinStore`).
@MainActor
struct RawDevelopStore {
    let modelContext: ModelContext

    // MARK: - Entwicklungsstand

    func state(for assetId: String) -> RawDevelopState? {
        var descriptor = FetchDescriptor<RawDevelopState>(
            predicate: #Predicate { $0.assetId == assetId }
        )
        descriptor.fetchLimit = 1
        do {
            return try modelContext.fetch(descriptor).first
        } catch {
            AppLogger.app.error("RawDevelopStore: Laden des Zustands fehlgeschlagen: \(error)")
            return nil
        }
    }

    func params(for assetId: String) -> RawDevelopParams? {
        guard let state = state(for: assetId) else { return nil }
        return RawDevelopParams(json: state.paramsJSON)
    }

    /// Legt den Zustand an oder aktualisiert ihn (Upsert nach `assetId`), `updatedAt = now`.
    func saveParams(_ params: RawDevelopParams, for assetId: String) {
        let json = params.encodedJSON()
        if let existing = state(for: assetId) {
            existing.paramsJSON = json
            existing.updatedAt = Date()
        } else {
            modelContext.insert(RawDevelopState(assetId: assetId, paramsJSON: json))
        }
        save()
    }

    func setDevelopedAsset(_ developedAssetId: String?, for assetId: String) {
        guard let existing = state(for: assetId) else { return }
        existing.developedAssetId = developedAssetId
        existing.updatedAt = Date()
        save()
    }

    func deleteState(for assetId: String) {
        guard let existing = state(for: assetId) else { return }
        modelContext.delete(existing)
        save()
    }

    // MARK: - Presets

    func presets() -> [DevelopPreset] {
        let descriptor = FetchDescriptor<DevelopPreset>(
            sortBy: [SortDescriptor(\.sortIndex)]
        )
        do {
            return try modelContext.fetch(descriptor)
        } catch {
            AppLogger.app.error("RawDevelopStore: Laden der Presets fehlgeschlagen: \(error)")
            return []
        }
    }

    @discardableResult
    func createPreset(name: String, params: RawDevelopParams) -> DevelopPreset {
        let nextIndex = (presets().map(\.sortIndex).max() ?? -1) + 1
        let preset = DevelopPreset(
            name: name,
            paramsJSON: params.encodedJSON(),
            sortIndex: nextIndex
        )
        modelContext.insert(preset)
        save()
        return preset
    }

    func renamePreset(_ preset: DevelopPreset, to name: String) {
        preset.name = name
        save()
    }

    func deletePreset(_ preset: DevelopPreset) {
        modelContext.delete(preset)
        save()
    }

    // MARK: - Speichern

    private func save() {
        do {
            try modelContext.save()
        } catch {
            AppLogger.app.error("RawDevelopStore: Speichern fehlgeschlagen: \(error)")
        }
    }
}
