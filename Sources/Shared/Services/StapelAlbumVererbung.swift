import Foundation

/// Kleinster Server-Vertrag für die Album-Vererbung innerhalb eines Stapels —
/// erlaubt vollständige Komponententests ohne Netzwerk.
protocol StapelAlbumServer: Sendable {
    func getAlbumsForAsset(assetId: String) async throws -> [Album]
    func addAssetsToAlbum(albumId: String, assetIds: [String]) async throws
    func removeAssetsFromAlbum(albumId: String, assetIds: [String]) async throws
    func setAlbumCover(albumId: String, assetId: String) async throws
}

extension ImmichAPIClient: StapelAlbumServer {}

/// Übergabepaket nach der synchronen lokalen Vorbereitung einer Löschung.
struct StapelLoeschVorbereitung: Sendable {
    struct Paar: Equatable, Sendable {
        let geloeschteId: String
        let nachfolgerId: String
    }

    /// Für jede gelöschte ID mit überlebendem Stapel-Geschwister das neue Haupt-Asset.
    let nachfolgerJeGeloeschterId: [String: Asset]
    /// Überlebende Asset-IDs, deren Stapel-Zustand im Grid-Index aktualisiert wurde.
    let geaenderteUeberlebendeIds: [String]
    /// Paare `(geloeschteId, nachfolgerId)`, deren Alben vor `deleteAssets` auf dem
    /// Server vererbt werden müssen (ohne identische IDs).
    let vererbungsPaare: [Paar]
    /// Ersetzungstabelle für offene Album-Ansichten (`[alteId: neuesAsset]` sowie
    /// `[neuesAsset.id: neuesAsset]`, damit beim Löschen eines RAW-Kinds auch das
    /// verbleibende HEIC-Hauptbild sofort sein „HEIC + RAW"-Abzeichen verliert).
    let ersetzungenFuerAnsicht: [String: Asset]
}

/// Hält Server-Alben sauber (nur das aktive Hauptbild im Album) und vererbt
/// Album-Mitgliedschaften automatisch innerhalb eines Stapels:
/// - **Beim Löschen** einer Fassung (z. B. `HEIC` wird gelöscht, `DNG` bleibt):
///   vor `deleteAssets` erbt das überlebende Geschwister alle echten Benutzer-Alben
///   (keine Smart-Album-Spiegel `✦ …`) und übernimmt bei Bedarf auch das Album-Titelbild.
/// - **Beim Titelbildwechsel** im Stapel-Popover (`HEIC` → `DNG`):
///   das neue Hauptbild wird zuerst in alle Alben des alten Hauptbilds aufgenommen und
///   erst nach Erfolg wird das alte Hauptbild dort entfernt.
enum StapelAlbumVererbung {

    /// Schritt 1 (synchron, lokal): aktualisiert den Stapel-Zustand im `GridIndexStore`,
    /// trägt überlebende Nachfolger optimistisch in den lokalen `AlbumMembershipStore`
    /// ein und liefert alle Angaben für UI-Soforttausch und Server-Nachlauf.
    static func bereiteLoeschungVor(
        ids: [String],
        gridStore: GridIndexStore = .shared,
        albumStore: AlbumMembershipStore = .shared
    ) -> StapelLoeschVorbereitung {
        guard !ids.isEmpty else {
            return StapelLoeschVorbereitung(
                nachfolgerJeGeloeschterId: [:],
                geaenderteUeberlebendeIds: [],
                vererbungsPaare: [],
                ersetzungenFuerAnsicht: [:]
            )
        }

        let nachfolge = gridStore.trashAssetsAndPromoteStacks(ids: ids)
        guard !nachfolge.nachfolgerJeGeloeschterId.isEmpty else {
            return StapelLoeschVorbereitung(
                nachfolgerJeGeloeschterId: [:],
                geaenderteUeberlebendeIds: nachfolge.geaenderteUeberlebendeIds,
                vererbungsPaare: [],
                ersetzungenFuerAnsicht: [:]
            )
        }

        var paare: [StapelLoeschVorbereitung.Paar] = []
        var gesehenePaare = Set<String>()
        var ersetzungen: [String: Asset] = [:]

        let lokaleAlbenJeAsset = albumStore.albumIds(
            forAssets: Array(nachfolge.nachfolgerJeGeloeschterId.keys)
        )

        for id in ids {
            guard let nachfolger = nachfolge.nachfolgerJeGeloeschterId[id] else { continue }
            ersetzungen[id] = nachfolger
            ersetzungen[nachfolger.id] = nachfolger

            guard nachfolger.id != id else { continue }
            let schluessel = "\(id)->\(nachfolger.id)"
            if gesehenePaare.insert(schluessel).inserted {
                paare.append(.init(geloeschteId: id, nachfolgerId: nachfolger.id))
            }

            if let lokaleAlben = lokaleAlbenJeAsset[id] {
                for albumId in lokaleAlben {
                    albumStore.addMembership(albumId: albumId, assetIds: [nachfolger.id])
                }
            }
        }

        return StapelLoeschVorbereitung(
            nachfolgerJeGeloeschterId: nachfolge.nachfolgerJeGeloeschterId,
            geaenderteUeberlebendeIds: nachfolge.geaenderteUeberlebendeIds,
            vererbungsPaare: paare,
            ersetzungenFuerAnsicht: ersetzungen
        )
    }

    /// Schritt 2 (asynchron, **vor** `deleteAssets` aufrufen): überträgt auf dem Server
    /// alle Nicht-Smart-Alben jeder gelöschten Fassung auf ihren überlebenden Nachfolger.
    ///
    /// Warum zwingend **vor** `deleteAssets`: Sobald ein Asset im Papierkorb liegt,
    /// liefert `GET /api/albums?assetId=…` je nach Server-Version keine Alben mehr oder
    /// hat das Album-Titelbild bereits verworfen. Fehler einzelner Alben (z. B. fremdes
    /// geteiltes Album ohne Schreibrecht) werden geloggt, brechen aber weder die übrigen
    /// Alben noch das anschließende Löschen ab.
    @discardableResult
    static func vererbeAlbenVorLoeschen(
        paare: [StapelLoeschVorbereitung.Paar],
        server: any StapelAlbumServer,
        albumStore: AlbumMembershipStore? = nil
    ) async -> Int {
        guard !paare.isEmpty else { return 0 }
        var geaenderteAlben = Set<String>()

        for paar in paare where paar.geloeschteId != paar.nachfolgerId {
            let serverAlben: [Album]?
            do {
                serverAlben = try await server.getAlbumsForAsset(assetId: paar.geloeschteId)
            } catch {
                AppLogger.api.warning(
                    "StapelAlbumVererbung: getAlbumsForAsset(\(paar.geloeschteId)) fehlgeschlagen, versuche lokalen Index: \(error)"
                )
                serverAlben = nil
            }

            if let serverAlben {
                for album in serverAlben where !album.isSmartAlbum {
                    do {
                        try await server.addAssetsToAlbum(
                            albumId: album.id,
                            assetIds: [paar.nachfolgerId]
                        )
                        geaenderteAlben.insert(album.id)
                        if album.albumThumbnailAssetId == paar.geloeschteId {
                            try? await server.setAlbumCover(
                                albumId: album.id,
                                assetId: paar.nachfolgerId
                            )
                        }
                    } catch {
                        AppLogger.api.warning(
                            "StapelAlbumVererbung: Nachfolger \(paar.nachfolgerId) konnte Album \(album.id) nicht beitreten: \(error)"
                        )
                    }
                }
            } else if let albumStore {
                // Rückfall bei gestörtem getAlbumsForAsset: bekannte lokale Alben versuchen.
                let fallbackIds = albumStore.albumIds(forAssets: [paar.geloeschteId])[paar.geloeschteId] ?? []
                for albumId in fallbackIds {
                    do {
                        try await server.addAssetsToAlbum(
                            albumId: albumId,
                            assetIds: [paar.nachfolgerId]
                        )
                        geaenderteAlben.insert(albumId)
                    } catch {
                        AppLogger.api.warning(
                            "StapelAlbumVererbung: Fallback-Beitritt für \(paar.nachfolgerId) in Album \(albumId) fehlgeschlagen: \(error)"
                        )
                    }
                }
            }
        }

        return geaenderteAlben.count
    }

    /// Tauscht bei einem Titelbildwechsel im Stapel (`altesTitelbild` → `neuesTitelbild`)
    /// die Mitgliedschaft in allen Nicht-Smart-Alben: erst das neue Hauptbild hinzufügen,
    /// ggf. Album-Titelbild nachziehen, und **nur bei Erfolg** das alte Hauptbild aus dem
    /// Album entfernen. So geht bei einem Teilfehler niemals ein Foto aus einem Album
    /// verloren.
    @discardableResult
    static func uebertrageAlbenBeiTitelwechsel(
        altesTitelbild: String,
        neuesTitelbild: String,
        server: any StapelAlbumServer
    ) async -> Int {
        guard altesTitelbild != neuesTitelbild else { return 0 }

        let alben: [Album]
        do {
            alben = try await server.getAlbumsForAsset(assetId: altesTitelbild)
        } catch {
            AppLogger.api.warning(
                "StapelAlbumVererbung: Titelwechsel konnte Alben für \(altesTitelbild) nicht laden: \(error)"
            )
            return 0
        }

        var umgezogeneAlben = 0
        for album in alben where !album.isSmartAlbum {
            do {
                try await server.addAssetsToAlbum(
                    albumId: album.id,
                    assetIds: [neuesTitelbild]
                )
            } catch {
                AppLogger.api.warning(
                    "StapelAlbumVererbung: Titelwechsel konnte \(neuesTitelbild) nicht zu Album \(album.id) hinzufügen — altes Titelbild bleibt im Album: \(error)"
                )
                continue
            }

            if album.albumThumbnailAssetId == altesTitelbild {
                try? await server.setAlbumCover(
                    albumId: album.id,
                    assetId: neuesTitelbild
                )
            }

            do {
                try await server.removeAssetsFromAlbum(
                    albumId: album.id,
                    assetIds: [altesTitelbild]
                )
                umgezogeneAlben += 1
            } catch {
                AppLogger.api.warning(
                    "StapelAlbumVererbung: Neues Titelbild \(neuesTitelbild) ist in Album \(album.id), Entfernen von \(altesTitelbild) schlug fehl: \(error)"
                )
                umgezogeneAlben += 1
            }
        }

        return umgezogeneAlben
    }
}
