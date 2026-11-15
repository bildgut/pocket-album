import Foundation

/// Verworfene Fotos aus „Fotos prüfen", deren Löschen in Apple Fotos noch aussteht.
///
/// Verworfene werden **beim Start** des Laufs dauerhaft ignoriert, gelöscht wird aber
/// erst **an seinem Ende** (vollständig oder angehalten). Endete die App dazwischen,
/// standen sie danach nirgends mehr: Die Vorschau zeigt Ignoriertes nicht, und die
/// Löschabsicht lebte nur im Speicher. Diese Vormerkung überdauert den Neustart; der
/// nächste Lauf aus dem Dialog holt das Löschen nach. Der Stand zur Zeit der Vorschau
/// reist mit — `ApplePhotoVerwerfUrteil` lässt ein inzwischen bearbeitetes Foto stehen.
struct ApplePhotosVerwerfVormerkung {
    static let schluessel = "applePhotos.verwerfen.ausstehend.v1"

    let defaults: UserDefaults

    func ausstehend() -> [ApplePhotoVerwerfKandidat] {
        guard let daten = defaults.data(forKey: Self.schluessel),
              let liste = try? JSONDecoder().decode([ApplePhotoVerwerfKandidat].self, from: daten)
        else { return [] }
        return liste
    }

    func merke(_ neue: [ApplePhotoVerwerfKandidat]) {
        guard !neue.isEmpty else { return }
        schreibe(Self.vereinigt(ausstehend(), neue))
    }

    /// Nach dem Löschversuch — oder wenn der Nutzer ein Foto wieder freigibt: Wer es
    /// zurückholt, will es nicht mehr gelöscht haben.
    func entferne(_ localIdentifiers: Set<String>) {
        guard !localIdentifiers.isEmpty else { return }
        let rest = ausstehend().filter { !localIdentifiers.contains($0.localIdentifier) }
        schreibe(rest)
    }

    func leere() {
        defaults.removeObject(forKey: Self.schluessel)
    }

    /// Je Foto ein Eintrag; der neuere Vorschau-Stand gewinnt.
    static func vereinigt(
        _ alt: [ApplePhotoVerwerfKandidat],
        _ neu: [ApplePhotoVerwerfKandidat]
    ) -> [ApplePhotoVerwerfKandidat] {
        let neueIds = Set(neu.map(\.localIdentifier))
        var gesehen = Set<String>()
        return (alt.filter { !neueIds.contains($0.localIdentifier) } + neu)
            .filter { gesehen.insert($0.localIdentifier).inserted }
    }

    private func schreibe(_ liste: [ApplePhotoVerwerfKandidat]) {
        if liste.isEmpty {
            defaults.removeObject(forKey: Self.schluessel)
        } else if let daten = try? JSONEncoder().encode(liste) {
            defaults.set(daten, forKey: Self.schluessel)
        }
    }
}

/// Was ein Lauf aus „Fotos prüfen" zurückmeldet.
struct ApplePhotosLaufErgebnis: Equatable {
    /// Vom Nutzer angehalten — der Rest erscheint beim nächsten Prüfen wieder.
    let angehalten: Bool
    let löschung: ApplePhotoDeletionOutcome?
}
