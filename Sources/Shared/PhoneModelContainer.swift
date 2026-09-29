import Foundation
import SwiftData

/// SwiftData-Aufbau für den iOS-Client.
///
/// Bewusst nicht der Mac-Aufbau aus `ImmichMacApp.swift`: Der zeigt `NSAlert`-Dialoge,
/// ruft `NSApp.terminate` und rettet über `StoreBackupService` — alles macOS-eigen.
/// Statt eines Backups gibt es hier den Rettungspfad in ``oeffneMitRettung(at:versuche:pause:jetzt:)``:
/// Der iOS-Store ist ein Cache, der sich vom Server neu aufbaut.
///
/// Beibehalten ist das Wiederholen bei transienten Fehlern: Ein gesperrter Store
/// (etwa während eine noch beendende Instanz die Migration hält) darf nicht als
/// „kaputt" gelten. Am 2026-07-10 haben genau solche Fehler auf dem Mac zwei
/// unnötige Resets mit vollständigem Re-Sync von 155k Assets ausgelöst.
///
/// Liegt in `Shared`, obwohl nur der iOS-Client sie aufruft: Das Ablagekriterium
/// hier ist technisch, nicht funktional (siehe CLAUDE.md, „Key Patterns") — was
/// gegen das iOS-SDK kompiliert, ohne einen macOS-eigenen Typ zu brauchen, gehört
/// nach `Shared`. Diese Datei braucht nur Foundation, SwiftData sowie
/// `AppEnvironment`, `ImmichMacMigrationPlan` und `AppLogger` — alle vier bereits
/// hier —, erfüllt das Kriterium also unabhängig davon, wer sie ruft.
enum PhoneModelContainer {

    static let shared: ModelContainer = {
        let url = AppEnvironment.supportDirectory.appending(path: "ImmichPhone.store")
        let ergebnis = oeffneMitRettung(at: url)
        if ergebnis.rettung != .keine {
            AppEnvironment.defaults.set(true, forKey: storeZurueckgesetztKey)
        }
        return ergebnis.container
    }()

    /// Merker für die App: Der Store wurde beim Start ersetzt. `PhoneRootView`
    /// zeigt dazu einmal einen Hinweis und setzt ihn zurück.
    static let storeZurueckgesetztKey = "phoneStoreZurueckgesetzt"

    /// Was beim Öffnen passiert ist.
    enum Rettung: Equatable {
        /// Der Store ging normal auf.
        case keine
        /// Der Store war nicht zu öffnen, liegt jetzt beiseite, ein leerer ist angelegt.
        case neuAngelegt(beiseite: [URL])
        /// Nicht einmal ein leerer Store ließ sich anlegen — dieser Lauf hält alles
        /// nur im Speicher.
        case nurImSpeicher
    }

    /// Öffnet den Store; scheitert das dreimal, wird er beiseitegelegt und leer neu
    /// angelegt; scheitert auch das, bleibt ein Container im Speicher.
    ///
    /// Früher stand hier ein `fatalError`: Eine kaputte Datei hätte die App bei
    /// **jedem** Start abstürzen lassen, und ohne Neuinstallation gäbe es keinen
    /// Ausweg. Auf dem Telefon ist der Store ein Cache — Alben und Assets baut der
    /// nächste Serverabgleich neu auf. **Verloren gehen dabei die Offline-Vermerke
    /// (`OfflinePin`)**: Welche Alben offline gewählt waren, steht nur im Store; die
    /// geladenen Dateien in `OriginalCache` bleiben liegen, bis der Nutzer die Alben
    /// erneut offline stellt (dann werden sie wiederverwendet oder überschrieben).
    ///
    /// Beiseitegelegt heißt umbenannt (`…store.kaputt-<Zeitstempel>` samt `-wal`/`-shm`),
    /// nicht gelöscht — zum Nachsehen. Ältere beiseitegelegte Kopien werden dabei
    /// entfernt, damit sich bei wiederkehrendem Fehler keine Gigabyte stapeln.
    static func oeffneMitRettung(
        at url: URL,
        versuche: Int = 3,
        pause: TimeInterval = 2,
        jetzt: Date = Date()
    ) -> (container: ModelContainer, rettung: Rettung) {
        do {
            return (try make(at: url, versuche: versuche, pause: pause), .keine)
        } catch {
            AppLogger.app.error("Store bleibt zu, wird beiseitegelegt: \(error)")
        }

        let beiseite = legeBeiseite(url, jetzt: jetzt)
        do {
            return (try make(at: url, versuche: 1, pause: 0), .neuAngelegt(beiseite: beiseite))
        } catch {
            AppLogger.app.error("Auch ein leerer Store geht nicht auf, weiter nur im Speicher: \(error)")
        }

        do {
            let config = ModelConfiguration(isStoredInMemoryOnly: true)
            let container = try ModelContainer(
                for: Schema(versionedSchema: ImmichMacMigrationPlan.currentSchema),
                migrationPlan: ImmichMacMigrationPlan.self,
                configurations: config
            )
            return (container, .nurImSpeicher)
        } catch {
            // Ein Container im Speicher scheitert nur an einem kaputten Schema —
            // ein Programmierfehler, den jeder Testlauf fängt, kein Zustand des Geräts.
            fatalError("Nicht einmal ein Store im Speicher: \(error)")
        }
    }

    /// Benennt Store, `-wal` und `-shm` um und räumt ältere beiseitegelegte Kopien ab.
    /// - Returns: die neuen Pfade der beiseitegelegten Dateien.
    static func legeBeiseite(_ url: URL, jetzt: Date = Date()) -> [URL] {
        let fm = FileManager.default
        let ordner = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        let praefixe = [name, name + "-wal", name + "-shm"].map { $0 + ".kaputt-" }

        // Nur die jüngste Kopie behalten: die bisherigen gehen, bevor die neue entsteht.
        if let alle = try? fm.contentsOfDirectory(atPath: ordner.path()) {
            for datei in alle where praefixe.contains(where: { datei.hasPrefix($0) }) {
                try? fm.removeItem(at: ordner.appending(path: datei))
            }
        }

        let stempel = Int(jetzt.timeIntervalSince1970)
        var verschoben: [URL] = []
        for endung in ["", "-wal", "-shm"] {
            let quelle = ordner.appending(path: name + endung)
            guard fm.fileExists(atPath: quelle.path()) else { continue }
            let ziel = ordner.appending(path: "\(name)\(endung).kaputt-\(stempel)")
            do {
                try fm.moveItem(at: quelle, to: ziel)
                verschoben.append(ziel)
            } catch {
                // Umbenennen gescheitert: dann eben weg — sonst öffnet der nächste
                // Versuch wieder dieselbe kaputte Datei.
                AppLogger.app.error("Store-Datei nicht umzubenennen, wird gelöscht: \(error)")
                try? fm.removeItem(at: quelle)
            }
        }
        return verschoben
    }

    /// Öffnet den Store an `url`. Wirft nach `versuche` Fehlversuchen den letzten Fehler.
    static func make(at url: URL, versuche: Int = 3, pause: TimeInterval = 2) throws -> ModelContainer {
        let config = ModelConfiguration(url: url)
        var lastError: Error?

        for versuch in 1...max(1, versuche) {
            do {
                return try ModelContainer(
                    for: Schema(versionedSchema: ImmichMacMigrationPlan.currentSchema),
                    migrationPlan: ImmichMacMigrationPlan.self,
                    configurations: config
                )
            } catch {
                lastError = error
                AppLogger.app.error("Store-Öffnung fehlgeschlagen (Versuch \(versuch)/\(versuche)): \(error)")
                if versuch < versuche, pause > 0 { Thread.sleep(forTimeInterval: pause) }
            }
        }

        throw lastError ?? NSError(
            domain: "ImmichPhone", code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Store konnte nicht geöffnet werden"]
        )
    }
}
