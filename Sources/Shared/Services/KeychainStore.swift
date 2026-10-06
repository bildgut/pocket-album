import Foundation
import Security

/// Secure credential storage using a local file in Application Support.
///
/// Stores credentials as JSON in `~/Library/Application Support/ImmichMac/credentials.json`
/// with `0600` (owner-only) file permissions. This avoids macOS Keychain entirely,
/// eliminating the repeated password prompts that occur under ad-hoc / "Sign to
/// Run Locally" signing.
///
/// Call `loadAll()` once at app startup to read credentials into memory.
/// All subsequent `read()` calls are pure in-memory lookups.
enum KeychainStore {
    private static let service = "com.ralksta.immichmac"
    /// Schlüssel der Immich-Verbindung — werden beim Abmelden gelöscht.
    static let connectionKeys = ["serverURL", "apiKey", "sessionToken", "email", "password"]
    /// App-eigene Geheimnisse, die eine Ab-/Neuanmeldung überleben sollen.
    static let appKeys = ["geminiApiKey"]
    static let allKeys = connectionKeys + appKeys

    /// Schlüssel des Gemini-API-Keys für den KI-Zuschnitt.
    static let geminiApiKeyKey = "geminiApiKey"

    // One-time migration flags
    private static let userDefaultsMigrationKey = "com.immichmac.keychain_migrated"
    private static let fileMigrationKey = "com.immichmac.file_credentials_migrated"

    /// In-memory credential store.
    ///
    /// Zugriff ausschließlich unter ``lock`` — die statischen Methoden sind
    /// synchron und werden aus beliebigen Threads aufgerufen (Verbindungsaufbau,
    /// Sync-Tasks, UI). Ohne Absicherung verliert das Dictionary bei parallelen
    /// Schreibvorgängen Einträge oder korrumpiert seinen Speicher.
    nonisolated(unsafe) private static var credentials = [String: String]()

    private static let lock = NSLock()

    /// Führt `body` unter dem Lock aus.
    private static func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Path to the credentials file.
    private static var credentialsFileURL: URL {
        AppEnvironment.supportDirectory.appending(path: "credentials.json")
    }

    // MARK: - Bulk Load

    /// Reads all credentials from disk into memory.
    /// Also performs one-time migration from the legacy Keychain / UserDefaults if needed.
    /// Safe to call multiple times — subsequent calls are a cheap no-op if credentials
    /// are already loaded and the migrations have been completed.
    static func loadAll() {
        // 1. Load existing file-based credentials first so migrations can merge into them,
        //    not overwrite them with a partial set.
        if let data = try? Data(contentsOf: credentialsFileURL),
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            withLock { credentials = dict }
        }

        // 2. Run migrations — they only add/overwrite individual keys, they do not reset
        //    the entire credentials dict, so existing values are always preserved.
        //    Skipped under XCTest: migrations delete legacy Keychain entries and write
        //    flags to the real UserDefaults — test runs must not touch either.
        guard !AppEnvironment.isRunningTests else { return }
        migrateFromKeychainIfNeeded()
        migrateFromUserDefaultsIfNeeded()
    }

    // MARK: - Public API

    static func save(key: String, value: String) {
        withLock {
            credentials[key] = value
            writeToDiskLocked()
        }
    }

    static func read(key: String) -> String? {
        withLock { credentials[key] }
    }

    static func delete(key: String) {
        withLock {
            credentials[key] = nil
            writeToDiskLocked()
        }
    }

    /// Löscht die Verbindungsdaten (Abmelden). App-eigene Schlüssel wie der
    /// Gemini-API-Key bleiben erhalten — ein Serverwechsel ist kein Grund, sie zu
    /// verlieren.
    static func deleteAll() {
        withLock {
            for key in connectionKeys { credentials[key] = nil }
            if credentials.isEmpty {
                try? FileManager.default.removeItem(at: credentialsFileURL)
            } else {
                writeToDiskLocked()
            }
        }
    }

    // MARK: - Private File I/O

    /// Writes the current credentials dictionary to disk with owner-only permissions.
    ///
    /// Nur mit gehaltenem ``lock`` aufrufen: die Methode liest ``credentials``,
    /// und das Schreiben gehört in dieselbe kritische Sektion wie die Änderung —
    /// sonst kann ein älterer Stand einen neueren auf der Platte überholen.
    private static func writeToDiskLocked() {
        guard let data = try? JSONEncoder().encode(credentials) else { return }
        try? Self.writeProtected(data, to: credentialsFileURL)
    }

    /// Schreibt atomar mit Eigentümer-Rechten, vom Backup ausgeschlossen und auf iOS
    /// mit expliziter Schutzklasse.
    ///
    /// `.completeUntilFirstUserAuthentication` statt `.complete`: PR 2c bringt einen
    /// Hintergrund-Refresh, der bei gesperrtem Gerät lesen muss. `.complete` würde ihn
    /// still scheitern lassen. Backup-Ausschluss ist plattformübergreifend messbar und
    /// wird getestet; die Schutzklasse ist auf macOS bedeutungslos.
    static func writeProtected(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var werte = URLResourceValues()
        werte.isExcludedFromBackup = true
        var ziel = url
        try ziel.setResourceValues(werte)
        #if !os(macOS)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
    }

    // MARK: - Migration: Legacy Keychain → File

    /// One-time migration from the legacy Keychain to file-based storage.
    /// Merges migrated keys into the existing credentials dict so no data is lost.
    private static func migrateFromKeychainIfNeeded() {
        let defaults = AppEnvironment.defaults
        guard !defaults.bool(forKey: fileMigrationKey) else { return }

        // Legacy-Werte außerhalb des Locks einsammeln — der Keychain-Zugriff
        // gehört nicht in die kritische Sektion.
        var legacyValues: [String: String] = [:]
        for key in allKeys {
            if let value = readFromLegacyKeychain(key: key) {
                legacyValues[key] = value
                deleteFromLegacyKeychain(key: key)
            }
        }

        let migrated = withLock { () -> Int in
            var count = 0
            for (key, value) in legacyValues where credentials[key] == nil {
                // Only overwrite if we don't already have a value from the file
                credentials[key] = value
                count += 1
            }
            if count > 0 { writeToDiskLocked() }
            return count
        }

        if migrated > 0 {
            AppLogger.app.info("Migrated \(migrated) credential(s) from Keychain to file storage")
        }

        defaults.set(true, forKey: fileMigrationKey)
    }

    /// Read from the legacy Keychain (for migration only).
    private static func readFromLegacyKeychain(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    /// Delete from the legacy Keychain (for migration only).
    private static func deleteFromLegacyKeychain(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Migration: UserDefaults → File

    /// One-time migration from UserDefaults → file storage.
    /// Merges migrated keys; does not overwrite values already present in the file.
    static func migrateFromUserDefaultsIfNeeded() {
        let defaults = AppEnvironment.defaults
        guard !defaults.bool(forKey: userDefaultsMigrationKey) else { return }

        let oldPrefix = "com.immichmac."

        var legacyValues: [String: String] = [:]
        for key in allKeys {
            if let value = defaults.string(forKey: oldPrefix + key) {
                legacyValues[key] = value
                defaults.removeObject(forKey: oldPrefix + key)
            }
        }

        let migrated = withLock { () -> Int in
            var count = 0
            for (key, value) in legacyValues where credentials[key] == nil {
                // Only overwrite if we don't already have a value from the file
                credentials[key] = value
                count += 1
            }
            if count > 0 { writeToDiskLocked() }
            return count
        }

        if migrated > 0 {
            AppLogger.app.info("Migrated \(migrated) credential(s) from UserDefaults to file storage")
        }

        defaults.set(true, forKey: userDefaultsMigrationKey)
    }
}
