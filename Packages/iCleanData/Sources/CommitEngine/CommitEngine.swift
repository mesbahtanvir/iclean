import Foundation
import GRDB
import PhotoGateway
import ProposalStore
import ScanEngine
import Entitlements

/// The write half (APP_PLATFORM.md §2): allowance gate → re-validation →
/// chunking → one atomic change block per chunk → receipt. Crash-safe via
/// the commit journal; idempotent recovery on relaunch.
public actor CommitRunner {
    public struct Config: Sendable {
        /// 500–1,000, tuned on device (Slidebox's >100-item freeze is the
        /// category's cautionary precedent).
        public var chunkSize = 500
        public init() {}
    }

    public enum NoteKind: Int, Sendable {
        case droppedMissing = 0
        case droppedModified = 1
        case commitFailed = 2
    }

    public struct Outcome: Sendable {
        public var deletedCount = 0
        /// Σ fileSize of assets confirmed absent post-commit — never a
        /// free-space delta (nothing frees until Recently Deleted purges).
        public var confirmedBytes: Int64 = 0
        public var bytesAreEstimates = false
        public var droppedMissing = 0
        public var droppedModified = 0
        public var failedChunks = 0
        public var cancelled = false
        /// Items beyond the free allowance, still staged, awaiting unlock.
        public var heldByPaywall = 0
        public var chunkCount = 0
    }

    private let database: AppDatabase
    private let gateway: any PhotoLibraryGateway
    private let entitlements: any EntitlementsProviding
    private let config: Config

    public init(
        database: AppDatabase,
        gateway: any PhotoLibraryGateway,
        entitlements: any EntitlementsProviding,
        config: Config = Config()
    ) {
        self.database = database
        self.gateway = gateway
        self.entitlements = entitlements
        self.config = config
    }

    /// How many system dialogs a commit of the current staging bin needs —
    /// the review screen says "iOS will ask you to confirm N times" up front.
    public func plannedChunkCount() async throws -> Int {
        let staged = try await stagedItems()
        let assetCount = staged.reduce(0) { $0 + $1.memberIds.count }
        return assetCount == 0 ? 0 : Int(ceil(Double(assetCount) / Double(config.chunkSize)))
    }

    // MARK: - The commit

    public func commitStaged() async throws -> Outcome {
        var outcome = Outcome()
        var staged = try await stagedItems()
        guard !staged.isEmpty else { return outcome }

        // 1. Allowance gate at commit entry (APP_PLATFORM.md §2.1). The
        //    under-allowance prefix stays committable; the rest stays staged.
        let freeRemaining = await entitlements.freeRemaining()
        if freeRemaining < staged.reduce(0, { $0 + $1.memberIds.count }) {
            var budget = freeRemaining
            var committable: [StagedItem] = []
            for item in staged {
                if item.memberIds.count <= budget {
                    committable.append(item)
                    budget -= item.memberIds.count
                } else {
                    outcome.heldByPaywall += item.memberIds.count
                }
            }
            staged = committable
            guard !staged.isEmpty else { return outcome }
        }

        // 2. Pre-commit re-validation (APP_PLATFORM.md §2.1 step 2).
        let allIds = staged.flatMap(\.memberIds)
        let existing = await gateway.existingAssetIds(among: allIds)
        let modified = await gateway.modificationDates(for: allIds)

        var validated: [StagedItem] = []
        for var item in staged {
            var kept: [String] = []
            for id in item.memberIds {
                if !existing.contains(id) {
                    outcome.droppedMissing += 1
                    try await writeNote(proposalId: item.proposalId, kind: .droppedMissing)
                } else if let modifiedAt = modified[id], let decidedAt = item.decidedAt, modifiedAt > decidedAt {
                    outcome.droppedModified += 1
                    try await writeNote(proposalId: item.proposalId, kind: .droppedModified)
                } else {
                    kept.append(id)
                }
            }
            item.memberIds = kept
            if !kept.isEmpty { validated.append(item) }
        }
        guard !validated.isEmpty else { return outcome }

        // 3. Chunk + inheritance plans.
        let commitId = UUID().uuidString
        let chunks = try await buildChunks(items: validated)
        outcome.chunkCount = chunks.count

        // 4. One atomic change block per chunk, journaled before each attempt.
        for (index, chunk) in chunks.enumerated() {
            try await journalWrite(commitId: commitId, chunkIndex: index, assetIds: chunk.plan.deleteIds, state: 0)
            do {
                try await gateway.performCommitChunk(chunk.plan)
                try await journalResolve(commitId: commitId, chunkIndex: index, state: 1)
                try await markCommitted(proposalIds: chunk.proposalIds)

                // 7. Receipt math: confirmed-absent only.
                let remaining = await gateway.existingAssetIds(among: chunk.plan.deleteIds)
                let confirmedGone = chunk.plan.deleteIds.filter { !remaining.contains($0) }
                outcome.deletedCount += confirmedGone.count
                let sizes = try await byteSizes(ids: confirmedGone)
                outcome.confirmedBytes += sizes.total
                outcome.bytesAreEstimates = outcome.bytesAreEstimates || sizes.anyEstimate
                await entitlements.recordCommitted(count: confirmedGone.count)
            } catch CommitChunkError.userCancelled {
                // Whole chunk rolled back — inheritance included. Staging
                // preserved, no guilt copy (APP_PLATFORM.md §2.1 step 4).
                try await journalResolve(commitId: commitId, chunkIndex: index, state: 2)
                outcome.cancelled = true
                return outcome
            } catch {
                try await journalResolve(commitId: commitId, chunkIndex: index, state: 2)
                outcome.failedChunks += 1
                for proposalId in chunk.proposalIds {
                    try await writeNote(proposalId: proposalId, kind: .commitFailed)
                }
            }
        }
        return outcome
    }

    /// Idempotent recovery on relaunch (APP_PLATFORM.md §2.1 step 5):
    /// a `pending` journal row is resolved by re-fetching its identifiers —
    /// absent ⇒ the chunk applied; present ⇒ it didn't (items stay staged).
    public func recoverPendingJournals() async throws {
        let pending: [(String, Int, [String])] = try await database.pool.read { db in
            let rows = try Row.fetchAll(
                db, sql: "SELECT commitId, chunkIndex, assetIds FROM commit_journal WHERE state = 0"
            )
            return rows.map { row in
                let ids = (try? JSONDecoder().decode([String].self, from: Data((row["assetIds"] as String).utf8))) ?? []
                return (row["commitId"], row["chunkIndex"], ids)
            }
        }
        for (commitId, chunkIndex, assetIds) in pending {
            let existing = await gateway.existingAssetIds(among: assetIds)
            let applied = existing.isEmpty && !assetIds.isEmpty
            try await journalResolve(commitId: commitId, chunkIndex: chunkIndex, state: applied ? 1 : 2)
        }
    }

    // MARK: - Chunk building

    struct StagedItem: Sendable {
        let proposalId: Int64
        var memberIds: [String]
        let keeperId: String?
        let decidedAt: Date?
    }

    struct Chunk: Sendable {
        let plan: CommitChunkPlan
        let proposalIds: [Int64]
    }

    private func stagedItems() async throws -> [StagedItem] {
        try await database.pool.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT id, memberIds, keeperId, decidedAt FROM proposal WHERE state = 4 ORDER BY id"
            )
            return rows.map { row in
                let members = (try? JSONDecoder().decode(
                    [String].self, from: Data((row["memberIds"] as String).utf8)
                )) ?? []
                return StagedItem(
                    proposalId: row["id"],
                    memberIds: members,
                    keeperId: row["keeperId"],
                    decidedAt: (row["decidedAt"] as Double?).map(Date.init(timeIntervalSince1970:))
                )
            }
        }
    }

    private func buildChunks(items: [StagedItem]) async throws -> [Chunk] {
        // Keeper inheritance (APP_PLATFORM.md §2.1 step 4, DESIGN.md §9.3):
        // for every user album a doomed member occupies that the keeper doesn't,
        // add the keeper; a doomed favorite makes the keeper a favorite.
        var chunks: [Chunk] = []
        var currentDeletes: [String] = []
        var currentAdds: [CommitChunkPlan.AlbumAdd] = []
        var currentFavorites: Set<String> = []
        var currentProposals: [Int64] = []

        func flush() {
            guard !currentDeletes.isEmpty else { return }
            chunks.append(
                Chunk(
                    plan: CommitChunkPlan(
                        albumAdds: currentAdds,
                        favoriteKeeperIds: Array(currentFavorites).sorted(),
                        deleteIds: currentDeletes
                    ),
                    proposalIds: currentProposals
                )
            )
            currentDeletes = []
            currentAdds = []
            currentFavorites = []
            currentProposals = []
        }

        for item in items {
            if currentDeletes.count + item.memberIds.count > config.chunkSize {
                flush()
            }
            if let keeper = item.keeperId {
                let doomedAlbums = try await albumIds(ofAssets: item.memberIds)
                let keeperAlbums = try await albumIds(ofAssets: [keeper])
                for albumId in doomedAlbums.subtracting(keeperAlbums) {
                    currentAdds.append(CommitChunkPlan.AlbumAdd(albumId: albumId, keeperId: keeper))
                }
                if try await anyFavorite(ids: item.memberIds) {
                    currentFavorites.insert(keeper)
                }
            }
            currentDeletes.append(contentsOf: item.memberIds)
            currentProposals.append(item.proposalId)
        }
        flush()
        return chunks
    }

    // MARK: - DB helpers

    private func albumIds(ofAssets ids: [String]) async throws -> Set<String> {
        guard !ids.isEmpty else { return [] }
        return try await database.pool.read { db in
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            return Set(try String.fetchAll(
                db,
                sql: "SELECT DISTINCT albumId FROM album_member WHERE assetId IN (\(placeholders))",
                arguments: StatementArguments(ids)
            ))
        }
    }

    private func anyFavorite(ids: [String]) async throws -> Bool {
        guard !ids.isEmpty else { return false }
        return try await database.pool.read { db in
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            return try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM asset WHERE id IN (\(placeholders)) AND isFavorite = 1)",
                arguments: StatementArguments(ids)
            ) ?? false
        }
    }

    private func byteSizes(ids: [String]) async throws -> (total: Int64, anyEstimate: Bool) {
        guard !ids.isEmpty else { return (0, false) }
        return try await database.pool.read { db in
            let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ",")
            let row = try Row.fetchOne(
                db,
                sql: """
                SELECT COALESCE(SUM(fileSize), 0) AS total,
                       MAX(fileSizeIsEstimate) AS est,
                       SUM(CASE WHEN fileSize IS NULL THEN 1 ELSE 0 END) AS missing
                FROM asset WHERE id IN (\(placeholders))
                """,
                arguments: StatementArguments(ids)
            )
            let missing: Int = row?["missing"] ?? 0
            return (row?["total"] ?? 0, (row?["est"] ?? false) || missing > 0)
        }
    }

    private func markCommitted(proposalIds: [Int64]) async throws {
        guard !proposalIds.isEmpty else { return }
        try await database.pool.write { db in
            let placeholders = Array(repeating: "?", count: proposalIds.count).joined(separator: ",")
            try db.execute(
                sql: "UPDATE proposal SET state = 5 WHERE id IN (\(placeholders))",
                arguments: StatementArguments(proposalIds)
            )
        }
    }

    private func writeNote(proposalId: Int64, kind: NoteKind) async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: "INSERT INTO staging_note (proposalId, kind, createdAt) VALUES (?, ?, ?)",
                arguments: [proposalId, kind.rawValue, Date().timeIntervalSince1970]
            )
        }
    }

    private func journalWrite(commitId: String, chunkIndex: Int, assetIds: [String], state: Int) async throws {
        let json = String(data: (try? JSONEncoder().encode(assetIds)) ?? Data("[]".utf8), encoding: .utf8) ?? "[]"
        try await database.pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO commit_journal (commitId, chunkIndex, assetIds, state, createdAt)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(commitId, chunkIndex) DO UPDATE SET state = excluded.state
                """,
                arguments: [commitId, chunkIndex, json, state, Date().timeIntervalSince1970]
            )
        }
    }

    private func journalResolve(commitId: String, chunkIndex: Int, state: Int) async throws {
        try await database.pool.write { db in
            try db.execute(
                sql: "UPDATE commit_journal SET state = ?, resolvedAt = ? WHERE commitId = ? AND chunkIndex = ?",
                arguments: [state, Date().timeIntervalSince1970, commitId, chunkIndex]
            )
        }
    }
}
