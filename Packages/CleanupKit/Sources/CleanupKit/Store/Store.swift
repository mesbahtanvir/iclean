import Foundation

/// Local storage for scan results, keep marks and scan progress.
/// Everything stays on the phone (Constitution Principle I).
public protocol Store: Sendable {
    /// Every stored item with its whole analysis. Costs about 20 KB of memory per item, so a
    /// library of 30,000 needs more than 600 MB: the scan and the results use the lean readers
    /// below instead (spec 008).
    func items() async throws -> [LibraryItem]
    /// What a scan needs to know about every stored item, without any fingerprint.
    func itemSummaries() async throws -> [StoredItemSummary]
    /// Every stored item with its analysis except the feature print (`featurePrint` is empty).
    /// Only `ResultsLoader` reads this: an item read this way must not be handed to a detector
    /// without its feature print when the detector needs it.
    func itemsWithoutFeaturePrints() async throws -> [LibraryItem]
    /// The feature prints of these items; items without one are left out.
    func featurePrints(for assetIDs: [String]) async throws -> [String: Data]
    /// Updates the metadata of stored items in place and leaves their analysis alone.
    func refreshMetadata(_ metadata: [AssetMetadata]) async throws
    func upsert(_ items: [LibraryItem]) async throws
    func deleteItems(_ assetIDs: Set<String>) async throws
    func keepMarks() async throws -> Set<String>
    func setKeep(_ assetID: String, _ keep: Bool) async throws
    func clearKeepMarks() async throws
    func saveSession(_ session: ScanSession) async throws
    /// The most recent session, if any.
    func currentSession() async throws -> ScanSession?
    /// Recent sessions, newest first (003 FR-012).
    func sessions() async throws -> [ScanSession]
    /// How many scans have ended with each of these items not analyzed (003 FR-008).
    func scanAttempts(for assetIDs: [String]) async throws -> [String: Int]

    // MARK: Scan jobs (003)

    /// Saves the session and replaces its chunks, in one transaction.
    func createJob(_ session: ScanSession, chunks: [ScanChunk]) async throws
    /// The job's chunks, ordered by sequence.
    func chunks(job: UUID) async throws -> [ScanChunk]
    /// Writes chunks (and the session when given) in one transaction.
    func saveChunks(_ chunks: [ScanChunk], session: ScanSession?) async throws
    /// Results of a chunk, its state, and the session counters, in one transaction, so a
    /// failure leaves the store with all of them or none (003 FR-002).
    func checkpoint(items: [LibraryItem], chunks: [ScanChunk], session: ScanSession) async throws
    func deleteChunks(job: UUID) async throws

    // MARK: Saved results and review state (007)

    /// Every item, the keep marks and the revision they belong to, read in one step so the
    /// revision always matches the data a build used.
    func resultInputs() async throws -> ResultInputs
    /// The revision of what results are built from. It only goes up (see `StoreMetaRecord`).
    func revision() async throws -> Int64
    /// What the launch needs, in one read and without reading a single item row.
    /// How many items the store holds, from a count and not from reading them.
    func itemCount() async throws -> Int
    func loadLaunchState() async throws -> LaunchState
    /// Saves a state row (decisions, position). Never changes the results revision.
    func saveState(_ key: StateKey, version: Int, payload: Data) async throws
    /// Saves the results snapshot only if the store is still at `ifRevision`. Returns whether it
    /// was written; false means the store moved on and the snapshot would already be stale.
    func saveSnapshot(_ payload: Data, version: Int, ifRevision: Int64) async throws -> Bool
    func deleteState(_ keys: Set<StateKey>) async throws
    /// Size and age of each saved state row.
    func stateInfo() async throws -> [StateKey: StateInfo]
    /// Records measured sizes without touching anything else. The revision moves once, and only
    /// if an item went from no size, or an estimate, to a measured size.
    func setSizes(_ sizes: [String: MeasuredSize]) async throws
    /// Stored sizes for these items.
    func sizes(for assetIDs: [String]) async throws -> [String: MeasuredSize]
    /// Deletes everything iclean has stored (FR-018), saved state included. The revision is kept
    /// and moves on, so an old snapshot can never match again.
    func deleteAllData() async throws

    /// Whether the saved data could be opened. A store that could not be opened is replaced by an
    /// empty one that lives only in memory, and this says so; it is never silently "empty".
    func openStatus() async -> StoreOpenStatus
    /// Deletes the store files themselves (the data file and its write-ahead log together) and
    /// opens a fresh store. For the person's explicit "Delete saved data" when the old one cannot
    /// be read. Anything else deletes rows through `deleteAllData`.
    func eraseStoreFiles() async throws
}

public enum StoreOpenStatus: Sendable, Equatable {
    case ready
    /// The saved data could not be opened; progress will not be saved this run.
    case volatile(String)
}

extension Store {
    public func checkpoint(items: [LibraryItem], chunk: ScanChunk, session: ScanSession)
        async throws
    {
        try await checkpoint(items: items, chunks: [chunk], session: session)
    }

    public func openStatus() async -> StoreOpenStatus { .ready }
    public func eraseStoreFiles() async throws { try await deleteAllData() }
}

/// The input of one results build, all from one moment.
public struct ResultInputs: Sendable {
    public var items: [LibraryItem]
    public var keepMarks: Set<String>
    public var revision: Int64

    public init(items: [LibraryItem], keepMarks: Set<String>, revision: Int64) {
        self.items = items
        self.keepMarks = keepMarks
        self.revision = revision
    }
}

/// Everything the launch needs from the store. No item rows.
public struct LaunchState: Sendable {
    public var revision: Int64
    /// Saved state rows whose checksum matched. A damaged row is deleted and left out.
    public var states: [StateKey: StateEnvelope]
    public var keepMarks: Set<String>
    public var session: ScanSession?
    public var itemCount: Int
    /// When the newest full scan that ran to the end finished. Not `session`: that is the newest
    /// session of any kind (a quick check at every foreground, a stopped scan), which says nothing
    /// about whether the library was ever fully checked.
    public var lastFullScanCompletedAt: Date?

    public init(
        revision: Int64 = 0, states: [StateKey: StateEnvelope] = [:], keepMarks: Set<String> = [],
        session: ScanSession? = nil, itemCount: Int = 0, lastFullScanCompletedAt: Date? = nil
    ) {
        self.revision = revision
        self.states = states
        self.keepMarks = keepMarks
        self.session = session
        self.itemCount = itemCount
        self.lastFullScanCompletedAt = lastFullScanCompletedAt
    }
}

public enum StoreError: Error, Equatable {
    /// Only one session can be running or paused at a time.
    case anotherSessionActive
}

/// A stored item without its fingerprints: all a scan plan needs (spec 008).
public struct StoredItemSummary: Sendable, Hashable {
    public var metadata: AssetMetadata
    public var analysisSource: AnalysisSource
    /// How many scans have ended with this item not analyzed (003 FR-008).
    public var scanAttempts: Int
    /// The Vision work left out of this item's analysis on purpose (spec 010). A plan reads it to
    /// find items whose neighbours have arrived since.
    public var skippedVision: VisionWork

    public var assetID: String { metadata.assetID }

    public init(
        metadata: AssetMetadata, analysisSource: AnalysisSource, scanAttempts: Int = 0,
        skippedVision: VisionWork = []
    ) {
        self.metadata = metadata
        self.analysisSource = analysisSource
        self.scanAttempts = scanAttempts
        self.skippedVision = skippedVision
    }
}

/// A file size read from the phone, or estimated when the file is not on it.
public struct MeasuredSize: Sendable, Hashable {
    public var bytes: Int64
    public var isEstimated: Bool

    public init(bytes: Int64, isEstimated: Bool) {
        self.bytes = bytes
        self.isEstimated = isEstimated
    }
}
