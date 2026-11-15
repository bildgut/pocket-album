import Foundation

/// Was „Fertig“ von der Ablage braucht — als Protokoll, damit der Ablauf ohne Netz
/// prüfbar ist (`BearbeitungSpeichern`).
@MainActor
protocol BearbeitungsAblageProtokoll {
    func eintrag(fuer originalId: String) async throws -> BearbeitungsEintrag?
    func verweis(von assetId: String) async throws -> FassungsVerweis?
    func schreibe(_ e: BearbeitungsEintrag, an originalId: String) async -> Bool
    func schreibeVerweis(_ v: FassungsVerweis, an fassungId: String) async -> Bool
    func loescheEintrag(an originalId: String) async
    func reicheNach() async
}

/// Liest und schreibt die Bearbeitungseinstellungen am Immich-Server
/// (`/api/assets/{id}/metadata`, Schlüssel in ``BearbeitungsEintrag`` und
/// ``FassungsVerweis``).
///
/// Scheitert ein Schreiben, wird der Eintrag in der ``BearbeitungsVormerkung``
/// festgehalten: Die Fassung ist dann schon hochgeladen, und ein Netzfehler darf die
/// Einstellungen nicht kosten. Beim Lesen gewinnt die Vormerkung — sie ist neuer als
/// alles, was der Server haben kann.
@MainActor
struct BearbeitungsAblage: BearbeitungsAblageProtokoll {
    let apiClient: ImmichAPIClient
    let vormerkung: BearbeitungsVormerkung

    init(apiClient: ImmichAPIClient, vormerkung: BearbeitungsVormerkung) {
        self.apiClient = apiClient
        self.vormerkung = vormerkung
    }

    func eintrag(fuer originalId: String) async throws -> BearbeitungsEintrag? {
        if let vorgemerkt = vormerkung.eintrag(fuer: originalId) { return vorgemerkt }
        guard let daten = try await apiClient.leseMetadatum(
            assetId: originalId, schluessel: BearbeitungsEintrag.schluessel
        ) else { return nil }
        return try BearbeitungJSON.decoder.decode(BearbeitungsEintrag.self, from: daten)
    }

    func verweis(von assetId: String) async throws -> FassungsVerweis? {
        if let vorgemerkt = vormerkung.verweis(von: assetId) { return vorgemerkt }
        guard let daten = try await apiClient.leseMetadatum(
            assetId: assetId, schluessel: FassungsVerweis.schluessel
        ) else { return nil }
        return try BearbeitungJSON.decoder.decode(FassungsVerweis.self, from: daten)
    }

    @discardableResult
    func schreibe(_ e: BearbeitungsEintrag, an originalId: String) async -> Bool {
        do {
            let daten = try BearbeitungJSON.encoder.encode(e)
            try await apiClient.schreibeMetadatum(
                assetId: originalId, schluessel: BearbeitungsEintrag.schluessel, wert: daten
            )
            vormerkung.vergissEintrag(fuer: originalId)
            return true
        } catch {
            AppLogger.api.warning("BearbeitungsAblage: Eintrag an \(originalId) vorgemerkt: \(error.localizedDescription)")
            vormerkung.merke(eintrag: e, fuer: originalId)
            return false
        }
    }

    @discardableResult
    func schreibeVerweis(_ v: FassungsVerweis, an fassungId: String) async -> Bool {
        do {
            let daten = try BearbeitungJSON.encoder.encode(v)
            try await apiClient.schreibeMetadatum(
                assetId: fassungId, schluessel: FassungsVerweis.schluessel, wert: daten
            )
            vormerkung.vergissVerweis(von: fassungId)
            return true
        } catch {
            AppLogger.api.warning("BearbeitungsAblage: Verweis an \(fassungId) vorgemerkt: \(error.localizedDescription)")
            vormerkung.merke(verweis: v, fuer: fassungId)
            return false
        }
    }

    /// Entfernt den Eintrag am Server und eine etwaige Vormerkung. Ein Fehlschlag am
    /// Server lässt einen Eintrag ohne Fassung zurück — harmlos, er beschreibt nur die
    /// letzten Regler.
    func loescheEintrag(an originalId: String) async {
        vormerkung.vergissEintrag(fuer: originalId)
        do {
            try await apiClient.loescheMetadatum(assetId: originalId, schluessel: BearbeitungsEintrag.schluessel)
        } catch {
            AppLogger.api.warning("BearbeitungsAblage: Eintrag an \(originalId) nicht gelöscht: \(error.localizedDescription)")
        }
    }

    func reicheNach() async {
        for posten in vormerkung.alle {
            switch posten {
            case .eintrag(let id, let e): await schreibe(e, an: id)
            case .verweis(let id, let v): await schreibeVerweis(v, an: id)
            }
        }
    }
}

/// Lokale Vormerkung nicht geschriebener Einträge, als JSON-Datei im
/// Support-Verzeichnis (nie `UserDefaults.standard`: Tests lenken
/// `AppEnvironment.supportDirectory` in Wegwerf-Pfade um).
@MainActor
final class BearbeitungsVormerkung {
    enum Posten: Equatable {
        case eintrag(String, BearbeitungsEintrag)
        case verweis(String, FassungsVerweis)
    }

    private struct Inhalt: Codable {
        var eintraege: [String: BearbeitungsEintrag] = [:]
        var verweise: [String: FassungsVerweis] = [:]
    }

    static let standardDatei = AppEnvironment.supportDirectory.appending(path: "bearbeitung_vormerkung.json")

    private let datei: URL
    private var inhalt: Inhalt

    init(datei: URL = BearbeitungsVormerkung.standardDatei) {
        self.datei = datei
        if let daten = try? Data(contentsOf: datei),
           let gelesen = try? BearbeitungJSON.decoder.decode(Inhalt.self, from: daten) {
            inhalt = gelesen
        } else {
            inhalt = Inhalt()
        }
    }

    var alle: [Posten] {
        inhalt.eintraege.sorted { $0.key < $1.key }.map { .eintrag($0.key, $0.value) }
            + inhalt.verweise.sorted { $0.key < $1.key }.map { .verweis($0.key, $0.value) }
    }

    func eintrag(fuer originalId: String) -> BearbeitungsEintrag? { inhalt.eintraege[originalId] }
    func verweis(von assetId: String) -> FassungsVerweis? { inhalt.verweise[assetId] }

    func merke(eintrag: BearbeitungsEintrag, fuer originalId: String) {
        inhalt.eintraege[originalId] = eintrag
        sichere()
    }

    func merke(verweis: FassungsVerweis, fuer fassungId: String) {
        inhalt.verweise[fassungId] = verweis
        sichere()
    }

    func vergissEintrag(fuer originalId: String) {
        guard inhalt.eintraege.removeValue(forKey: originalId) != nil else { return }
        sichere()
    }

    func vergissVerweis(von fassungId: String) {
        guard inhalt.verweise.removeValue(forKey: fassungId) != nil else { return }
        sichere()
    }

    private func sichere() {
        do {
            try BearbeitungJSON.encoder.encode(inhalt).write(to: datei, options: .atomic)
        } catch {
            AppLogger.app.error("BearbeitungsVormerkung: nicht gesichert: \(error.localizedDescription)")
        }
    }
}
