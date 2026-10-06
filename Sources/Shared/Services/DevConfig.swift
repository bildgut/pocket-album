import Foundation

/// Reads dev config from .env file in the project root.
/// Format: KEY=VALUE, one per line. Lines starting with # are ignored.
enum DevConfig {
    private static var values: [String: String] = {
        // Look for .env relative to the executable
        let paths = [
            FileManager.default.currentDirectoryPath + "/.env",
            Bundle.main.bundlePath + "/../../../.env",  // SPM .build/debug/
        ]

        for path in paths {
            if let contents = try? String(contentsOfFile: path, encoding: .utf8) {
                var dict: [String: String] = [:]
                for line in contents.components(separatedBy: .newlines) {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
                    let parts = trimmed.split(separator: "=", maxSplits: 1)
                    guard parts.count == 2 else { continue }
                    dict[String(parts[0])] = String(parts[1])
                }
                AppLogger.app.info("Loaded .env from: \(path)")
                return dict
            }
        }
        return [:]
    }()

    static var immichURL: String? { values["IMMICH_URL"] }
    static var immichAPIKey: String? { values["IMMICH_API_KEY"] }
    static var immichEmail: String? { values["IMMICH_EMAIL"] }
    static var immichPassword: String? { values["IMMICH_PASSWORD"] }
}
