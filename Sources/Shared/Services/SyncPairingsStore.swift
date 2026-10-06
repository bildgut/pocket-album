import Foundation
import SwiftData

// MARK: - Codable record (JSON-Repräsentation eines SyncPairing)

struct SyncPairingRecord: Codable {
    var id: String
    var appleAlbumLocalIdentifier: String
    var appleAlbumName: String
    var immichAlbumId: String
    var immichAlbumName: String
    var lastSyncedAt: Date?
    var lastSyncedUploaded: Int
    var lastSyncedMapped: Int
    var lastSyncedSkipped: Int

    init(from pairing: SyncPairing) {
        id                       = pairing.id
        appleAlbumLocalIdentifier = pairing.appleAlbumLocalIdentifier
        appleAlbumName           = pairing.appleAlbumName
        immichAlbumId            = pairing.immichAlbumId
        immichAlbumName          = pairing.immichAlbumName
        lastSyncedAt             = pairing.lastSyncedAt
        lastSyncedUploaded       = pairing.lastSyncedUploaded
        lastSyncedMapped         = pairing.lastSyncedMapped
        lastSyncedSkipped        = pairing.lastSyncedSkipped
    }
}

// MARK: - SyncPairingsStore

/// Hält einen JSON-Sidecar (`sync-pairings.json`) in
/// `~/Library/Application Support/ImmichMac/` aktuell.
///
/// **Zweck:** Falls der SwiftData-Store durch eine fehlgeschlagene Migration oder
/// einen Entwickler-Reset gelöscht wird, bleiben die Album-Verknüpfungen erhalten
/// und werden beim nächsten App-Start automatisch wiederhergestellt.
///
/// **Verwendung:**
/// - Nach jedem Insert/Update/Delete eines SyncPairing:
///   `SyncPairingsStore.shared.export(allCurrentPairings)`
/// - Beim App-Start, nachdem der Container initialisiert wurde:
///   `SyncPairingsStore.shared.importIfNeeded(into: ctx)` auf dem MainActor aufrufen.
final class SyncPairingsStore: @unchecked Sendable {

    static let shared = SyncPairingsStore()
    private init() {}

    // MARK: - Path

    static let fileName = "sync-pairings.json"

    /// Liegt unter ``AppEnvironment/supportDirectory``, damit Testläufe (TEST_HOST =
    /// ImmichMac.app, die Window-Szene läuft mit) nicht die echte Nutzerdatei anfassen.
    var jsonURL: URL {
        AppEnvironment.supportDirectory.appending(path: Self.fileName)
    }

    // MARK: - Export (write)

    /// Persistiert alle aktuellen Pairings in den JSON-Sidecar.
    /// Darf auf jedem Thread aufgerufen werden; der Schreibvorgang ist synchron aber schnell.
    func export(_ pairings: [SyncPairing]) {
        let records = pairings.map { SyncPairingRecord(from: $0) }
        let url = jsonURL
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(records)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            AppLogger.app.debug("SyncPairingsStore: \(records.count) Pairings in JSON gesichert.")
        } catch {
            AppLogger.app.error("SyncPairingsStore: Export nach \(url.path) fehlgeschlagen: \(error)")
        }
    }

    // MARK: - Import (read + restore)

    /// Liest den JSON-Sidecar und importiert fehlende Pairings in den übergebenen `ModelContext`.
    ///
    /// Eingefügt wird, was im Store fehlt — verglichen über
    /// `appleAlbumLocalIdentifier`. Zählstände werden **nicht** verglichen: Der Fall
    /// „Store hat mehr als der Sidecar" braucht keine Sonderbehandlung, weil dann
    /// schlicht nichts fehlt und die Funktion früh zurückkehrt.
    ///
    /// (Hier stand zuvor „Wird **nur** ausgeführt wenn der Store weniger Pairings
    /// enthält als der JSON" — einen solchen Vergleich gibt es im Code nicht.)
    ///
    /// - Returns: Anzahl wiederhergestellter Pairings.
    @discardableResult
    @MainActor
    func importIfNeeded(into ctx: ModelContext) -> Int {
        guard FileManager.default.fileExists(atPath: jsonURL.path) else { return 0 }

        let records: [SyncPairingRecord]
        do {
            let data = try Data(contentsOf: jsonURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            records = try decoder.decode([SyncPairingRecord].self, from: data)
        } catch {
            AppLogger.app.error("SyncPairingsStore: JSON konnte nicht gelesen werden: \(error)")
            return 0
        }

        guard !records.isEmpty else { return 0 }

        // Vorhandene Pairings im Store laden
        let existing = (try? ctx.fetch(FetchDescriptor<SyncPairing>())) ?? []
        let existingIds = Set(existing.map { $0.appleAlbumLocalIdentifier })

        let missing = records.filter { !existingIds.contains($0.appleAlbumLocalIdentifier) }
        guard !missing.isEmpty else {
            AppLogger.app.debug("SyncPairingsStore: Alle \(records.count) Pairings bereits im Store vorhanden.")
            return 0
        }

        for r in missing {
            let pairing = SyncPairing(
                id: r.id,
                appleAlbumLocalIdentifier: r.appleAlbumLocalIdentifier,
                appleAlbumName: r.appleAlbumName,
                immichAlbumId: r.immichAlbumId,
                immichAlbumName: r.immichAlbumName
            )
            pairing.lastSyncedAt       = r.lastSyncedAt
            pairing.lastSyncedUploaded = r.lastSyncedUploaded
            pairing.lastSyncedMapped   = r.lastSyncedMapped
            pairing.lastSyncedSkipped  = r.lastSyncedSkipped
            ctx.insert(pairing)
        }

        do {
            try ctx.save()
            AppLogger.app.info("SyncPairingsStore: \(missing.count) Pairings aus JSON-Sidecar wiederhergestellt.")
        } catch {
            AppLogger.app.error("SyncPairingsStore: Import-Save fehlgeschlagen: \(error)")
            return 0
        }

        return missing.count
    }
}
