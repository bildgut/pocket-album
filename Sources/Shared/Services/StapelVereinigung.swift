import Foundation

/// Stapelt eine Auswahl und nimmt bestehende Stapel dabei mit.
///
/// Liegt ein ausgewähltes Foto schon in einem Stapel, wird dieser Stapel
/// aufgelöst und **alle** seine Mitglieder kommen in den neuen — sonst bliebe
/// beim Stapeln eines RAW+JPEG-Paars mit einem dritten Foto die RAW-Hälfte
/// allein zurück, unsichtbar, weil sie im Index noch als Kind markiert ist.
///
/// Kontextmenü und Tastaturbefehl (`PhotoGridViewModel.stackAssets`) gehen
/// beide hier durch. Die Server-Aufrufe kommen als Closures herein, damit die
/// Tests ohne Netz auskommen.
enum StapelVereinigung {

    struct Plan: Equatable, Sendable {
        /// Alle Mitglieder des neuen Stapels: erst die Auswahl in ihrer
        /// Reihenfolge, dann die aus aufgelösten Stapeln hinzugekommenen.
        let ids: [String]
        /// Stapel, die vorher aufgelöst werden — sortiert, damit der Ablauf
        /// nicht von der Reihenfolge eines `Set` abhängt.
        let aufzuloesen: [String]
    }

    struct Ergebnis: Equatable, Sendable {
        let stackId: String
        let primaryId: String
        let ids: [String]
        let badge: String?
    }

    /// Rechnet aus, welche Stapel aufgelöst werden und wer in den neuen kommt.
    static func plane(
        auswahl: [String],
        stapelVon: (String) -> String?,
        mitglieder: (String) -> [String]
    ) -> Plan {
        var ids: [String] = []
        var gesehen = Set<String>()
        func nimm(_ id: String) {
            if gesehen.insert(id).inserted { ids.append(id) }
        }
        auswahl.forEach(nimm)

        var stapel = Set<String>()
        for id in auswahl {
            guard let stackId = stapelVon(id), !stackId.isEmpty else { continue }
            if stapel.insert(stackId).inserted {
                mitglieder(stackId).forEach(nimm)
            }
        }
        return Plan(ids: ids, aufzuloesen: stapel.sorted())
    }

    /// Das Titelbild: die bevorzugte ID (das angeklickte Foto), sofern sie ein
    /// Standbild ohne RAW ist; sonst das erste solche in Plan-Reihenfolge;
    /// gibt es keins, die bevorzugte ID oder die erste.
    static func titelbild(ids: [String], assets: [Asset], bevorzugt: String?) -> String {
        let nachId = Dictionary(assets.map { ($0.id, $0) }, uniquingKeysWith: { erstes, _ in erstes })
        func taugt(_ id: String) -> Bool {
            guard let asset = nachId[id] else { return false }
            return !asset.isVideo && !MediaType.isRawFile(fileName: asset.originalFileName, path: asset.originalPath)
        }
        if let bevorzugt, ids.contains(bevorzugt), taugt(bevorzugt) { return bevorzugt }
        if let erstes = ids.first(where: taugt) { return erstes }
        if let bevorzugt, ids.contains(bevorzugt) { return bevorzugt }
        return ids[0]
    }

    /// Löst die betroffenen Stapel auf, legt den neuen an und trägt ihn sofort
    /// in den Index ein — das Raster muss nicht auf den nächsten Sync warten.
    ///
    /// Scheitert das Auflösen eines alten Stapels, bricht der Ablauf ab, bevor
    /// ein neuer angelegt wird; bereits aufgelöste Stapel sind dann auch im
    /// Index aufgelöst, damit er dem Server entspricht.
    static func stapele(
        auswahl: [String],
        bevorzugt: String? = nil,
        bekannteAssets: [Asset] = [],
        index: GridIndexStore,
        loeseAuf: (String) async throws -> Void,
        erstelle: (_ primaryId: String, _ kinder: [String]) async throws -> String
    ) async throws -> Ergebnis? {
        let plan = plane(
            auswahl: auswahl,
            stapelVon: { index.stackId(forAssetId: $0) },
            mitglieder: { index.loadStackAssets(stackId: $0).map(\.id) }
        )
        guard plan.ids.count >= 2 else { return nil }

        // Vor dem Auflösen laden: Danach sind die Kinder zwar wieder sichtbar,
        // aber so hängt das Ergebnis nicht an dieser Reihenfolge.
        let bekannt = bekannteAssets.filter { plan.ids.contains($0.id) }
        let fehlend = plan.ids.filter { id in !bekannt.contains { $0.id == id } }
        let assets = bekannt + index.loadVisible(ids: fehlend)

        for stackId in plan.aufzuloesen {
            try await loeseAuf(stackId)
            index.removeStack(stackId: stackId)
        }

        let primaryId = titelbild(ids: plan.ids, assets: assets, bevorzugt: bevorzugt)
        let kinder = plan.ids.filter { $0 != primaryId }
        let stackId = try await erstelle(primaryId, kinder)

        // Fehlt ein Mitglied im Index (archiviert, noch nicht synchronisiert),
        // zählt das Abzeichen trotzdem alle.
        let badge = assets.count == plan.ids.count
            ? GridIndexStore.badgeText(for: assets, primaryId: primaryId)
            : "\(plan.ids.count)"
        index.updateStack(primaryId: primaryId, childIds: kinder, stackId: stackId, badgeText: badge)
        return Ergebnis(stackId: stackId, primaryId: primaryId, ids: plan.ids, badge: badge)
    }
}
