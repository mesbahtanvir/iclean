import Foundation
import GRDB
import ScanEngine

/// UI-facing proposal row.
public struct ProposalCard: Identifiable, Sendable, Equatable {
    public let id: Int64
    public let actionType: ActionType
    public let unit: DecisionUnit
    public let memberIds: [String]
    public let keeperId: String?
    public let reason: ReasonParams
    public let regretTier: Int
    public let confidence: Double
    public let estBytes: Int64
    public let humility: Bool
    public let state: ProposalState

    public var reasonText: String {
        ReasonCatalog.render(reason) ?? ""
    }
}

public struct StagingTotals: Sendable, Equatable {
    public let count: Int
    public let bytes: Int64
    public init(count: Int, bytes: Int64) {
        self.count = count
        self.bytes = bytes
    }
}

/// The proposal store → deck UI contract (SCAN_PIPELINE.md §12):
/// ValueObservation windows, compare-and-set verdicts, the decision_log undo
/// stack, staging totals honest by construction.
public final class DeckStore: @unchecked Sendable {
    private let database: AppDatabase
    private var pool: DatabasePool { database.pool }

    /// UI session id for the undo stack — a new one per app launch.
    public let uiSessionId: Int64

    public init(database: AppDatabase) {
        self.database = database
        self.uiSessionId = Int64(Date().timeIntervalSince1970)
    }

    // MARK: - Deck queries

    /// Pending proposals for one family, ordered by score. The DeckViewModel
    /// applies pacing over this window and owns the immutable dealt window.
    public func pendingWindow(family: Family, limit: Int = 30) throws -> [ProposalCard] {
        try pool.read { db in
            try Self.cards(
                db: db,
                sql: """
                SELECT * FROM proposal
                WHERE state IN (0, 1) AND actionType IN (\(Self.familyList(family)))
                ORDER BY score DESC, id ASC
                LIMIT ?
                """,
                arguments: [limit]
            )
        }
    }

    /// GRDB observation for the deck window — diffs apply only behind the
    /// dealt window (enforced by the view model, not the query).
    public func observePendingWindow(
        family: Family,
        limit: Int = 30,
        onChange: @escaping @Sendable ([ProposalCard]) -> Void
    ) -> AnyDatabaseCancellable {
        let observation = ValueObservation.tracking { db in
            try Self.cards(
                db: db,
                sql: """
                SELECT * FROM proposal
                WHERE state IN (0, 1) AND actionType IN (\(Self.familyList(family)))
                ORDER BY score DESC, id ASC
                LIMIT ?
                """,
                arguments: [limit]
            )
        }
        return observation.start(
            in: pool,
            onError: { _ in },
            onChange: onChange
        )
    }

    public func familySummaries() throws -> [Family: StagingTotals] {
        try pool.read { db in
            var out: [Family: StagingTotals] = [:]
            for family in Family.allCases {
                let row = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT COUNT(*) AS c, COALESCE(SUM(estBytes), 0) AS b FROM proposal
                    WHERE state IN (0, 1) AND actionType IN (\(Self.familyList(family)))
                    """
                )
                out[family] = StagingTotals(count: row?["c"] ?? 0, bytes: row?["b"] ?? 0)
            }
            return out
        }
    }

    // MARK: - Verdicts (compare-and-set — SCAN_PIPELINE.md §12)

    /// pending → shown, written when the card is first dealt (impression semantics).
    public func markShown(id: Int64) throws {
        try pool.write { db in
            try db.execute(
                sql: "UPDATE proposal SET state = 1 WHERE id = ? AND state = 0",
                arguments: [id]
            )
        }
    }

    public enum VerdictOutcome: Sendable {
        case applied
        /// Zero rows updated: invalidation won the race mid-swipe. The gesture
        /// completes visually; the verdict is discarded; quiet toast, never a modal.
        case invalidatedMidSwipe
    }

    /// Right-swipe: shown → approved → staged in the same transaction
    /// (`approved` exists so undo can pop staged → shown).
    public func approve(id: Int64) throws -> VerdictOutcome {
        try pool.write { db in
            try db.execute(
                sql: """
                UPDATE proposal SET state = \(ProposalState.staged.rawValue), decidedAt = ?
                WHERE id = ? AND state IN (0, 1)
                """,
                arguments: [Date().timeIntervalSince1970, id]
            )
            guard db.changesCount > 0 else { return .invalidatedMidSwipe }
            try self.appendDecision(db: db, proposalId: id, verdict: ProposalState.staged.rawValue)
            return .applied
        }
    }

    /// Left-swipe: shown → rejected, plus durable per-asset suppression —
    /// "Kept, won't suggest again" survives re-clustering (SCAN_PIPELINE.md §5-S7).
    public func reject(id: Int64) throws -> VerdictOutcome {
        try pool.write { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT actionType, memberIds FROM proposal WHERE id = ?", arguments: [id]
            ) else { return .invalidatedMidSwipe }

            try db.execute(
                sql: """
                UPDATE proposal SET state = \(ProposalState.rejected.rawValue), decidedAt = ?
                WHERE id = ? AND state IN (0, 1)
                """,
                arguments: [Date().timeIntervalSince1970, id]
            )
            guard db.changesCount > 0 else { return .invalidatedMidSwipe }

            let actionType: String = row["actionType"]
            let memberJSON: String = row["memberIds"]
            let members = (try? JSONDecoder().decode([String].self, from: Data(memberJSON.utf8))) ?? []
            let now = Date().timeIntervalSince1970
            for member in members {
                try db.execute(
                    sql: """
                    INSERT OR IGNORE INTO suppression (assetId, actionType, createdAt) VALUES (?, ?, ?)
                    """,
                    arguments: [member, actionType, now]
                )
            }
            try self.appendDecision(db: db, proposalId: id, verdict: ProposalState.rejected.rawValue)
            return .applied
        }
    }

    // MARK: - Undo stack (append-only decision_log — SCAN_PIPELINE.md §4)

    private func appendDecision(db: Database, proposalId: Int64, verdict: Int, restored: Bool = false) throws {
        let nextSeq = (try Int64.fetchOne(
            db,
            sql: "SELECT MAX(seq) FROM decision_log WHERE uiSessionId = ?",
            arguments: [uiSessionId]
        ) ?? 0) + 1
        try db.execute(
            sql: """
            INSERT INTO decision_log (uiSessionId, seq, proposalId, verdict, decidedAt, restored)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            arguments: [uiSessionId, nextSeq, proposalId, verdict, Date().timeIntervalSince1970, restored]
        )
    }

    /// Swipe-down: pop the session's highest seq and revert proposal.state.
    /// Returns the reverted proposal id, or nil when the stack is empty.
    public func undoLast() throws -> Int64? {
        try pool.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT seq, proposalId, verdict FROM decision_log
                WHERE uiSessionId = ? AND restored = 0
                ORDER BY seq DESC LIMIT 1
                """,
                arguments: [self.uiSessionId]
            ) else { return nil }

            let proposalId: Int64 = row["proposalId"]
            let verdict: Int = row["verdict"]

            // Revert to shown; restores append, never delete (adaptive thresholds
            // and telemetry read one source of truth).
            try db.execute(
                sql: "UPDATE proposal SET state = 1, decidedAt = NULL WHERE id = ? AND state IN (3, 4)",
                arguments: [proposalId]
            )
            if verdict == ProposalState.rejected.rawValue {
                // Undoing a rejection lifts its suppressions.
                if let proposalRow = try Row.fetchOne(
                    db, sql: "SELECT actionType, memberIds FROM proposal WHERE id = ?", arguments: [proposalId]
                ) {
                    let members = (try? JSONDecoder().decode(
                        [String].self, from: Data((proposalRow["memberIds"] as String).utf8)
                    )) ?? []
                    let actionType: String = proposalRow["actionType"]
                    for member in members {
                        try db.execute(
                            sql: "DELETE FROM suppression WHERE assetId = ? AND actionType = ?",
                            arguments: [member, actionType]
                        )
                    }
                }
            }
            try self.appendDecision(db: db, proposalId: proposalId, verdict: 1, restored: true)
            return proposalId
        }
    }

    // MARK: - Staging bin

    public func stagingTotals() throws -> StagingTotals {
        try pool.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT COUNT(*) AS c, COALESCE(SUM(estBytes), 0) AS b FROM proposal WHERE state = 4"
            )
            return StagingTotals(count: row?["c"] ?? 0, bytes: row?["b"] ?? 0)
        }
    }

    public func observeStagingTotals(
        onChange: @escaping @Sendable (StagingTotals) -> Void
    ) -> AnyDatabaseCancellable {
        let observation = ValueObservation.tracking { db -> StagingTotals in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT COUNT(*) AS c, COALESCE(SUM(estBytes), 0) AS b FROM proposal WHERE state = 4"
            )
            return StagingTotals(count: row?["c"] ?? 0, bytes: row?["b"] ?? 0)
        }
        return observation.start(in: pool, onError: { _ in }, onChange: onChange)
    }

    /// Bin grouped by reason = GROUP BY actionType over staged rows —
    /// no parallel store (SCAN_PIPELINE.md §4).
    public func stagedByAction() throws -> [(actionType: ActionType, cards: [ProposalCard])] {
        try pool.read { db in
            let cards = try Self.cards(
                db: db,
                sql: "SELECT * FROM proposal WHERE state = 4 ORDER BY actionType, id",
                arguments: []
            )
            let grouped = Dictionary(grouping: cards, by: \.actionType)
            return grouped
                .map { (actionType: $0.key, cards: $0.value) }
                .sorted { $0.actionType.rawValue < $1.actionType.rawValue }
        }
    }

    /// Per-item restore from the bin (staged → shown), logged as a restore —
    /// the ground truth of over-aggression (DESIGN.md §9.5).
    public func restoreFromBin(id: Int64) throws {
        try pool.write { db in
            try db.execute(
                sql: "UPDATE proposal SET state = 1, decidedAt = NULL WHERE id = ? AND state = 4",
                arguments: [id]
            )
            if db.changesCount > 0 {
                try self.appendDecision(db: db, proposalId: id, verdict: 1, restored: true)
            }
        }
    }

    // MARK: - Widget snapshot (APP_PLATFORM.md §6)

    public struct WidgetSnapshot: Codable, Sendable {
        public let reclaimableBytes: Int64
        public let pendingCount: Int
        public let updatedAt: Date
    }

    public func writeWidgetSnapshot() throws {
        let totals = try pool.read { db -> (Int64, Int) in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT COALESCE(SUM(estBytes),0) AS b, COUNT(*) AS c FROM proposal WHERE state IN (0,1)"
            )
            return (row?["b"] ?? 0, row?["c"] ?? 0)
        }
        let snapshot = WidgetSnapshot(reclaimableBytes: totals.0, pendingCount: totals.1, updatedAt: Date())
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppDatabase.appGroupIdentifier
        ) else { return }
        let url = container.appendingPathComponent("widget-snapshot.json")
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    }

    // MARK: - Row mapping

    private static func familyList(_ family: Family) -> String {
        ActionType.allCases
            .filter { $0.family == family }
            .map { "'\($0.rawValue)'" }
            .joined(separator: ",")
    }

    static func cards(db: Database, sql: String, arguments: StatementArguments) throws -> [ProposalCard] {
        let decoder = JSONDecoder()
        return try Row.fetchAll(db, sql: sql, arguments: arguments).compactMap { row in
            guard
                let actionType = ActionType(rawValue: row["actionType"]),
                let unit = DecisionUnit(rawValue: row["unit"]),
                let state = ProposalState(rawValue: row["state"] ?? 0)
            else { return nil }
            let members = (try? decoder.decode([String].self, from: Data((row["memberIds"] as String).utf8))) ?? []
            guard let reason = try? decoder.decode(
                ReasonParams.self, from: Data((row["reasonParams"] as String).utf8)
            ), ReasonCatalog.isRenderable(reason) else {
                // Unknown templateId (DB survived a downgrade) → invalidate, don't render
                // a generic fallback (SCAN_PIPELINE.md §5-S7).
                try? db.execute(
                    sql: "UPDATE proposal SET state = \(ProposalState.invalidated.rawValue) WHERE id = ?",
                    arguments: [row["id"] as Int64]
                )
                return nil
            }
            return ProposalCard(
                id: row["id"],
                actionType: actionType,
                unit: unit,
                memberIds: members,
                keeperId: row["keeperId"],
                reason: reason,
                regretTier: row["regretTier"] ?? 2,
                confidence: row["confidence"] ?? 0,
                estBytes: row["estBytes"] ?? 0,
                humility: row["humility"] ?? false,
                state: state
            )
        }
    }
}
