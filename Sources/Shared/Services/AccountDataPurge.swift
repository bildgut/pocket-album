import Foundation
import Nuke
import SwiftData

/// Räumt beim Abmelden die **kontogebundenen** Daten aus dem Store.
///
/// Warum das nicht in ``ConnectionManager/disconnect()`` steht: Derselbe Aufruf
/// hängt am Mac auf ⇧⌘W (`ImmichMacApp.swift`) und auf einem Symbol in der
/// Seitenleiste ohne jede Rückfrage (`SidebarView.swift`), und am Telefon heißt
/// er an einer Stelle „Zugangsdaten ändern" (`PhoneRootView.swift`) — der
/// Reparaturweg für einen falsch eingetippten Schlüssel. Ein Tastendruck oder
/// ein Vertipper darf keine Gigabyte löschen. `disconnect()` bleibt deshalb
/// unverändert; das Aufräumen ist ein eigener Schritt mit eigener Rückfrage.
///
/// **Eine namentliche Liste, kein Kahlschlag.** Im selben Store liegen vierzehn
/// Modelle mit Arbeit, die kein Nachsync wiederbringt — Smart Alben, RAW-Ent­
/// wicklungen, Presets, die Ignorier-Listen von Duplikat-, Geo- und Trip-Suche,
/// die Undo-Einträge der Datumskorrektur, die Befundjournale. Ein
/// `delete(model:)` über alles wäre hier kein Fehler, den man aussitzt.
enum AccountDataPurge {

    /// Wie weit das Aufräumen geht.
    struct Umfang: Equatable {
        /// Auch die Offline-Vermerke samt der dafür geladenen Originale entfernen.
        var offlineOriginale: Bool

        /// Vorgabe beim Abmelden: der Server-Spiegel fällt, die offline gewählten
        /// Alben bleiben nutzbar liegen.
        static let nurMetadaten = Umfang(offlineOriginale: false)

        /// Zusätzlich angekreuzt: auch die Offline-Alben und ihre Dateien.
        static let alles = Umfang(offlineOriginale: true)
    }

    /// Der ganze Weg: abmelden, Hintergrundläufe anhalten, dann aufräumen.
    ///
    /// **Die Reihenfolge ist nicht beliebig.** Zuerst `disconnect()`: Es sendet
    /// `.connectionDidDisconnect`, und erst danach hören Sync, Offline-Lader und
    /// Co. auf, in Store, Rasterindex und Dateicache zu schreiben — räumte man
    /// vorher auf, legte ein laufender Durchgang die Zeilen gleich wieder an.
    /// `disconnect()` setzt `imagePipeline` und den Plattencache auf `nil`; beide
    /// werden deshalb **vorher** festgehalten und danach geräumt.
    ///
    /// Den Fotos-Reiter (`PhonePhotoFeed.leere()`) ruft die iOS-Ansicht selbst
    /// im Anschluss — er hängt als `@State` an `PhoneRootView` und hat in
    /// `Sources/Shared` nichts zu suchen.
    @MainActor
    static func abmeldenUndAufraeumen(
        umfang: Umfang,
        connection: ConnectionManager,
        container: ModelContainer,
        defaults: UserDefaults = AppEnvironment.defaults
    ) async {
        let caches = connection.bildCaches
        connection.disconnect()
        // Abbrechen UND auf das Ende warten: `cancel()` allein setzte nur die Marke,
        // eine gerade schreibende Datei konnte danach noch in der geleerten Ablage landen.
        await OfflineDownloadManager.shared.abbrechenUndWarten()

        purgeStore(context: ModelContext(container), umfang: umfang)
        purgeDefaults(defaults, offlineDaten: umfang.offlineOriginale)
        GridIndexStore.shared.deleteAll()

        // Der Nuke-Cache ist hier **nicht** der Befund, sondern eine Aufräum-
        // arbeit: Sein Schlüssel ist die volle URL, also samt Host und
        // Asset-UUID (`ImmichAPIClient.assetBasePath`). Ein Kontowechsel auf
        // demselben Host trifft einen alten Eintrag deshalb nur dort, wo beide
        // Konten dasselbe Asset sehen dürfen — dann sind die Bytes richtig.
        // Falsche Bilder kann er nicht zeigen. Liegen bleiben die Thumbnails des
        // Vorbesitzers trotzdem, unerreichbar für die Oberfläche, aber auf der
        // Platte. Das genügt als Grund.
        caches.platte?.removeAll()
        caches.pipeline?.cache.removeAll()

        if umfang.offlineOriginale {
            await LocalFileCacheManager.shared.clearAll(container: container)
        }
    }

    /// Kontowechsel: Die neuen Zugangsdaten gehören zu einem anderen Konto als die
    /// zuletzt benutzten. Dann fällt **alles** Kontogebundene, auch die Offline-Alben
    /// samt Dateien — sie gehören dem Vorbesitzer. Ohne Abmelden (die neuen
    /// Zugangsdaten sind ja gerade gültig) und ohne Nuke: dessen Schlüssel sind volle
    /// URLs mit Asset-UUID, ein fremdes Bild kann er nicht zeigen (siehe oben).
    @MainActor
    static func kontoGewechselt(
        container: ModelContainer,
        defaults: UserDefaults = AppEnvironment.defaults
    ) async {
        await OfflineDownloadManager.shared.abbrechenUndWarten()
        purgeStore(context: ModelContext(container), umfang: .alles)
        purgeDefaults(defaults, offlineDaten: true)
        GridIndexStore.shared.deleteAll()
        await LocalFileCacheManager.shared.clearAll(container: container)
    }

    /// Der SwiftData-Teil. Bewusst synchron und ohne Netz, Dateisystem oder
    /// `ImagePipeline` — damit genau die Entscheidung prüfbar ist, an der ein
    /// Fehler nicht heilbar wäre.
    static func purgeStore(context: ModelContext, umfang: Umfang) {
        // Die Vermerke bestimmen, was überlebt — also zuerst lesen, dann löschen.
        let vermerke = umfang.offlineOriginale ? [] : OfflinePinStore.allPins(in: context)
        if umfang.offlineOriginale {
            try? context.delete(model: OfflinePin.self)
        }
        let geschonteAssets = Set(vermerke.flatMap(\.assetIds))
        let geschonteAlben = Set(vermerke.filter { $0.kind == .album }.map(\.targetId))

        loesche(CachedAsset.self, in: context, schonend: geschonteAssets, schluessel: \.assetId)
        loesche(CachedAlbum.self, in: context, schonend: geschonteAlben, schluessel: \.albumId)
        try? context.delete(model: CachedAssetEdit.self)
        // Sonst hinge die Bearbeitungs-Markierung eines fremden Kontos in den Bild-URLs.
        EditedAssetsStore.shared.removeAll()
        try? context.delete(model: SyncState.self)

        // Die beiden Warteschlangen sind der ernstere Teil. Beide werden beim
        // nächsten Start von selbst wieder aufgenommen — `OfflineActionQueue`
        // spielt `PendingAction` ab, `UploadManager.restorePendingUploads()` die
        // `UploadQueueEntry`. Bliebe ein offener Upload von Konto A liegen,
        // landete die Datei nach dem Neuanmelden in der Mediathek von Konto B:
        // ein stiller Schreibzugriff über die Kontogrenze, nicht bloß eine
        // falsche Anzeige.
        try? context.delete(model: PendingAction.self)
        try? context.delete(model: UploadQueueEntry.self)

        try? context.save()
    }

    /// Nimmt die beiden Marken zurück, an denen `ConnectionManager.hasCachedData`
    /// entscheidet, ob die App kalt in `.offline` statt in `.disconnected`
    /// startet. Bleiben sie stehen, behauptet der nächste Start einen Cache, den
    /// dieser Lauf gerade geleert hat.
    ///
    /// Ausdrücklich namentlich und nicht über `removePersistentDomain`:
    /// `AppEnvironment.defaults` ist die Ablage der ganzen App und enthält unter
    /// anderem den Gemini-Schlüssel, der ein Abmelden überleben soll.
    ///
    /// Mit `offlineDaten` fallen auch die Offline-Wahl je Vermerk und die Abkühlmarke
    /// des Offline-Laders — sonst gälte die Wahl des Vorkontos für gleichnamige
    /// `pinId`s weiter, und der erste Lauf danach wartete 15 Minuten.
    static let offlineSchluessel = [OfflineWahlSpeicher.schluessel, OfflineWahlSpeicher.letzteSchluessel,
                                           "offlineSync.lastSyncDate"]

    static func purgeDefaults(_ defaults: UserDefaults, offlineDaten: Bool = false) {
        defaults.removeObject(forKey: "hasCompletedInitialSync")
        defaults.removeObject(forKey: "hasCachedAlbums")
        if offlineDaten {
            for schluessel in offlineSchluessel { defaults.removeObject(forKey: schluessel) }
        }
    }

    /// Löscht alle Zeilen eines Modells außer denen, deren Schlüssel in
    /// `schonend` steht.
    ///
    /// Der leere Fall geht ausdrücklich über `delete(model:)` und nicht über die
    /// Schleife: Das ist der Regelfall (keine Offline-Alben, oder alles
    /// angekreuzt), und am Mac hängen daran rund 167 000 `CachedAsset`. Die alle
    /// in den Speicher zu holen, nur um sie einzeln zu löschen, wäre eine
    /// Sekundenpause für nichts — SwiftData erledigt den Rundumschlag in SQL.
    ///
    /// Für den Rest bleibt nur die Schleife: `#Predicate` kann keine
    /// Set-Mitgliedschaft über beliebig viele IDs ausdrücken (dieselbe Grenze,
    /// die schon `LocalFileCacheManager.status(forAssetIds:container:)` in den
    /// lokalen Filter zwingt).
    private static func loesche<T: PersistentModel>(
        _ type: T.Type,
        in context: ModelContext,
        schonend: Set<String>,
        schluessel: KeyPath<T, String>
    ) {
        guard !schonend.isEmpty else {
            try? context.delete(model: T.self)
            return
        }
        for zeile in (try? context.fetch(FetchDescriptor<T>())) ?? []
        where !schonend.contains(zeile[keyPath: schluessel]) {
            context.delete(zeile)
        }
    }
}
