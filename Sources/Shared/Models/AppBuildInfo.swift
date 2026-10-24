import Foundation

/// Bereitstellung von Versions- und Build-Informationen für About- und Einstellungsansichten.
///
/// Liest bei Vorhandensein die vom Build-Skript erzeugte `BuildInfo.json` aus dem Bundle
/// (enthält Git-Commit, Commit-Zähler und exakten Build-Zeitstempel). Liegt diese nicht vor
/// (z. B. in Tests), greift ein Fallback auf `Info.plist` und das Dateidatum des Executables.
public struct AppBuildInfo: Sendable {

    public struct Metadata: Codable, Sendable {
        public let commit: String
        public let buildNumber: String
        public let buildDate: String

        public init(commit: String, buildNumber: String, buildDate: String) {
            self.commit = commit
            self.buildNumber = buildNumber
            self.buildDate = buildDate
        }
    }

    public static let shared = AppBuildInfo()

    public let marketingVersion: String
    public let buildNumber: String
    public let gitCommit: String?
    public let buildTimestamp: String?

    public init(bundle: Bundle = .main) {
        let info = bundle.infoDictionary
        let marketing = (info?["CFBundleShortVersionString"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let bundleBuild = (info?["CFBundleVersion"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        self.marketingVersion = (marketing?.isEmpty == false) ? marketing! : "1.0.0"

        var loadedMeta: Metadata? = nil
        if let metaURL = bundle.url(forResource: "BuildInfo", withExtension: "json"),
           let data = try? Data(contentsOf: metaURL) {
            loadedMeta = try? JSONDecoder().decode(Metadata.self, from: data)
        }

        if let meta = loadedMeta {
            self.buildNumber = meta.buildNumber
            self.gitCommit = meta.commit
            self.buildTimestamp = meta.buildDate
        } else {
            self.buildNumber = (bundleBuild?.isEmpty == false) ? bundleBuild! : "1"
            self.gitCommit = nil

            if let execURL = bundle.executableURL,
               let attrs = try? FileManager.default.attributesOfItem(atPath: execURL.path),
               let modDate = attrs[.modificationDate] as? Date {
                let df = DateFormatter()
                df.dateFormat = "yyyy-MM-dd HH:mm"
                self.buildTimestamp = df.string(from: modDate)
            } else {
                self.buildTimestamp = nil
            }
        }
    }

    /// Beispiel: "Version 1.0.0"
    public var versionDisplay: String {
        "Version \(marketingVersion)"
    }

    /// Kompaktes Detail für About-Screen, z. B.
    /// "Build 1309 (e9a5a06) · 2026-10-18 15:00:12"
    public var buildDetail: String {
        var parts: [String] = []

        var buildStr = "Build \(buildNumber)"
        if let commit = gitCommit, !commit.isEmpty {
            buildStr += " (\(commit))"
        }
        parts.append(buildStr)

        if let time = buildTimestamp, !time.isEmpty {
            parts.append(time)
        }

        return parts.joined(separator: " · ")
    }
}
