import Foundation

/// Client for Immich's Sync Stream API (`POST /sync/stream`).
/// Uses session token auth (API keys rejected) and parses NDJSON responses
/// for checkpoint-based resumable synchronization.
///
/// Ack protocol (server-side checkpoints):
///   - GET  /api/sync/ack  → load existing checkpoints (server remembers them)
///   - POST /api/sync/stream → body: { "types": [...] }  (NO "since" field)
///   - POST /api/sync/ack  → body: { "acks": ["<ack_string>", ...] }

/// Ein verarbeitungsfertiger Ausschnitt des Sync-Streams — nach Nutzlast-Typ
/// vorsortiert, in Stream-Reihenfolge innerhalb jeder Liste.
struct SyncStreamBatch: Sendable {
    let upserted: [SyncAsset]
    let deleted: [String]
    let exifs: [SyncAssetExif]
    /// Bearbeitungen (Drehen, Beschnitt, Spiegeln) aus `AssetEditsV1`.
    var edits: [SyncAssetEditV1] = []
    /// IDs entfernter Bearbeitungen (`AssetEditDeleteV1`).
    var editDeletes: [String] = []
}

/// Zähler über den ganzen Lauf — für Statuszeile und Log.
struct SyncStreamRunStats: Sendable {
    var upserts = 0
    var deletes = 0
    var exifs = 0
    var edits = 0
}

final class SyncStreamClient: Sendable {
    private let baseURL: URL
    private let sessionToken: String
    private let session: URLSession

    /// - Parameter sessionConfiguration: Basis-Configuration für die URLSession
    init(baseURL: URL, sessionToken: String, sessionConfiguration: URLSessionConfiguration = .default) {
        self.baseURL = baseURL
        self.sessionToken = sessionToken

        let config = sessionConfiguration.copy() as! URLSessionConfiguration
        config.timeoutIntervalForRequest = 120  // Streaming can be slow for large datasets
        self.session = URLSession.mitSichererWeiterleitung(config)
    }

    // MARK: - Public API

    /// Streamt den Sync-Endpunkt zeilenweise und verarbeitet in Batches.
    ///
    /// Warum nicht mehr „alles laden, dann parsen": Beim Erstlauf eines neuen
    /// Typs (AssetExifsV1 ohne Checkpoint) spielt der Server den ganzen Bestand
    /// aus — sechsstellige Zeilenzahlen. Am Stück gepuffert wäre das
    /// Alles-oder-nichts: Abbruch mittendrin, Checkpoint unverändert, kompletter
    /// Replay. Batchweise wandert der Checkpoint mit; ein Neustart setzt dort
    /// fort, wo der letzte geackte Batch endete.
    ///
    /// Acks gehen nach jedem erfolgreichen `onBatch` raus. Wirft der Callback,
    /// bleibt der Batch unquittiert und der Fehler propagiert — die Einträge
    /// kommen beim nächsten Lauf erneut.
    @discardableResult
    func sync(
        types: [String],
        batchSize: Int = 5000,
        onBatch: (SyncStreamBatch) async throws -> Void
    ) async throws -> SyncStreamRunStats {
        let url = baseURL.appending(path: "api/sync/stream")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["types": types])

        let (bytes, response) = try await session.bytes(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw SyncStreamError.invalidResponse
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 403 { throw SyncStreamError.authRequired }
            var preview = Data()
            for try await byte in bytes.prefix(200) { preview.append(byte) }
            throw SyncStreamError.httpError(http.statusCode, String(data: preview, encoding: .utf8) ?? "n/a")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var stats = SyncStreamRunStats()
        var frozenTypes = Set<String>()

        // Akkumulatoren des laufenden Batches. `entries`/`consumed` laufen
        // parallel — Index i beschreibt denselben Stream-Eintrag.
        var entries: [SyncStreamEntry] = []
        var consumed: [Bool] = []
        var upserted: [SyncAsset] = []
        var deleted: [String] = []
        var exifs: [SyncAssetExif] = []
        var edits: [SyncAssetEditV1] = []
        var editDeletes: [String] = []

        func flush() async throws {
            guard !entries.isEmpty else { return }
            try await onBatch(SyncStreamBatch(
                upserted: upserted, deleted: deleted, exifs: exifs,
                edits: edits, editDeletes: editDeletes))
            let acks = Self.latestAcksPerType(
                in: entries, consumed: consumed, frozenTypes: &frozenTypes)
            try await sendAcks(acks)
            stats.upserts += upserted.count
            stats.deletes += deleted.count
            stats.exifs += exifs.count
            stats.edits += edits.count + editDeletes.count
            entries.removeAll(keepingCapacity: true)
            consumed.removeAll(keepingCapacity: true)
            upserted.removeAll(keepingCapacity: true)
            deleted.removeAll(keepingCapacity: true)
            exifs.removeAll(keepingCapacity: true)
            edits.removeAll(keepingCapacity: true)
            editDeletes.removeAll(keepingCapacity: true)
        }

        for try await line in bytes.lines {
            guard !line.isEmpty else { continue }
            // Eine syntaktisch kaputte Zeile trägt keinen lesbaren Ack — sie wird
            // wie bisher (parseNDJSON) übersprungen und friert nichts ein.
            guard let entry = try? decoder.decode(SyncStreamEntry.self, from: Data(line.utf8)) else { continue }

            switch entry.type {
            case "AssetV1", "AssetV2":
                if let asset = entry.decodeData(as: SyncAsset.self) {
                    upserted.append(asset)
                    consumed.append(true)
                } else {
                    consumed.append(false)
                }
            case "AssetDeleteV1":
                if let del = entry.decodeData(as: SyncAssetDelete.self) {
                    deleted.append(del.assetId)
                    consumed.append(true)
                } else {
                    consumed.append(false)
                }
            case "AssetExifV1":
                if let exif = entry.decodeData(as: SyncAssetExif.self) {
                    exifs.append(exif)
                    consumed.append(true)
                } else {
                    consumed.append(false)
                }
            case "AssetEditV1":
                if let edit = entry.decodeData(as: SyncAssetEditV1.self) {
                    edits.append(edit)
                    consumed.append(true)
                } else {
                    consumed.append(false)
                }
            case "AssetEditDeleteV1":
                if let del = entry.decodeData(as: SyncAssetEditDeleteV1.self) {
                    editDeletes.append(del.editId)
                    consumed.append(true)
                } else {
                    consumed.append(false)
                }
            default:
                // SyncAckV1 / SyncCompleteV1 / alles Weitere trägt nur seinen Ack.
                consumed.append(true)
            }
            entries.append(entry)

            if entries.count >= batchSize {
                try await flush()
            }
        }
        try await flush()
        return stats
    }

    /// Der Server hält Checkpoints pro (Session, Typ) und überschreibt beim
    /// Ack — von mehreren Acks desselben Typs überlebt nur der letzte. Der
    /// Stream kommt aufsteigend nach `updateId`, also ist der letzte Ack eines
    /// Typs der neueste Checkpoint. Alle übrigen wären reiner Ballast im Body.
    ///
    /// Ack-Format: `type|updateId[|extraId]` — der Typ ist der Teil vor dem
    /// ersten `|`.
    ///
    /// - Parameter consumed: Für jeden Eintrag, ob seine Nutzlast verwertet wurde.
    ///   Leer heißt „alles verwertet" — dann verhält sich die Funktion wie zuvor.
    ///
    ///   Ein nicht verwerteter Eintrag **friert seinen Ack-Typ ein**: Ab da wird für
    ///   diesen Typ kein neuerer Ack mehr gemeldet. Sonst schöbe der Checkpoint über
    ///   eine Änderung hinweg, die nur im Log als „Failed to decode" steht — der
    ///   Server hielte sie für zugestellt und schickte sie nie wieder. Ein nicht
    ///   gesetzter Checkpoint kostet dagegen nur eine Wiederholung beim nächsten
    ///   Lauf; deshalb bis zum **letzten lückenlos verwerteten** Eintrag quittieren
    ///   und nicht bis zum letzten geglückten.
    ///
    /// - Parameter frozenTypes: Vom Aufrufer gehaltenes Freeze-Set, das über
    ///   Batch-Grenzen hinweg bestehen bleibt. Der Aufrufer verantwortet seinen
    ///   ganzen Lauf lang (von Task 3 an: über mehrere Batches).
    static func latestAcksPerType(
        in entries: [SyncStreamEntry],
        consumed: [Bool] = [],
        frozenTypes: inout Set<String>
    ) -> [String] {
        var latestByType: [String: String] = [:]
        var typeOrder: [String] = []

        for (index, entry) in entries.enumerated() {
            guard let ack = entry.ack else { continue }
            let ackType = String(ack.prefix(while: { $0 != "|" }))

            let wasConsumed = index < consumed.count ? consumed[index] : true
            guard wasConsumed else {
                frozenTypes.insert(ackType)
                continue
            }
            guard !frozenTypes.contains(ackType) else { continue }

            if latestByType.updateValue(ack, forKey: ackType) == nil {
                typeOrder.append(ackType)
            }
        }

        return typeOrder.compactMap { latestByType[$0] }
    }

    /// Ein-Batch-Fassung: frisches Freeze-Set, Verhalten wie vor der Batch-API.
    static func latestAcksPerType(in entries: [SyncStreamEntry], consumed: [Bool] = []) -> [String] {
        var frozen = Set<String>()
        return latestAcksPerType(in: entries, consumed: consumed, frozenTypes: &frozen)
    }

    /// Send batch acknowledgements to the server.
    /// Body format: `{ "acks": ["<ack_string>", ...] }`
    func sendAcks(_ acks: [String]) async throws {
        guard !acks.isEmpty else { return }
        let url = baseURL.appending(path: "api/sync/ack")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")

        let body: [String: [String]] = ["acks": acks]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...204).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw SyncStreamError.ackFailed(code)
        }
    }

    /// Löscht Server-Checkpoints gezielt je Entity-Typ (`DELETE /api/sync/ack`).
    ///
    /// Der nächste Stream-Sync spielt die betroffenen Typen komplett neu aus —
    /// das ist der Hebel für den einmaligen Checksum-Backfill: Checkpoint für
    /// `AssetV2` weg, Replay füllt die neue Grid-Spalte, die EXIF-Checkpoints
    /// bleiben unangetastet. `AssetDeleteV1` bewusst nicht dabei — ein Tombstone-
    /// Replay flutet `changedIds` ohne Diff (Cache-/Notification-Sturm) und
    /// bringt für die Checksum-Spalte nichts.
    func deleteAcks(types: [String]) async throws {
        guard !types.isEmpty else { return }
        let url = baseURL.appending(path: "api/sync/ack")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["types": types])

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...204).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw SyncStreamError.ackFailed(code)
        }
    }
}

// MARK: - Models

/// A single entry from the NDJSON sync stream.
struct SyncStreamEntry: Decodable {
    let type: String
    let data: AnyCodable?
    let ack: String?
    let syncTypeHint: String?

    private enum CodingKeys: String, CodingKey {
        case type
        case data
        case ack
        case syncTypeHint = "syncType"
    }

    func decodeData<T: Decodable>(as: T.Type) -> T? {
        guard let rawData = data?.value else { return nil }
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: rawData)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(T.self, from: jsonData)
        } catch {
            AppLogger.syncStream.error("Failed to decode \(type) data: \(error)")
            return nil
        }
    }
}

/// Minimal wrapper for arbitrary JSON values.
struct AnyCodable: Decodable {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let number = try? container.decode(Double.self) {
            value = number
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if container.decodeNil() {
            value = NSNull()
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported type")
        }
    }
}

struct SyncAsset: Decodable {
    let id: String
    let ownerId: String
    let originalFileName: String
    let thumbhash: String?
    let checksum: String
    let fileCreatedAt: String?
    let fileModifiedAt: String?
    let localDateTime: String?
    let duration: String?
    let type: String              // "IMAGE" or "VIDEO"
    let deletedAt: String?
    let isFavorite: Bool
    let visibility: String?       // "timeline", "archive", "hidden"
    let livePhotoVideoId: String?
    let stackId: String?

    enum CodingKeys: String, CodingKey {
        case id, ownerId, originalFileName, thumbhash, checksum, fileCreatedAt, fileModifiedAt, localDateTime, duration, type, deletedAt, isFavorite, visibility, livePhotoVideoId, stackId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        ownerId = try c.decode(String.self, forKey: .ownerId)
        originalFileName = try c.decode(String.self, forKey: .originalFileName)
        thumbhash = try c.decodeIfPresent(String.self, forKey: .thumbhash)
        checksum = try c.decode(String.self, forKey: .checksum)
        fileCreatedAt = try c.decodeIfPresent(String.self, forKey: .fileCreatedAt)
        fileModifiedAt = try c.decodeIfPresent(String.self, forKey: .fileModifiedAt)
        localDateTime = try c.decodeIfPresent(String.self, forKey: .localDateTime)
        type = try c.decode(String.self, forKey: .type)
        deletedAt = try c.decodeIfPresent(String.self, forKey: .deletedAt)
        isFavorite = try c.decode(Bool.self, forKey: .isFavorite)
        visibility = try c.decodeIfPresent(String.self, forKey: .visibility)
        livePhotoVideoId = try c.decodeIfPresent(String.self, forKey: .livePhotoVideoId)
        stackId = try c.decodeIfPresent(String.self, forKey: .stackId)

        // AssetV1 schickt duration als String ("HH:MM:SS.mmm"), AssetV2 als
        // Millisekunden-Int (nullable) — hier auf dasselbe String-Format gebracht.
        if let strVal = try? c.decodeIfPresent(String.self, forKey: .duration) {
            duration = strVal
        } else if let doubleVal = try? c.decodeIfPresent(Double.self, forKey: .duration) {
            duration = Asset.durationString(fromMilliseconds: doubleVal)
        } else if let intVal = try? c.decodeIfPresent(Int.self, forKey: .duration) {
            duration = Asset.durationString(fromMilliseconds: Double(intVal))
        } else {
            duration = nil
        }
    }
}

/// Eine EXIF-Zeile aus dem Sync-Stream (Entry-Typ `AssetExifV1`, Request-Typ
/// `AssetExifsV1`). Nur die Felder, die `CachedAsset` und der Grid-Index führen —
/// der Server schickt mehr (description, timeZone, rating, …), das synthetisierte
/// Decodable ignoriert Unbekanntes.
///
/// `orientation` gehörte lange zu diesem Unbekannten. Es fehlte damit genau die
/// Angabe, die aus `exifImageWidth`/`Height` erst die **angezeigten** Maße macht:
/// Ein hochkant fotografiertes iPhone-Bild liegt im Sensor quer und trägt
/// `orientation = 6`. Ohne den Wert legte das Raster für 67 % der Fotos ein
/// Kästchen der falschen Form an (siehe ``ExifOrientation``).
///
/// `iso` ist serverseitig ein Int; hier Double, weil `CachedAsset.iso` Double ist
/// und JSON-Zahlen verlustfrei so dekodieren.
struct SyncAssetExif: Decodable, Sendable {
    let assetId: String
    let city: String?
    let state: String?
    let country: String?
    let latitude: Double?
    let longitude: Double?
    let make: String?
    let model: String?
    let lensModel: String?
    let fNumber: Double?
    let focalLength: Double?
    let iso: Double?
    let exposureTime: String?
    let fileSizeInByte: Int?
    let exifImageWidth: Int?
    let exifImageHeight: Int?
    /// EXIF-Orientierung 1–8. Immich liefert sie als Zahl **oder** als Zeichenkette,
    /// je nachdem, was im Bild stand — deshalb von Hand dekodiert.
    let orientation: Int?

    enum CodingKeys: String, CodingKey {
        case assetId, city, state, country, latitude, longitude, make, model, lensModel
        case fNumber, focalLength, iso, exposureTime, fileSizeInByte
        case exifImageWidth, exifImageHeight, orientation
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        assetId = try c.decode(String.self, forKey: .assetId)
        city = try c.decodeIfPresent(String.self, forKey: .city)
        state = try c.decodeIfPresent(String.self, forKey: .state)
        country = try c.decodeIfPresent(String.self, forKey: .country)
        latitude = try c.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try c.decodeIfPresent(Double.self, forKey: .longitude)
        make = try c.decodeIfPresent(String.self, forKey: .make)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        lensModel = try c.decodeIfPresent(String.self, forKey: .lensModel)
        fNumber = try c.decodeIfPresent(Double.self, forKey: .fNumber)
        focalLength = try c.decodeIfPresent(Double.self, forKey: .focalLength)
        iso = try c.decodeIfPresent(Double.self, forKey: .iso)
        exposureTime = try c.decodeIfPresent(String.self, forKey: .exposureTime)
        fileSizeInByte = try c.decodeIfPresent(Int.self, forKey: .fileSizeInByte)
        exifImageWidth = try c.decodeIfPresent(Int.self, forKey: .exifImageWidth)
        exifImageHeight = try c.decodeIfPresent(Int.self, forKey: .exifImageHeight)

        if let zahl = try? c.decodeIfPresent(Int.self, forKey: .orientation) {
            orientation = zahl
        } else if let text = try? c.decodeIfPresent(String.self, forKey: .orientation) {
            orientation = Int(text.trimmingCharacters(in: .whitespaces))
        } else {
            orientation = nil
        }
    }

    /// Ausgeschrieben, weil der eigene `init(from:)` den synthetisierten
    /// Memberwise-Initialisierer verdrängt. Die Vorgaben halten bestehende
    /// Aufrufstellen unverändert; `orientation` ist neu und deshalb optional.
    init(
        assetId: String,
        city: String? = nil,
        state: String? = nil,
        country: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        make: String? = nil,
        model: String? = nil,
        lensModel: String? = nil,
        fNumber: Double? = nil,
        focalLength: Double? = nil,
        iso: Double? = nil,
        exposureTime: String? = nil,
        fileSizeInByte: Int? = nil,
        exifImageWidth: Int? = nil,
        exifImageHeight: Int? = nil,
        orientation: Int? = nil
    ) {
        self.assetId = assetId
        self.city = city
        self.state = state
        self.country = country
        self.latitude = latitude
        self.longitude = longitude
        self.make = make
        self.model = model
        self.lensModel = lensModel
        self.fNumber = fNumber
        self.focalLength = focalLength
        self.iso = iso
        self.exposureTime = exposureTime
        self.fileSizeInByte = fileSizeInByte
        self.exifImageWidth = exifImageWidth
        self.exifImageHeight = exifImageHeight
        self.orientation = orientation
    }
}

/// Asset delete event from the sync stream.
struct SyncAssetDelete: Decodable {
    let assetId: String
}

/// Eine Bearbeitung aus `AssetEditsV1` (`SyncAssetEditV1`). Der Server schickt
/// `{id, assetId, action, parameters, sequence}`; gebraucht wird nur, *dass* ein Asset
/// bearbeitet ist. Nur `id` und `assetId` sind Pflicht — ein unerwartetes anderes Feld
/// darf den Ack nicht einfrieren.
struct SyncAssetEditV1: Decodable, Sendable, Equatable {
    let id: String
    let assetId: String
    /// `crop`, `rotate` oder `mirror` — nur fürs Protokoll.
    let action: String?
}

/// Eine entfernte Bearbeitung (`SyncAssetEditDeleteV1`).
struct SyncAssetEditDeleteV1: Decodable {
    let editId: String
}

// MARK: - Errors

enum SyncStreamError: LocalizedError {
    case invalidResponse
    case authRequired
    case httpError(Int, String)
    case ackFailed(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid response from sync stream"
        case .authRequired: return "Session token required for sync stream (API keys not supported)"
        case .httpError(let code, let msg): return "Sync stream HTTP \(code): \(msg)"
        case .ackFailed(let code): return "Sync ack failed with HTTP \(code)"
        }
    }
}
