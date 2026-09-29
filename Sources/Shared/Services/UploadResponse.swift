import Foundation

// Aus UploadManager.swift herausgelöst: `UploadResponse` braucht auch
// `EditedAssetUploadService`, das die iOS-App mitkompiliert — UploadManager
// selbst (PhotoKit) ist dort ausgeschlossen, siehe project.yml.

struct UploadResponse: Decodable {
    let id: String
    let status: String?
}

// MARK: - Data multipart helper

extension Data {
    mutating func appendMultipart(boundary: String, name: String, value: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append("\(value)\r\n".data(using: .utf8)!)
    }
}
