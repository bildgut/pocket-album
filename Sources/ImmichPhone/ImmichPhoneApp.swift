import SwiftUI

@main
struct ImmichPhoneApp: App {

    /// Nur für eine einzige Sache da: die Zweitbildschirm-Szene anzumelden.
    /// SwiftUI kennt keinen Szenentyp für externe Bildschirme, also muss die
    /// Konfiguration über einen `UIApplicationDelegate` kommen — die
    /// Begründung, warum das ohne `UIApplicationSceneManifest` auskommt, steht
    /// bei ``PhoneAppDelegat``.
    @UIApplicationDelegateAdaptor(PhoneAppDelegat.self) private var appDelegat

    @State private var connectionManager: ConnectionManager

    init() {
        // Kontowechsel leert Store, Offline-Dateien und Rasterindex, bevor der neue
        // Client die Oberfläche erreicht. Fotos- und Entdecken-Reiter leert
        // `PhoneRootView` auf `.kontoGewechselt` — sie hängen dort als `@State`.
        let connection = ConnectionManager()
        connection.beiKontoWechsel = {
            await AccountDataPurge.kontoGewechselt(container: PhoneModelContainer.shared)
        }
        _connectionManager = State(initialValue: connection)

        // Der Lader ist geteilter Code; nur hier bekommt er die Wahl je Album.
        // Ohne diese Zeile lüde auch das Telefon Originale, wie der Mac.
        Task {
            await OfflineDownloadManager.shared.setzeWahlQuelle { OfflineWahlSpeicher().wahl(fuer: $0) }
        }
        // Am Mac räumt `evictExpired` (über die SyncEngine) abgebrochene Downloads
        // weg; das Telefon startet keine SyncEngine, die `.tmp`-Reste blieben also
        // für immer liegen. Abseits des MainActors: die Aufzählung geht über die
        // ganze Offline-Ablage.
        if !AppEnvironment.isRunningTests {
            Task.detached(priority: .utility) {
                LocalFileCacheManager.removeStaleTempFiles()
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            PhoneRootView()
                .tint(Marke.akzent)
                .defaultAppStorage(AppEnvironment.defaults)
                .environment(connectionManager)
        }
        .modelContainer(PhoneModelContainer.shared)
    }
}
