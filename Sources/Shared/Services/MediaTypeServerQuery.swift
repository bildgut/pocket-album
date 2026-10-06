import Foundation

/// Übersetzt die Objektiv- und Dateinamenregel einer Medienart (Selfies, Porträts) in
/// **einen** Serverfilter — dieselbe Regel wie ``MediaType/matches(_:)``.
///
/// Der Server kennt für `lensModel`/`model` nur exakte Gleichheit. Die Stichworte
/// („front", „truedepth" …) werden deshalb gegen die Kataloge aus
/// `GET /api/search/suggestions?type=camera-lens-model|camera-model` aufgelöst und als
/// `in: [...]` geschickt. Am 11.09.2026 ID-genau gleich der lokalen Regel über den
/// ganzen Index: 4 016 Selfies, 1 935 Porträts (1 229 übers Objektiv, 706 über
/// Dateinamen wie `PXL_….PORTRAIT.jpg`).
///
/// Die alte Metadatensuche mit `lensModel: "front"` verglich exakt und fand nie etwas.
enum MediaTypeServerQuery {

    /// Der Filter, oder `nil`, wenn die Medienart keine Stichworte hat oder kein
    /// Katalogwert passt — dann gibt es auf dem Server nichts zu fragen.
    static func filter(for mediaType: MediaType, lenses: [String], models: [String]) -> SearchFilter? {
        let lensMatches = lenses.filter { value in
            mediaType.lensKeywords.contains { value.lowercased().contains($0) }
        }
        let modelMatches = models.filter { value in
            mediaType.lensKeywords.contains { value.lowercased().contains($0) }
        }

        var branches: [SearchFilter] = []
        if !lensMatches.isEmpty {
            var branch = SearchFilter()
            branch.lensModel = .oneOf(lensMatches)
            branches.append(branch)
        }
        // Lokal gilt das Kameramodell nur, wenn das Objektiv fehlt (`lensModel ?? model`).
        if !modelMatches.isEmpty {
            var branch = SearchFilter()
            branch.lensModel = .isNull
            branch.model = .oneOf(modelMatches)
            branches.append(branch)
        }
        // `like` ignoriert Groß-/Kleinschreibung und Akzente — „porträt" trifft damit
        // auch „portrat", lokal nicht. Ein vernachlässigbarer Unterschied.
        for keyword in mediaType.fileNameKeywords {
            var branch = SearchFilter()
            branch.originalFileName = .contains(keyword)
            branches.append(branch)
        }
        guard !branches.isEmpty else { return nil }

        var filter = SearchFilter.visibleLibrary(type: .image)
        if branches.count == 1 {
            let only = branches[0]
            filter.lensModel = only.lensModel
            filter.model = only.model
            filter.originalFileName = only.originalFileName
        } else {
            filter.or = branches
        }
        return filter
    }
}
