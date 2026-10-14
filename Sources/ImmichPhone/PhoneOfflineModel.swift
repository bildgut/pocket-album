import Foundation
import SwiftData
import Observation

/// Hält die Offline-Abzeichen aller Alben für die Oberfläche.
///
/// Liest ausschließlich über `OfflinePinStore` und schreibt ausschließlich über
/// `OfflinePinStore.setPinned` — derselbe einzige Aufruf wie in
/// `AlbumDetailView.commitOfflineToggle` auf dem Mac. Es gibt hier bewusst **keinen**
/// zweiten, direkten Anstoß von `OfflineDownloadManager.syncOfflineAlbums`: Beim
/// Pinnen startet `setPinned(true, …)` diesen Lauf bereits selbst über einen
/// internen `Task.detached` (`OfflinePinStore.swift:101-107`). Ein zusätzlicher
/// `await`-Aufruf hier würde mit diesem internen Lauf um den Actor-eigenen
/// `isSyncing`-Schalter konkurrieren — gewinnt der interne Task, kehrt der
/// zusätzliche Aufruf sofort zurück, obwohl der eigentliche Download noch läuft.
@Observable @MainActor
final class PhoneOfflineModel {
    private(set) var badges: [String: OfflineBadge] = [:]
    /// „Letzte Tage offline“: Stufe, Anzahl und Zustand — `nil`, solange aus.
    private(set) var zuletzt: PhoneZuletztStand?

    func badge(for albumId: String) -> OfflineBadge { badges[albumId] ?? .cloud }

    func refresh(context: ModelContext) {
        var neu: [String: OfflineBadge] = [:]
        for pin in OfflinePinStore.allPins(in: context) where pin.kind == .album {
            neu[pin.targetId] = OfflineBadge.from(pin: pin)
        }
        badges = neu

        let tage = ZuletztOffline.tage()
        if tage > 0, let pin = OfflinePinStore.pin(kind: .zuletzt, targetId: ZuletztOffline.targetId, in: context) {
            zuletzt = PhoneZuletztStand(tage: tage, anzahl: pin.assetIds.count, badge: OfflineBadge.from(pin: pin))
        } else {
            zuletzt = nil
        }
    }

    /// Setzt die Stufe von „Letzte Tage offline“. Bei > 0 wird der eine Vermerk
    /// angelegt oder neu aufgelöst (`setPinned` startet den Lauf mit `force`, das
    /// neue Fenster greift sofort; was herausfällt, räumt der Lauf am Ende ab). Bei 0
    /// wird er aufgehoben wie ein Album. Eine schon getroffene Qualitätswahl bleibt,
    /// sonst gilt ``ZuletztOffline/vorgabeWahl``.
    func setzeZuletzt(tage: Int, context: ModelContext, apiClient: ImmichAPIClient,
                      speicher: OfflineWahlSpeicher = OfflineWahlSpeicher()) {
        ZuletztOffline.setzeTage(tage)
        if ZuletztOffline.tage() > 0 {
            if speicher.wahl(fuer: ZuletztOffline.pinId) == nil {
                speicher.setze(ZuletztOffline.vorgabeWahl, fuer: ZuletztOffline.pinId, alsLetzte: false)
            }
            OfflinePinStore.setPinned(
                true, kind: .zuletzt, targetId: ZuletztOffline.targetId,
                displayName: PhoneZuletztStand.titel(tage: tage), assetIds: nil,
                context: context, apiClient: apiClient
            )
        } else {
            Self.hebeAuf(kind: .zuletzt, targetId: ZuletztOffline.targetId,
                         displayName: PhoneZuletztStand.titel(tage: 0),
                         context: context, apiClient: apiClient, speicher: speicher)
        }
        refresh(context: context)
    }

    /// Nimmt ein Album mit der Wahl aus dem Blatt offline. Die Wahl wird **zuerst**
    /// gemerkt, **dann** gepinnt: `setPinned` startet den Lauf sofort, und der fragt
    /// die Wahl-Quelle ab (`ImmichPhoneApp.init`). Andersherum lüde der erste Lauf
    /// Originale. Ob über Mobilfunk geladen werden darf, steht in der Wahl.
    ///
    /// Fortschritt während des Ladens liefert dieser Typ nicht selbst: Ansichten
    /// beobachten `OfflineSyncProgress.shared` (`isActive`/`labelText`/`progress`,
    /// `wartetAufWLAN`) direkt, genau wie der Mac es in `OfflineAlbumsSettingsSection`
    /// tut, und rufen `refresh(context:)` in
    /// `.onChange(of: OfflineSyncProgress.shared.isActive)`, sobald es auf `false`
    /// wechselt.
    func nimmOffline(album: Album, wahl: OfflineWahl, context: ModelContext,
                     apiClient: ImmichAPIClient, speicher: OfflineWahlSpeicher = OfflineWahlSpeicher()) {
        speicher.setze(wahl, fuer: OfflinePin.pinId(kind: .album, targetId: album.id))
        OfflinePinStore.setPinned(
            true, kind: .album, targetId: album.id,
            displayName: album.albumName, assetIds: nil,
            context: context, apiClient: apiClient
        )
        refresh(context: context)
    }

    /// Hebt den Offline-Status auf: Vermerk weg, Dateien werden geräumt, die Wahl
    /// vergessen — neu speichern heißt neu wählen.
    func gibFrei(album: Album, context: ModelContext,
                 apiClient: ImmichAPIClient, speicher: OfflineWahlSpeicher = OfflineWahlSpeicher()) {
        Self.hebeAuf(kind: .album, targetId: album.id, displayName: album.albumName,
                     context: context, apiClient: apiClient, speicher: speicher)
        refresh(context: context)
    }

    /// Der eine Weg, einen Vermerk aufzuheben — auch für die Einstellungen, die
    /// kein Modell in der Hand haben. Vorher rief die Liste dort nur `setPinned`
    /// und ließ Wahl und „wartet auf WLAN“-Marke liegen; ein späteres Neu-Pinnen
    /// erbte dann die alte Wahl.
    static func hebeAuf(kind: OfflinePinKind, targetId: String, displayName: String,
                        context: ModelContext, apiClient: ImmichAPIClient,
                        speicher: OfflineWahlSpeicher = OfflineWahlSpeicher()) {
        let pinId = OfflinePin.pinId(kind: kind, targetId: targetId)
        OfflinePinStore.setPinned(
            false, kind: kind, targetId: targetId,
            displayName: displayName, assetIds: nil,
            context: context, apiClient: apiClient
        )
        speicher.entferne(pinId: pinId)
        OfflineSyncProgress.shared.wartetAufWLAN.remove(pinId)
        // Wer „Letzte Tage“ in der Offline-Liste entfernt, schaltet die Funktion
        // ab — sonst legte der nächste Wechsel der Stufe ihn stillschweigend neu an.
        if kind == .zuletzt { ZuletztOffline.setzeTage(0) }
    }
}

/// Was Kachel und Einstellungen über „Letzte Tage offline“ zeigen.
struct PhoneZuletztStand: Equatable {
    let tage: Int
    let anzahl: Int
    let badge: OfflineBadge

    var titel: String { Self.titel(tage: tage) }

    static func offlineHinweis(tage: Int) -> String {
        String(localized: "Offline · photos from the last \(tage) days")
    }

    static func titel(tage: Int) -> String {
        tage == 0 ? String(localized: "Recent Days") : String(localized: "Last \(tage) Days")
    }
}
