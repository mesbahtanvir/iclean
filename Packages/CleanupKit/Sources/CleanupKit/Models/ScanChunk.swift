import Foundation

public enum ScanChunkState: String, Sendable, Codable {
    case pending, running, done
}

/// One piece of a scan job: up to 64 asset identifiers with a bit per finished one
/// (003 data-model.md). A crash loses at most the unfinished part of one chunk.
public struct ScanChunk: Sendable, Hashable, Identifiable {
    public static let maxSize = 64

    public var jobID: UUID
    public var sequence: Int
    public var assetIDs: [String]
    public var state: ScanChunkState
    /// Bit `i` is set once `assetIDs[i]` is finished (analyzed, skipped, or given up).
    public var doneMask: UInt64
    /// Failed runs of this chunk (not counting crashes).
    public var attempts: Int
    /// Times the app died while this chunk was running.
    public var crashes: Int
    /// After a crash: one item at a time, saved after every item (003 FR-006).
    public var isolate: Bool
    /// In isolate mode, the item that was in flight at the last crash.
    public var suspectIndex: Int?
    /// In isolate mode, the item being analyzed right now. Saved before it starts, so a
    /// death is blamed on exactly that item and not on an earlier one that merely failed.
    public var inFlightIndex: Int?
    /// Earliest time to retry after a failed run.
    public var notBefore: Date?
    /// The process incarnation that leased the chunk; nil when not running.
    public var owner: UUID?
    public var lastError: String?

    public init(
        jobID: UUID, sequence: Int, assetIDs: [String], state: ScanChunkState = .pending,
        doneMask: UInt64 = 0, attempts: Int = 0, crashes: Int = 0, isolate: Bool = false,
        suspectIndex: Int? = nil, inFlightIndex: Int? = nil, notBefore: Date? = nil,
        owner: UUID? = nil, lastError: String? = nil
    ) {
        precondition(assetIDs.count <= Self.maxSize, "a chunk holds at most 64 items")
        self.jobID = jobID
        self.sequence = sequence
        self.assetIDs = assetIDs
        self.state = state
        self.doneMask = doneMask
        self.attempts = attempts
        self.crashes = crashes
        self.isolate = isolate
        self.suspectIndex = suspectIndex
        self.inFlightIndex = inFlightIndex
        self.notBefore = notBefore
        self.owner = owner
        self.lastError = lastError
    }

    public var id: String { Self.key(jobID: jobID, sequence: sequence) }

    public static func key(jobID: UUID, sequence: Int) -> String {
        "\(jobID.uuidString)/\(sequence)"
    }

    public func isDone(_ index: Int) -> Bool { doneMask & (1 << UInt64(index)) != 0 }

    public mutating func markDone(_ index: Int) { doneMask |= 1 << UInt64(index) }

    public var doneCount: Int { doneMask.nonzeroBitCount }

    public var undoneIndices: [Int] { assetIDs.indices.filter { !isDone($0) } }

    public var firstUndoneIndex: Int? { undoneIndices.first }

    public var isComplete: Bool { undoneIndices.isEmpty }

    /// Ready to run: pending and past its retry time.
    public func isEligible(at now: Date) -> Bool {
        state == .pending && (notBefore.map { $0 <= now } ?? true)
    }
}

/// Limits for chunking, retries, timeouts, and crash isolation (003 FR-005 to FR-008).
public struct ScanRetryPolicy: Sendable {
    /// Items per chunk (1…64). About 1.6 s of work at the 001 target rate.
    public var chunkSize: Int
    /// Failed runs of a chunk before its failing items are given up on.
    public var maxAttempts: Int
    /// Delay before the first, second, … retry; the last value repeats.
    public var backoff: [Duration]
    /// Longest wait for one item's preview plus analysis (FR-007).
    public var itemTimeout: Duration
    /// Crashes of one job before it is stopped (done items are kept).
    public var crashBudget: Int
    /// Full scans that may try an item again after it was not analyzed (FR-008).
    public var crossScanAttempts: Int

    public init(
        chunkSize: Int = 32, maxAttempts: Int = 3,
        backoff: [Duration] = [.seconds(2), .seconds(8)], itemTimeout: Duration = .seconds(20),
        crashBudget: Int = 5, crossScanAttempts: Int = 6
    ) {
        self.chunkSize = min(max(1, chunkSize), ScanChunk.maxSize)
        self.maxAttempts = max(1, maxAttempts)
        self.backoff = backoff.isEmpty ? [.seconds(2)] : backoff
        self.itemTimeout = itemTimeout
        self.crashBudget = max(1, crashBudget)
        self.crossScanAttempts = max(1, crossScanAttempts)
    }

    public static let `default` = ScanRetryPolicy()

    /// Delay before retry number `attempt` (1-based).
    public func delay(forAttempt attempt: Int) -> Duration {
        backoff[min(max(attempt, 1), backoff.count) - 1]
    }
}
