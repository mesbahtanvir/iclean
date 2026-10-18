// Writes a SwiftData store the way the first released iclean build did, before the durable
// scan work added the chunk entity and optional columns. The result is the test fixture in
// Packages/CleanupKit/Tests/CleanupKitTests/Fixtures/previous-store, opened by
// StoreMigrationTests to prove that a phone with an existing store keeps its data.
//
// It lives in its own process on purpose: the test process must never define these model
// classes next to the real ones (same entity names), or CoreData mixes them up.
//
// Run from the repository root:
//   scripts/make-previous-store-fixture.swift
// or by hand:
//   xcrun swiftc -parse-as-library scripts/make-previous-store-fixture.swift -o /tmp/mkstore
//   /tmp/mkstore <output folder>
//   sqlite3 <output folder>/iclean.store "PRAGMA wal_checkpoint(TRUNCATE);"
//   rm -f <output folder>/iclean.store-wal <output folder>/iclean.store-shm

import Foundation
import SwiftData

@Model final class LibraryItemRecord {
    @Attribute(.unique) var assetID: String
    var kindRaw: String
    var captureDate: Date?
    var modificationDate: Date?
    var pixelWidth: Int
    var pixelHeight: Int
    var duration: Double?
    var isFavorite: Bool
    var hasAdjustments: Bool
    var isPortrait: Bool
    var isLongExposure: Bool
    var burstID: String?
    var albumNames: [String]
    var analysisSourceRaw: String
    var dHashBits: Int64?
    var thumbprint: Data?
    var featurePrint: Data?
    var sharpness: Double?
    var aestheticsScore: Double?
    var faceQuality: Double?
    var byteSize: Int64?
    var isSizeEstimated: Bool
    var analyzedAt: Date

    init(assetID: String, analyzed: Bool, modified: Date, albums: [String]) {
        self.assetID = assetID
        kindRaw = "photo"
        captureDate = modified
        modificationDate = modified
        pixelWidth = 4032
        pixelHeight = 3024
        isFavorite = false
        hasAdjustments = false
        isPortrait = false
        isLongExposure = false
        albumNames = albums
        analysisSourceRaw = analyzed ? "localPreview" : "notScanned"
        dHashBits = analyzed ? 5 : nil
        thumbprint = analyzed ? Data([1, 2, 3]) : nil
        featurePrint = analyzed ? Data([4]) : nil
        sharpness = analyzed ? 0.7 : nil
        byteSize = 1_000
        isSizeEstimated = false
        analyzedAt = Date(timeIntervalSince1970: 10)
    }
}

@Model final class KeepMarkRecord {
    @Attribute(.unique) var assetID: String
    var createdAt: Date

    init(assetID: String) {
        self.assetID = assetID
        createdAt = Date(timeIntervalSince1970: 20)
    }
}

@Model final class ScanSessionRecord {
    @Attribute(.unique) var id: UUID
    var kindRaw: String
    var stateRaw: String
    var startedAt: Date
    var finishedAt: Date?
    var totalItems: Int
    var processedItems: Int
    var notScannedCount: Int
    var lastProcessedAssetID: String?

    init(id: UUID, state: String, total: Int, processed: Int) {
        self.id = id
        kindRaw = "full"
        stateRaw = state
        startedAt = Date(timeIntervalSince1970: 30)
        totalItems = total
        processedItems = processed
        notScannedCount = 0
    }
}

@main
struct MakePreviousStore {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            print("usage: mkstore <output folder>")
            exit(2)
        }
        let folder = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let schema = Schema([
            LibraryItemRecord.self, KeepMarkRecord.self, ScanSessionRecord.self,
        ])
        let config = ModelConfiguration(
            schema: schema, url: folder.appending(path: "iclean.store"), cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: config)
        let context = ModelContext(container)
        let modified = Date(timeIntervalSince1970: 0)
        // Two stored items (one analyzed, one given up on), one keep mark, and a scan that
        // was running when the app was last closed: 2 of 4 processed.
        context.insert(
            LibraryItemRecord(
                assetID: "old-1", analyzed: true, modified: modified, albums: ["Trip"]))
        context.insert(
            LibraryItemRecord(assetID: "old-2", analyzed: false, modified: modified, albums: []))
        context.insert(KeepMarkRecord(assetID: "old-1"))
        context.insert(
            ScanSessionRecord(
                id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, state: "running",
                total: 4, processed: 2))
        try context.save()
        print("wrote \(folder.path)")
    }
}
