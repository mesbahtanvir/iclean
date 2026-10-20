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
    /// Records measured file sizes and leaves everything else of the items alone.
    func saveSizes(_ sizes: [String: MeasuredSize]) async throws
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
    func checkpoint(items: [LibraryItem], chunk: ScanChunk, session: ScanSession) async throws
    func deleteChunks(job: UUID) async throws
    /// Deletes everything iclean has stored (FR-018).
    func deleteAllData() async throws
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

    public var assetID: String { metadata.assetID }

    public init(metadata: AssetMetadata, analysisSource: AnalysisSource, scanAttempts: Int = 0) {
        self.metadata = metadata
        self.analysisSource = analysisSource
        self.scanAttempts = scanAttempts
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
