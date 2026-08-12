import Foundation
import GRDB
import PhotoGateway
import ScanEngine

public enum ProposalState: Int, Sendable, Codable {
    case pending = 0
    case shown = 1
    case approved = 2
    case rejected = 3
    case staged = 4
    case committed = 5
    case invalidated = 6
}

/// GRDB implementation of the engine's persistence seam (SCAN_PIPELINE.md §12).
public final class GRDBPipelineStore: PipelineStore, @unchecked Sendable {
    private let database: AppDatabase
    private var pool: DatabasePool { database.pool }

    public init(database: AppDatabase) {
        self.database = database
    }

    // MARK: - Assets & scan state

    public func upsertAssets(_ stubs: [AssetStub]) async throws {
        guard !stubs.isEmpty else { return }
        try await pool.write { db in
            for stub in stubs {
                try db.execute(
                    sql: """
                    INSERT INTO asset (id, mediaType, subtypes, createdAt, modifiedAt, width, height,
                                       duration, isFavorite, burstId, representsBurst, hasLocation,
                                       latBucket, lonBucket)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        modifiedAt = excluded.modifiedAt,
                        isFavorite = excluded.isFavorite,
                        subtypes = excluded.subtypes,
                        deletedAt = NULL
                    """,
                    arguments: [
                        stub.id, stub.mediaKind.rawValue, stub.subtypes.rawValue,
                        stub.createdAt?.timeIntervalSince1970, stub.modifiedAt?.timeIntervalSince1970,
                        stub.pixelWidth, stub.pixelHeight, stub.duration, stub.isFavorite,
                        stub.burstId, stub.representsBurst, stub.locationBucket != nil,
                        stub.locationBucket?.lat, stub.locationBucket?.lon,
                    ]
                )
                // S0 creates scan_state rows for exactly {s1, s2, s3, s4} (§11).
                for stage in [ScanStage.s1, .s2, .s3, .s4] {
                    try db.execute(
                        sql: """
                        INSERT OR IGNORE INTO scan_state (assetId, stage, status, detectorVersion)
                        VALUES (?, ?, 0, 0)
                        """,
                        arguments: [stub.id, stage.rawValue]
                    )
                }
            }
        }
    }

    public func markAssetsDeleted(ids: [String], at date: Date) async throws {
        guard !ids.isEmpty else { return }
        try await pool.write { db in
            for chunk in ids.chunked(500) {
                let placeholders = databaseQuestionMarks(count: chunk.count)
                try db.execute(
                    sql: "UPDATE asset SET deletedAt = ? WHERE id IN (\(placeholders))",
                    arguments: StatementArguments([date.timeIntervalSince1970] + chunk)
                )
            }
        }
    }

    public func allAssetIds() async throws -> Set<String> {
        try await pool.read { db in
            Set(try String.fetchAll(db, sql: "SELECT id FROM asset WHERE deletedAt IS NULL"))
        }
    }

    public func assetStubs(ids: [String]) async throws -> [AssetStub] {
        guard !ids.isEmpty else { return [] }
        return try await pool.read { db in
            let placeholders = databaseQuestionMarks(count: ids.count)
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM asset WHERE id IN (\(placeholders)) AND deletedAt IS NULL",
                arguments: StatementArguments(ids)
            )
            return rows.map(Self.stub(from:))
        }
    }

    public func nextBatch(stage: ScanStage, limit: Int, now: Date, currentVersion: Int) async throws -> [String] {
        try await pool.read { db in
            // pending OR retry-eligible failed OR done-with-stale-version (§11).
            try String.fetchAll(
                db,
                sql: """
                SELECT s.assetId FROM scan_state s
                JOIN asset a ON a.id = s.assetId AND a.deletedAt IS NULL
                WHERE s.stage = ?
                  AND (s.status = 0
                       OR (s.status = 2 AND s.retryCount < 3 AND (s.nextRetryAt IS NULL OR s.nextRetryAt < ?))
                       OR (s.status = 1 AND s.detectorVersion < ?))
                ORDER BY a.createdAt DESC
                LIMIT ?
                """,
                arguments: [stage.rawValue, now.timeIntervalSince1970, currentVersion, limit]
            )
        }
    }

    public func recordStageOutcome(
        assetIds: [String], stage: ScanStage, status: StageStatus, version: Int, now: Date
    ) async throws {
        guard !assetIds.isEmpty else { return }
        try await pool.write { db in
            for id in assetIds {
                switch status {
                case .failed:
                    // nextRetryAt = updatedAt + 60·4^retryCount (§11).
                    try db.execute(
                        sql: """
                        UPDATE scan_state
                        SET status = 2, updatedAt = ?, retryCount = retryCount + 1,
                            nextRetryAt = ? + 60.0 * (CASE retryCount WHEN 0 THEN 1 WHEN 1 THEN 4 ELSE 16 END)
                        WHERE assetId = ? AND stage = ?
                        """,
                        arguments: [now.timeIntervalSince1970, now.timeIntervalSince1970, id, stage.rawValue]
                    )
                default:
                    try db.execute(
                        sql: """
                        UPDATE scan_state
                        SET status = ?, updatedAt = ?, detectorVersion = ?
                        WHERE assetId = ? AND stage = ?
                        """,
                        arguments: [status.rawValue, now.timeIntervalSince1970, version, id, stage.rawValue]
                    )
                }
            }
        }
    }

    public func resetNeedsConnection(now: Date) async throws {
        // One UPDATE on app-foreground with reachability up (§11).
        try await pool.write { db in
            try db.execute(sql: "UPDATE scan_state SET status = 0 WHERE status = 3")
        }
    }

    public func pendingWorkExists() async throws -> Bool {
        try await pool.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM scan_state WHERE status = 0 OR (status = 2 AND retryCount < 3))"
            ) ?? false
        }
    }

    // MARK: - Signals

    public func writeSignals(_ signals: [AssetSignals]) async throws {
        guard !signals.isEmpty else { return }
        try await pool.write { db in
            for signal in signals {
                try db.execute(
                    sql: """
                    INSERT INTO asset_signal (assetId, phash, dhash, lapVar, meanLum, bottomConc,
                                              pixelVar, cornerBlob, faceCount, bestFaceQuality,
                                              eyesOpenMin, saliencyArea, noFaces1024)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(assetId) DO UPDATE SET
                        phash = COALESCE(excluded.phash, asset_signal.phash),
                        dhash = COALESCE(excluded.dhash, asset_signal.dhash),
                        lapVar = COALESCE(excluded.lapVar, asset_signal.lapVar),
                        meanLum = COALESCE(excluded.meanLum, asset_signal.meanLum),
                        bottomConc = COALESCE(excluded.bottomConc, asset_signal.bottomConc),
                        pixelVar = COALESCE(excluded.pixelVar, asset_signal.pixelVar),
                        cornerBlob = COALESCE(excluded.cornerBlob, asset_signal.cornerBlob),
                        faceCount = COALESCE(excluded.faceCount, asset_signal.faceCount),
                        bestFaceQuality = COALESCE(excluded.bestFaceQuality, asset_signal.bestFaceQuality),
                        eyesOpenMin = COALESCE(excluded.eyesOpenMin, asset_signal.eyesOpenMin),
                        saliencyArea = COALESCE(excluded.saliencyArea, asset_signal.saliencyArea),
                        noFaces1024 = COALESCE(excluded.noFaces1024, asset_signal.noFaces1024)
                    """,
                    arguments: [
                        signal.assetId,
                        signal.phash.map { Int64(bitPattern: $0) },
                        signal.dhash.map { Int64(bitPattern: $0) },
                        signal.laplacianVariance, signal.meanLuminance,
                        signal.luminanceBottomConcentration, signal.pixelVariance,
                        signal.cornerBlobSuspect, signal.faceCount, signal.bestFaceQuality,
                        signal.eyesOpenMin, signal.saliencyArea, signal.noFacesConfirmedAt1024,
                    ]
                )
            }
        }
    }

    public func writeResourceInfo(assetId: String, info: ResourceInfo) async throws {
        try await pool.write { db in
            try db.execute(
                sql: """
                UPDATE asset SET filename = ?, uti = ?, fileSize = ?, fileSizeIsEstimate = ?,
                                 isEdited = ?, hasRawResource = ?
                WHERE id = ?
                """,
                arguments: [
                    info.filename, info.uti, info.fileSize, info.fileSizeIsEstimate,
                    info.isEdited, info.hasRawResource, assetId,
                ]
            )
        }
    }

    public func signals(ids: [String]) async throws -> [String: AssetSignals] {
        guard !ids.isEmpty else { return [:] }
        return try await pool.read { db in
            let placeholders = databaseQuestionMarks(count: ids.count)
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM asset_signal WHERE assetId IN (\(placeholders))",
                arguments: StatementArguments(ids)
            )
            var out: [String: AssetSignals] = [:]
            for row in rows {
                var signal = AssetSignals(assetId: row["assetId"])
                signal.phash = (row["phash"] as Int64?).map { UInt64(bitPattern: $0) }
                signal.dhash = (row["dhash"] as Int64?).map { UInt64(bitPattern: $0) }
                signal.laplacianVariance = row["lapVar"]
                signal.meanLuminance = row["meanLum"]
                signal.luminanceBottomConcentration = row["bottomConc"]
                signal.pixelVariance = row["pixelVar"]
                signal.cornerBlobSuspect = row["cornerBlob"]
                signal.faceCount = row["faceCount"]
                signal.bestFaceQuality = row["bestFaceQuality"]
                signal.eyesOpenMin = row["eyesOpenMin"]
                signal.saliencyArea = row["saliencyArea"]
                signal.noFacesConfirmedAt1024 = row["noFaces1024"]
                out[signal.assetId] = signal
            }
            return out
        }
    }

    public func resourceInfos(ids: [String]) async throws -> [String: ResourceInfo] {
        guard !ids.isEmpty else { return [:] }
        return try await pool.read { db in
            let placeholders = databaseQuestionMarks(count: ids.count)
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT id, filename, uti, fileSize, fileSizeIsEstimate, isEdited, hasRawResource
                FROM asset WHERE id IN (\(placeholders))
                """,
                arguments: StatementArguments(ids)
            )
            var out: [String: ResourceInfo] = [:]
            for row in rows {
                out[row["id"]] = ResourceInfo(
                    filename: row["filename"],
                    uti: row["uti"],
                    fileSize: row["fileSize"],
                    fileSizeIsEstimate: row["fileSizeIsEstimate"] ?? false,
                    isEdited: row["isEdited"] ?? false,
                    hasRawResource: row["hasRawResource"] ?? false
                )
            }
            return out
        }
    }

    // MARK: - Albums (S1.5)

    public func replaceAlbums(_ albums: [AlbumInfo]) async throws {
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM album")
            try db.execute(sql: "DELETE FROM album_member")
            for album in albums {
                try db.execute(
                    sql: "INSERT INTO album (id, title) VALUES (?, ?)",
                    arguments: [album.id, album.title]
                )
                for member in album.memberIds {
                    try db.execute(
                        sql: "INSERT OR IGNORE INTO album_member (albumId, assetId) VALUES (?, ?)",
                        arguments: [album.id, member]
                    )
                }
            }
        }
    }

    public func albumMembership(ids: [String]) async throws -> [String: [String]] {
        guard !ids.isEmpty else { return [:] }
        return try await pool.read { db in
            let placeholders = databaseQuestionMarks(count: ids.count)
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT assetId, albumId FROM album_member WHERE assetId IN (\(placeholders))",
                arguments: StatementArguments(ids)
            )
            var out: [String: [String]] = [:]
            for row in rows {
                out[row["assetId"], default: []].append(row["albumId"])
            }
            return out
        }
    }

    // MARK: - Sessions

    public func replaceSessions(_ drafts: [Sessionizer.SessionDraft]) async throws -> [Int64] {
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM session")
            var ids: [Int64] = []
            for draft in drafts {
                try db.execute(
                    sql: "INSERT INTO session (startAt, endAt, isUndated, assetCount, dirty) VALUES (?, ?, ?, ?, 1)",
                    arguments: [
                        draft.startAt?.timeIntervalSince1970,
                        draft.endAt?.timeIntervalSince1970,
                        draft.isUndated,
                        draft.memberIds.count,
                    ]
                )
                let sessionId = db.lastInsertedRowID
                ids.append(sessionId)
                for member in draft.memberIds {
                    try db.execute(
                        sql: "UPDATE asset SET sessionId = ? WHERE id = ?",
                        arguments: [sessionId, member]
                    )
                }
            }
            return ids
        }
    }

    public func dirtySessionIds() async throws -> [Int64] {
        try await pool.read { db in
            try Int64.fetchAll(db, sql: "SELECT id FROM session WHERE dirty = 1 AND isUndated = 0 ORDER BY endAt DESC")
        }
    }

    public func sessionMembers(sessionId: Int64) async throws -> [AssetStub] {
        try await pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM asset WHERE sessionId = ? AND deletedAt IS NULL",
                arguments: [sessionId]
            )
            return rows.map(Self.stub(from:))
        }
    }

    public func markSessionClean(sessionId: Int64) async throws {
        try await pool.write { db in
            try db.execute(sql: "UPDATE session SET dirty = 0 WHERE id = ?", arguments: [sessionId])
        }
    }

    public func sessionsReadyForClustering(now: Date) async throws -> [Int64] {
        try await pool.read { db in
            // Cluster-eligible: every member's S4 row is terminal (SCAN_PIPELINE.md §5).
            try Int64.fetchAll(
                db,
                sql: """
                SELECT s.id FROM session s
                WHERE s.dirty = 1 AND s.isUndated = 0
                  AND NOT EXISTS (
                    SELECT 1 FROM asset a
                    JOIN scan_state st ON st.assetId = a.id AND st.stage = 's4'
                    WHERE a.sessionId = s.id AND a.deletedAt IS NULL
                      AND st.status = 0
                      AND NOT (st.status = 2 AND st.retryCount >= 3)
                  )
                ORDER BY s.endAt DESC
                LIMIT 5
                """
            )
        }
    }

    // MARK: - Proposals & suppression

    public func upsertProposals(_ drafts: [ProposalDraft], clusterSessionId: Int64?) async throws {
        guard !drafts.isEmpty else { return }
        let encoder = JSONEncoder()
        try await pool.write { db in
            for draft in drafts {
                let memberJSON = String(data: try encoder.encode(draft.memberIds), encoding: .utf8) ?? "[]"
                let reasonJSON = String(data: try encoder.encode(draft.reason), encoding: .utf8) ?? "{}"
                let score = ProposalEmitter.deckScore(
                    estBytes: draft.estBytes,
                    confidence: draft.confidence,
                    decisionCostSeconds: draft.unit == .cluster ? 8 : 1.5,
                    regretTier: draft.regretTier
                )
                // Upsert on dedupeKey: unchanged regenerations keep their state (§5-S7).
                try db.execute(
                    sql: """
                    INSERT INTO proposal (actionType, unit, dedupeKey, sessionId, memberIds, keeperId,
                                          reasonParams, regretTier, confidence, estBytes, score,
                                          humility, state, createdAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?)
                    ON CONFLICT(dedupeKey) DO UPDATE SET
                        confidence = excluded.confidence,
                        estBytes = excluded.estBytes,
                        score = excluded.score,
                        reasonParams = excluded.reasonParams
                    """,
                    arguments: [
                        draft.actionType.rawValue, draft.unit.rawValue, draft.dedupeKey,
                        clusterSessionId, memberJSON, draft.keeperId, reasonJSON,
                        draft.regretTier, draft.confidence, draft.estBytes, score,
                        draft.humility, Date().timeIntervalSince1970,
                    ]
                )
            }
        }
    }

    public func invalidateProposals(touchingAssetIds: [String]) async throws {
        guard !touchingAssetIds.isEmpty else { return }
        try await pool.write { db in
            // memberIds is a JSON array; LIKE-match each id. Committed rows stay.
            for id in touchingAssetIds {
                try db.execute(
                    sql: """
                    UPDATE proposal SET state = \(ProposalState.invalidated.rawValue)
                    WHERE state NOT IN (\(ProposalState.committed.rawValue))
                      AND (memberIds LIKE ? OR keeperId = ?)
                    """,
                    arguments: ["%\"\(id)\"%", id]
                )
            }
        }
    }

    public func suppressedAssetIds(actionType: ActionType) async throws -> Set<String> {
        try await pool.read { db in
            Set(try String.fetchAll(
                db,
                sql: "SELECT assetId FROM suppression WHERE actionType = ?",
                arguments: [actionType.rawValue]
            ))
        }
    }

    public func clearSuppressions(assetIds: [String]) async throws {
        guard !assetIds.isEmpty else { return }
        try await pool.write { db in
            let placeholders = databaseQuestionMarks(count: assetIds.count)
            try db.execute(
                sql: "DELETE FROM suppression WHERE assetId IN (\(placeholders))",
                arguments: StatementArguments(assetIds)
            )
        }
    }

    // MARK: - Meta

    public func loadChangeToken() async throws -> Data? {
        try await pool.read { db in
            try Data.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'changeToken'")
        }
    }

    public func saveChangeToken(_ token: Data?) async throws {
        guard let token else { return }
        try await pool.write { db in
            try db.execute(
                sql: "INSERT INTO meta (key, value) VALUES ('changeToken', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                arguments: [token]
            )
        }
    }

    public func setScanProgress(stage: ScanStage, done: Int, total: Int) async throws {
        try await pool.write { db in
            let value = "\(done)/\(total)".data(using: .utf8)
            try db.execute(
                sql: "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                arguments: ["progress.\(stage.rawValue)", value]
            )
        }
    }

    // MARK: - Row mapping

    static func stub(from row: Row) -> AssetStub {
        var bucket: LocationBucket?
        if let lat = row["latBucket"] as Int?, let lon = row["lonBucket"] as Int? {
            bucket = LocationBucket(lat: lat, lon: lon)
        }
        return AssetStub(
            id: row["id"],
            mediaKind: MediaKind(rawValue: row["mediaType"] ?? 1) ?? .image,
            subtypes: AssetSubtypes(rawValue: row["subtypes"] ?? 0),
            createdAt: (row["createdAt"] as Double?).map(Date.init(timeIntervalSince1970:)),
            modifiedAt: (row["modifiedAt"] as Double?).map(Date.init(timeIntervalSince1970:)),
            pixelWidth: row["width"] ?? 0,
            pixelHeight: row["height"] ?? 0,
            duration: row["duration"] ?? 0,
            isFavorite: row["isFavorite"] ?? false,
            burstId: row["burstId"],
            representsBurst: row["representsBurst"] ?? false,
            isBurstUserPick: false,
            locationBucket: bucket
        )
    }
}

func databaseQuestionMarks(count: Int) -> String {
    Array(repeating: "?", count: count).joined(separator: ",")
}

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
