import Foundation
import GRDB

/// Database bootstrap: WAL-mode SQLite in the App Group container
/// (SCAN_PIPELINE.md §4, APP_PLATFORM.md §6). GRDB DatabasePool = concurrent
/// UI reads against pipeline writes.
public struct AppDatabase: Sendable {
    public let pool: DatabasePool

    public static let appGroupIdentifier = "group.com.iclean.shared"

    public init(pool: DatabasePool) throws {
        self.pool = pool
        try Self.migrator.migrate(pool)
    }

    /// Production location: the App Group container.
    public static func open() throws -> AppDatabase {
        let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)

        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        let pool = try DatabasePool(
            path: container.appendingPathComponent("iclean.sqlite").path,
            configuration: configuration
        )
        return try AppDatabase(pool: pool)
    }

    /// In-memory database for tests.
    public static func inMemory() throws -> AppDatabase {
        // DatabaseQueue would be more natural for in-memory, but the store code
        // is written against DatabasePool; a shared-cache temp file works for tests.
        let path = NSTemporaryDirectory() + "iclean-test-\(UUID().uuidString).sqlite"
        let pool = try DatabasePool(path: path)
        return try AppDatabase(pool: pool)
    }

    /// Schema v1 — SCAN_PIPELINE.md §4 verbatim, plus APP_PLATFORM.md §2.2.
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "asset") { t in
                t.primaryKey("id", .text)
                t.column("mediaType", .integer).notNull()
                t.column("subtypes", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .double)
                t.column("modifiedAt", .double)
                t.column("width", .integer).notNull().defaults(to: 0)
                t.column("height", .integer).notNull().defaults(to: 0)
                t.column("duration", .double).notNull().defaults(to: 0)
                t.column("isFavorite", .boolean).notNull().defaults(to: false)
                t.column("burstId", .text)
                t.column("representsBurst", .boolean).notNull().defaults(to: false)
                t.column("hasLocation", .boolean).notNull().defaults(to: false)
                t.column("latBucket", .integer)
                t.column("lonBucket", .integer)
                t.column("sessionId", .integer).indexed()
                t.column("cloudId", .text)
                t.column("filename", .text)
                t.column("uti", .text)
                t.column("fileSize", .integer)
                t.column("fileSizeIsEstimate", .boolean).notNull().defaults(to: false)
                t.column("isEdited", .boolean).notNull().defaults(to: false)
                t.column("hasRawResource", .boolean).notNull().defaults(to: false)
                t.column("thumbAvailability", .integer).notNull().defaults(to: 0)
                t.column("originalAvailability", .integer).notNull().defaults(to: 0)
                t.column("deletedAt", .double)
            }
            try db.create(index: "asset_createdAt", on: "asset", columns: ["createdAt"])

            try db.create(table: "scan_state") { t in
                t.column("assetId", .text).notNull()
                t.column("stage", .text).notNull()
                t.column("status", .integer).notNull().defaults(to: 0)
                t.column("detectorVersion", .integer).notNull().defaults(to: 0)
                t.column("updatedAt", .double)
                t.column("retryCount", .integer).notNull().defaults(to: 0)
                t.column("nextRetryAt", .double)
                t.primaryKey(["assetId", "stage"])
            }
            // The batch query's covering index (SCAN_PIPELINE.md §4).
            try db.create(
                index: "scan_state_batch",
                on: "scan_state",
                columns: ["stage", "status", "detectorVersion"]
            )

            // One wide row per asset (SCAN_PIPELINE.md §4). Hashes as INTEGER
            // (stored as Int64 bit patterns — SQLite integers are 64-bit).
            try db.create(table: "asset_signal") { t in
                t.primaryKey("assetId", .text)
                t.column("phash", .integer)
                t.column("dhash", .integer)
                t.column("lapVar", .double)
                t.column("meanLum", .double)
                t.column("bottomConc", .double)
                t.column("pixelVar", .double)
                t.column("cornerBlob", .boolean)
                t.column("faceCount", .integer)
                t.column("bestFaceQuality", .double)
                t.column("eyesOpenMin", .double)
                t.column("saliencyArea", .double)
                t.column("noFaces1024", .boolean)
            }

            try db.create(table: "album") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull().defaults(to: "")
            }
            try db.create(table: "album_member") { t in
                t.column("albumId", .text).notNull()
                t.column("assetId", .text).notNull()
                t.primaryKey(["albumId", "assetId"])
            }
            try db.create(index: "album_member_asset", on: "album_member", columns: ["assetId"])

            try db.create(table: "session") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("startAt", .double)
                t.column("endAt", .double)
                t.column("isUndated", .boolean).notNull().defaults(to: false)
                t.column("assetCount", .integer).notNull().defaults(to: 0)
                t.column("dirty", .boolean).notNull().defaults(to: true)
            }

            try db.create(table: "proposal") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("actionType", .text).notNull()
                t.column("unit", .text).notNull()
                t.column("dedupeKey", .text).notNull().unique()
                t.column("sessionId", .integer)
                t.column("memberIds", .text).notNull() // JSON array
                t.column("keeperId", .text)
                t.column("reasonParams", .text).notNull() // JSON
                t.column("regretTier", .integer).notNull().defaults(to: 2)
                t.column("confidence", .double).notNull().defaults(to: 0)
                t.column("estBytes", .integer).notNull().defaults(to: 0)
                t.column("score", .double).notNull().defaults(to: 0)
                t.column("humility", .boolean).notNull().defaults(to: false)
                t.column("state", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .double).notNull()
                t.column("decidedAt", .double)
            }
            try db.create(index: "proposal_deck", on: "proposal", columns: ["state", "actionType", "score"])

            try db.create(table: "suppression") { t in
                t.column("assetId", .text).notNull()
                t.column("actionType", .text).notNull()
                t.column("createdAt", .double).notNull()
                t.primaryKey(["assetId", "actionType"])
            }

            try db.create(table: "decision_log") { t in
                t.column("uiSessionId", .integer).notNull()
                t.column("seq", .integer).notNull()
                t.column("proposalId", .integer).notNull()
                t.column("verdict", .integer).notNull()
                t.column("decidedAt", .double).notNull()
                t.column("restored", .boolean).notNull().defaults(to: false)
                t.primaryKey(["uiSessionId", "seq"])
            }

            try db.create(table: "staging_note") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("proposalId", .integer).notNull()
                t.column("kind", .integer).notNull()
                t.column("createdAt", .double).notNull()
            }

            try db.create(table: "commit_journal") { t in
                t.column("commitId", .text).notNull()
                t.column("chunkIndex", .integer).notNull()
                t.column("assetIds", .text).notNull() // JSON array
                t.column("state", .integer).notNull().defaults(to: 0) // pending/done/aborted
                t.column("createdAt", .double).notNull()
                t.column("resolvedAt", .double)
                t.primaryKey(["commitId", "chunkIndex"])
            }

            try db.create(table: "user_calibration") { t in
                t.primaryKey("detectorId", .text)
                t.column("stepOffset", .integer).notNull().defaults(to: 0)
                t.column("decisionsSinceChange", .integer).notNull().defaults(to: 0)
            }

            try db.create(table: "telemetry_event") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("kind", .text).notNull()
                t.column("paramsJSON", .text)
                t.column("at", .double).notNull()
            }

            try db.create(table: "user_state") { t in
                t.primaryKey("key", .text)
                t.column("value", .blob)
            }

            try db.create(table: "meta") { t in
                t.primaryKey("key", .text)
                t.column("value", .blob)
            }
        }

        return migrator
    }
}
