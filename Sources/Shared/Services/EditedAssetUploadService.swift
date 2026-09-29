import Foundation

/// Payload für einen "bearbeitetes Bild hochladen"-Aufruf.
///
/// Genau eines von `data` / `fileURL` ist gesetzt: `data` für Editoren, die das
/// Ergebnis im Speicher halten (Straighten, Anpassungen), `fileURL` für Pfade, die
/// schon eine Datei auf der Platte haben (externer Editor).
struct EditedUpload {
    let data: Data?
    let fileURL: URL?
    let fileName: String
    let fileCreatedAt: String
    let fileModifiedAt: String
}

/// Konsolidiert die drei zuvor fast identischen "bearbeitetes Bild hochladen"-Pfade
/// (`PhotoStraightenViewModel`, `ImageAdjustmentsViewModel`, `ExternalEditorService`)
/// zu einer gemeinsamen Implementierung. Reiner Refactor — das Verhalten ist 1:1 aus
/// den drei Originalen übernommen, nur die Beschaffung der Quelldatei ist neu (siehe
/// unten).
enum EditedAssetUploadService {

    // MARK: - Öffentliche API

    /// Lädt die bearbeitete Datei als neues Asset hoch. Original bleibt unangetastet.
    /// - Returns: ID des neuen Assets.
    static func upload(_ u: EditedUpload, apiClient: ImmichAPIClient) async throws -> String {
        let (sourceURL, cleanupSource) = try sourceFileURL(for: u)
        defer { cleanupSource() }
        return try await uploadFile(sourceURL, upload: u, apiClient: apiClient)
    }

    /// Lädt hoch und stapelt das neue Asset auf `primaryAssetId`.
    ///
    /// Stack-Erstellung: Fehler ist nicht fatal (nur Log) — bleibt das Original
    /// bestehen, sonst lägen zwei fast gleiche Fotos lose nebeneinander in der
    /// Timeline. Ein gescheiterter Stack-Aufruf ändert daran nichts Kritisches.
    ///
    /// - Parameter mitMetadatenVomOriginal: Überträgt Alben und Favoritenstern des
    ///   Originals auf die neue Fassung. Die Editier-Wege setzen das: Wer ein Foto
    ///   aus einem Album heraus zuschneidet und „Neues Foto erstellen" wählt, erwartet
    ///   den Zuschnitt im selben Album — vorher landete er in keinem, und das Album
    ///   zeigte weiter nur die unbeschnittene Fassung. Der Vorgabewert `false` hält
    ///   das Nachreichen von Apple-Photos-Originalen unverändert: Dort ist das neue
    ///   Asset keine Bearbeitung, sondern die fehlende Quelldatei.
    @discardableResult
    static func uploadAndStack(
        _ u: EditedUpload,
        primaryAssetId: String,
        mitMetadatenVomOriginal: Bool = false,
        apiClient: ImmichAPIClient
    ) async throws -> String {
        let newId = try await upload(u, apiClient: apiClient)
        do {
            _ = try await apiClient.createStack(primaryAssetId: primaryAssetId, childAssetIds: [newId])
            AppLogger.ui.info("EditedAssetUploadService: neues Asset \(newId) auf Original \(primaryAssetId) gestapelt")
        } catch {
            AppLogger.ui.warning("EditedAssetUploadService: Stapeln fehlgeschlagen: \(error)")
        }
        if mitMetadatenVomOriginal {
            await uebertrageMetadaten(von: primaryAssetId, auf: newId, apiClient: apiClient)
        }
        return newId
    }

    /// Überträgt Alben und Favoritenstern von einem Asset auf ein anderes.
    ///
    /// **Bewusst nach dem Upload und bewusst ohne `throw`** — anders als in
    /// ``uploadAndReplace(_:originalAsset:apiClient:)``. Dort muss das Lesen der
    /// Metadaten *vor* dem Upload gelingen und darf abbrechen, weil das Original
    /// danach in den Papierkorb wandert: Ein Fehlschlag kostete sonst die
    /// Albumzugehörigkeit des Fotos. Beim Stapeln bleibt das Original samt seinen
    /// Alben unangetastet, also wäre ein Abbruch der teurere Fehler — er würfe eine
    /// fertig hochgeladene Bearbeitung weg, um eine Zugehörigkeit zu retten, die noch
    /// da ist. Deshalb hier: melden, nicht scheitern.
    private static func uebertrageMetadaten(
        von originalId: String,
        auf neueId: String,
        apiClient: ImmichAPIClient
    ) async {
        do {
            let istFavorit = try await apiClient.getAssetDetail(id: originalId).isFavorite
            let albumIds = try await apiClient.getAlbumsForAsset(assetId: originalId).map(\.id)
            AppLogger.ui.info("EditedAssetUploadService: übernehme vom Original \(originalId) – Favorit=\(istFavorit), Alben=\(albumIds.count)")

            if istFavorit {
                try await apiClient.toggleFavorite(assetId: neueId, isFavorite: true)
            }
            // Einzeln, damit ein Album, das den Zusatz ablehnt (etwa ein geteiltes ohne
            // Schreibrecht), die übrigen nicht mitnimmt.
            for albumId in albumIds {
                do {
                    try await apiClient.addAssetsToAlbum(albumId: albumId, assetIds: [neueId])
                    AppLogger.ui.info("EditedAssetUploadService: \(neueId) zu Album \(albumId) hinzugefügt")
                } catch {
                    AppLogger.ui.warning("EditedAssetUploadService: \(neueId) nicht zu Album \(albumId) hinzugefügt: \(error.localizedDescription)")
                }
            }
        } catch {
            AppLogger.ui.warning("EditedAssetUploadService: Metadaten des Originals \(originalId) nicht übernommen: \(error.localizedDescription)")
        }
    }

    /// Ergebnis des Ersetzen-Pfads.
    ///
    /// Neben der neuen Asset-ID liefert dies den vom Original übernommenen
    /// Favoritenstatus zurück — Aufrufer bauen daraus im Fehlerfall (Re-Fetch des
    /// neuen Assets scheitert) ein optimistisches Fallback-Asset fürs Grid, so wie es
    /// die drei Originalimplementierungen taten.
    struct ReplaceResult {
        let newAssetId: String
        let isFavorite: Bool
    }

    /// Lädt hoch, überträgt Favorit/Alben des Originals auf das neue Asset und
    /// verschiebt danach das Original in den Papierkorb.
    static func uploadAndReplace(
        _ u: EditedUpload,
        originalAsset: Asset,
        apiClient: ImmichAPIClient
    ) async throws -> ReplaceResult {
        // Favorit + Alben stehen **vor** dem Hochladen — hier ist noch nichts
        // geschehen, ein Abbruch lässt die Bibliothek unberührt.
        //
        // Zuvor stand hier zweimal `try?`: Schlug eine Abfrage fehl, blieben
        // `isFavorite` false und `albumIds` leer, das Original wanderte trotzdem in
        // den Papierkorb — und die bearbeitete Fassung stand danach in keinem Album.
        // Ein HTTP-Fehler kostete damit die Albumzugehörigkeit des Fotos.
        let isFavorite: Bool
        let albumIds: [String]
        do {
            isFavorite = try await apiClient.getAssetDetail(id: originalAsset.id).isFavorite
            albumIds = try await apiClient.getAlbumsForAsset(assetId: originalAsset.id).map(\.id)
        } catch {
            throw ImageEditingError.originalMetadataUnavailable(
                underlying: error.localizedDescription
            )
        }
        AppLogger.ui.info("EditedAssetUploadService: original metadata – isFavorite=\(isFavorite), albumCount=\(albumIds.count)")

        // --- Upload des bearbeiteten Bildes ---
        let newId = try await upload(u, apiClient: apiClient)
        AppLogger.ui.info("EditedAssetUploadService: uploaded new asset \(newId), deleteOriginal=true")

        // --- Original in Papierkorb ---
        // Erst übertragen, dann löschen. Umgekehrt ist die Quelle im Zweifel schon
        // weg: Scheiterte ein `addAssetsToAlbum`, lag das Original bereits im
        // Papierkorb, und das Album hatte sein Foto verloren — lautlos, denn beide
        // Aufrufe standen unter `try?`.
        //
        // Dieselbe Reihenfolge hält `DuplicateActionService` ein; dort sichert sie ein
        // eigener Test zu ("Die Übernahme läuft vollständig vor dem Löschen"). Ein
        // Fehlschlag bricht jetzt ab, bevor gelöscht wird: Dann liegen zwar zwei
        // Fassungen in der Bibliothek, aber keine verliert etwas.
        if isFavorite {
            try await apiClient.toggleFavorite(assetId: newId, isFavorite: true)
            AppLogger.ui.info("EditedAssetUploadService: set favorite on new asset \(newId)")
        }
        for albumId in albumIds {
            try await apiClient.addAssetsToAlbum(albumId: albumId, assetIds: [newId])
            AppLogger.ui.info("EditedAssetUploadService: added new asset \(newId) to album \(albumId)")
        }

        // Upload immer vor Delete. `force: false` → Papierkorb, keine endgültige Löschung.
        try await apiClient.deleteAssets(ids: [originalAsset.id], force: false)
        AppLogger.ui.info("EditedAssetUploadService: moved original \(originalAsset.id) to trash")

        return ReplaceResult(newAssetId: newId, isFavorite: isFavorite)
    }

    // MARK: - Netzwerk-Upload

    private static func uploadFile(
        _ sourceURL: URL,
        upload u: EditedUpload,
        apiClient: ImmichAPIClient
    ) async throws -> String {
        let url = apiClient.baseURL.appending(path: "api/assets")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiClient.apiKey, forHTTPHeaderField: "x-api-key")

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        // MIME-Typ aus der (schon korrekt gewählten) Endung des Zieldateinamens —
        // nicht aus der tatsächlichen Quelldatei, deren Temp-Name im `data:`-Fall
        // keine Endung trägt.
        let mimeType = MIMEType.mimeType(for: URL(fileURLWithPath: u.fileName))

        let bodyURL = try writeMultipartBody(
            fileURL: sourceURL,
            fileName: u.fileName,
            mimeType: mimeType,
            boundary: boundary,
            fields: [
                "deviceAssetId": "\(u.fileName)-\(UUID().uuidString)",
                "deviceId": "ImmichMac",
                "fileCreatedAt": u.fileCreatedAt,
                "fileModifiedAt": u.fileModifiedAt,
            ]
        )
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: bodyURL, delegate: SichereWeiterleitung.shared)
        guard let http = response as? HTTPURLResponse, (200...201).contains(http.statusCode) else {
            throw APIError.httpError((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return try JSONDecoder().decode(UploadResponse.self, from: data).id
    }

    /// Liefert die Quelldatei für den Upload plus eine Aufräum-Funktion.
    ///
    /// Bei `data` wird der Inhalt erst in eine Temp-Datei geschrieben — der Multipart-
    /// Rumpf wird immer auf die Platte gestreamt (siehe `writeMultipartBody`), auch für
    /// den `data:`-Fall. Grund: kommende 60-MP-HEIC-Exporte sollen nicht doppelt im
    /// Speicher liegen (Data → Multipart-Data → httpBody).
    private static func sourceFileURL(for u: EditedUpload) throws -> (url: URL, cleanup: () -> Void) {
        switch (u.data, u.fileURL) {
        case (let data?, nil):
            let tempURL = FileManager.default.temporaryDirectory
                .appending(path: "edited-upload-source-\(UUID().uuidString)")
            try data.write(to: tempURL)
            return (tempURL, { try? FileManager.default.removeItem(at: tempURL) })
        case (nil, let fileURL?):
            return (fileURL, {})
        default:
            preconditionFailure("EditedUpload: genau eines von data/fileURL muss gesetzt sein")
        }
    }

    // MARK: - Multipart Body (auf Disk gestreamt)

    /// Schreibt den Multipart-Rumpf in eine temporäre Datei und liefert deren Pfad.
    ///
    /// Die Nutzdatei wird dabei in 256-KB-Häppchen umkopiert statt am Stück gelesen —
    /// dasselbe Vorgehen wie in `UploadManager.performUpload`, wo der Quelltext es mit
    /// „avoids loading entire video into memory" begründet. Übernommen aus
    /// `ExternalEditorService.writeMultipartBody`.
    ///
    /// `internal` statt `private`, damit der Aufbau des Rumpfes im Test prüfbar ist:
    /// Der Sendevorgang selbst läuft über `URLSession.shared` und ist im Test nicht
    /// erreichbar.
    static func writeMultipartBody(
        fileURL: URL,
        fileName: String,
        mimeType: String,
        boundary: String,
        fields: [String: String]
    ) throws -> URL {
        let bodyURL = FileManager.default.temporaryDirectory
            .appending(path: "edit-upload-\(UUID().uuidString).multipart")
        FileManager.default.createFile(atPath: bodyURL.path, contents: nil)

        let handle = try FileHandle(forWritingTo: bodyURL)
        defer { try? handle.close() }

        func schreibe(_ text: String) throws {
            try handle.write(contentsOf: Data(text.utf8))
        }

        // Feste Reihenfolge: Ein Dictionary hat keine, und ein Rumpf, der sich von Lauf
        // zu Lauf umsortiert, ließe sich weder vergleichen noch prüfen.
        for name in fields.keys.sorted() {
            try schreibe("--\(boundary)\r\n")
            try schreibe("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            try schreibe("\(fields[name] ?? "")\r\n")
        }

        try schreibe("--\(boundary)\r\n")
        try schreibe("Content-Disposition: form-data; name=\"assetData\"; filename=\"\(fileName)\"\r\n")
        try schreibe("Content-Type: \(mimeType)\r\n\r\n")

        let quelle = try FileHandle(forReadingFrom: fileURL)
        defer { try? quelle.close() }
        while let block = try quelle.read(upToCount: 256 * 1024), !block.isEmpty {
            try handle.write(contentsOf: block)
        }

        try schreibe("\r\n--\(boundary)--\r\n")
        return bodyURL
    }
}
