import Foundation
import SwiftData
import Testing
@testable import ImmichPhone

@Suite("Offline-Status: Bytes auf dem Gerät")
@MainActor
struct OfflineStatusAufPlatteTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(
            for: Schema(versionedSchema: ImmichMacMigrationPlan.currentSchema),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    @Test func zaehltDateigroessenUndLaesstAusgeschlosseneVideosWeg() throws {
        let c = try container()
        let ctx = ModelContext(c)
        let m = "test-\(UUID().uuidString.prefix(8))"
        let ordner = LocalFileCacheManager.cacheDirectory.appending(path: m)
        try FileManager.default.createDirectory(at: ordner, withIntermediateDirectories: true)

        func asset(_ id: String, video: Bool, datei: Int?) throws {
            let a = CachedAsset(from: Asset(
                id: id, type: video ? .video : .image, originalFileName: id,
                fileCreatedAt: "2024-01-01T00:00:00.000Z", fileModifiedAt: "2024-01-01T00:00:00.000Z",
                isFavorite: false))
            a.fileSizeInByte = 99_000_000   // Servergröße — darf nicht zählen
            if let datei {
                let name = "\(id).vorschau.jpg"
                try Data(count: datei).write(to: ordner.appending(path: name))
                a.localFilePath = "\(m)/\(name)"
            }
            ctx.insert(a)
        }
        try asset("f1", video: false, datei: 1_000)
        try asset("f2", video: false, datei: 2_000)
        try asset("f3", video: false, datei: nil)
        try asset("v1", video: true, datei: nil)
        try ctx.save()
        let ids = ["f1", "f2", "f3", "v1"]

        let ohneVideos = LocalFileCacheManager.statusAufPlatte(
            forAssetIds: ids, wahl: OfflineWahl(fotos: .vorschau, videos: .keine, mobilfunk: false), container: c)
        #expect(ohneVideos.present == 2)
        #expect(ohneVideos.expected == 3)
        #expect(ohneVideos.bytes == 3_000)

        let mitVideos = LocalFileCacheManager.statusAufPlatte(forAssetIds: ids, wahl: nil, container: c)
        #expect(mitVideos.expected == 4)
        #expect(mitVideos.bytes == 3_000)
    }

    @Test func leer() throws {
        let s = LocalFileCacheManager.statusAufPlatte(forAssetIds: [], wahl: nil, container: try container())
        #expect(s.present == 0 && s.expected == 0 && s.bytes == 0)
    }
}
