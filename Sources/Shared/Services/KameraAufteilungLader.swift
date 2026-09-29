import Foundation

/// Was das Blatt „Nach Kamera aufteilen" zum Anzeigen braucht.
struct KameraAufteilungStand: Equatable, Sendable {
    let gruppen: [KameraGruppe]
    let hauptkamera: String?
    let gemerkt: Set<String>
}

/// Liest Auswahl und Umfeld aus dem Rasterindex und setzt die Gruppen zusammen.
/// Läuft synchron auf den Lese-Queues des Index — Aufrufer aus der Oberfläche
/// starten ihn in einem `Task.detached`.
enum KameraAufteilungLader {
    static func lade(ids: [String], store: GridIndexStore, defaults: UserDefaults) -> KameraAufteilungStand? {
        guard let zeilen = store.kameraZeilen(ids: ids) else { return nil }

        var hauptkamera: String?
        if let fenster = KameraAufteilung.zeitfenster(zeilen) {
            guard let anzahlen = store.kameraAnzahlen(in: fenster) else { return nil }
            hauptkamera = KameraAufteilung.hauptkamera(anzahlen: anzahlen)
        }

        let gemerkt = KameraMerkliste.load(from: defaults)
        return KameraAufteilungStand(
            gruppen: KameraAufteilung.gruppen(zeilen: zeilen, hauptkamera: hauptkamera, gemerkt: gemerkt),
            hauptkamera: hauptkamera,
            gemerkt: gemerkt
        )
    }
}
