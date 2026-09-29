import Foundation

/// Runtime environment detection and the single source of truth for the
/// app's persistent storage location.
///
/// The unit tests use ImmichMac.app as TEST_HOST, so the full app lifecycle
/// (AppDelegate, ConnectionManager, SwiftUI scenes) runs during every test
/// invocation. To keep test runs from ever touching — or corrupting — the
/// real user data under `~/Library/Application Support/ImmichMac/`, all
/// storage is redirected to a per-process temporary directory while running
/// under XCTest, and network sync / credential migrations are skipped.
enum AppEnvironment {

    /// True when the process was launched by the XCTest runner
    /// (covers both XCTest and Swift Testing, which share the same runner).
    static let isRunningTests: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil
            || env["XCTestBundlePath"] != nil
            || env["XCTestSessionIdentifier"] != nil
            || NSClassFromString("XCTestCase") != nil
    }()

    /// Root directory for all persistent app data
    /// (`ImmichMac.store`, `grid_index.sqlite`, `credentials.json`, `OriginalCache/`).
    ///
    /// - Normal launch: `~/Library/Application Support/ImmichMac/`
    /// - Test host: `$TMPDIR/ImmichMacTests-<pid>/` — per-process, so parallel
    ///   test-host instances can never race each other on the same SQLite files.
    static let supportDirectory: URL = {
        let dir: URL
        if isRunningTests {
            dir = FileManager.default.temporaryDirectory.appending(
                path: "ImmichMacTests-\(ProcessInfo.processInfo.processIdentifier)",
                directoryHint: .isDirectory
            )
        } else {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first!
            dir = appSupport.appending(path: "ImmichMac", directoryHint: .isDirectory)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Ablage für persistente App-Marker (einmalige Migrationsschritte, Resume-Cursor).
    ///
    /// Dieselbe Isolation wie bei `supportDirectory`, nur für Preferences: Das
    /// Testbundle ist app-gehostet, `UserDefaults.standard` im Test ist also **dieselbe
    /// Domain, die die ausgelieferte App liest**. Ein abgebrochener Testlauf könnte dort
    /// sonst z. B. `gridIndex.exifV8BackfillDone` zurücklassen und den echten,
    /// einmaligen Backfill des Nutzers dauerhaft überspringen.
    ///
    /// - Normaler Start: `.standard`.
    /// - Test-Host: eine prozess-eigene Suite — parallele Test-Hosts sehen sich
    ///   dadurch auch nicht gegenseitig.
    static let defaults: UserDefaults = {
        guard isRunningTests else { return .standard }
        let suiteName = "ImmichMacTests-\(ProcessInfo.processInfo.processIdentifier)"
        // Kein `?? .standard`-Fallback: Genau das wäre die Domain, vor der dieser ganze
        // Mechanismus schützen soll — ein Testlauf, der z. B.
        // `gridIndex.exifV8BackfillDone` in die echte App-Domain schreibt und damit den
        // einmaligen Backfill des Nutzers dauerhaft überspringt. Lieber laut abstürzen als
        // still in den unsicheren Fall zurückfallen.
        guard let suite = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("UserDefaults(suiteName: \(suiteName)) lieferte nil — ein Fallback auf .standard würde Test-Marker in die echte App-Domain com.ralksta.immichmac schreiben")
        }
        // Frisch starten: eine gleichnamige Suite eines früheren Laufs mit derselben
        // PID darf den aktuellen nicht beeinflussen.
        suite.removePersistentDomain(forName: suiteName)
        return suite
    }()
}
