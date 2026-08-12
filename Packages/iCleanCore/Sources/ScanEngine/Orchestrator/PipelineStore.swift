import Foundation
import PhotoGateway

/// Persistence seam between the engine and GRDB (implemented by the
/// ProposalStore package; mocked by FixtureKit). ScanEngine never imports GRDB.
public protocol PipelineStore: Sendable {
    // MARK: Assets & scan state

    func upsertAssets(_ stubs: [AssetStub]) async throws
    func markAssetsDeleted(ids: [String], at date: Date) async throws
    func allAssetIds() async throws -> Set<String>
    func assetStubs(ids: [String]) async throws -> [AssetStub]

    /// pending OR (failed AND retryCount < 3 AND nextRetryAt < now) OR
    /// (done AND detectorVersion < currentVersion) — SCAN_PIPELINE.md §11.
    func nextBatch(stage: ScanStage, limit: Int, now: Date, currentVersion: Int) async throws -> [String]
    func recordStageOutcome(assetIds: [String], stage: ScanStage, status: StageStatus, version: Int, now: Date) async throws
    func resetNeedsConnection(now: Date) async throws
    func pendingWorkExists() async throws -> Bool

    // MARK: Signals

    func writeSignals(_ signals: [AssetSignals]) async throws
    func writeResourceInfo(assetId: String, info: ResourceInfo) async throws
    func signals(ids: [String]) async throws -> [String: AssetSignals]
    func resourceInfos(ids: [String]) async throws -> [String: ResourceInfo]

    // MARK: Albums (S1.5)

    func replaceAlbums(_ albums: [AlbumInfo]) async throws
    func albumMembership(ids: [String]) async throws -> [String: [String]] // assetId → albumIds

    // MARK: Sessions

    func replaceSessions(_ drafts: [Sessionizer.SessionDraft]) async throws -> [Int64]
    func dirtySessionIds() async throws -> [Int64]
    func sessionMembers(sessionId: Int64) async throws -> [AssetStub]
    func markSessionClean(sessionId: Int64) async throws
    func sessionsReadyForClustering(now: Date) async throws -> [Int64]

    // MARK: Proposals & suppression

    /// Upsert on dedupeKey: unchanged regenerations keep their state
    /// (SCAN_PIPELINE.md §5-S7).
    func upsertProposals(_ drafts: [ProposalDraft], clusterSessionId: Int64?) async throws
    func invalidateProposals(touchingAssetIds: [String]) async throws
    func suppressedAssetIds(actionType: ActionType) async throws -> Set<String>
    func clearSuppressions(assetIds: [String]) async throws

    // MARK: Change token & meta

    func loadChangeToken() async throws -> Data?
    func saveChangeToken(_ token: Data?) async throws
    func setScanProgress(stage: ScanStage, done: Int, total: Int) async throws
}

/// Deck-readiness events the UI observes (SCAN_PIPELINE.md §5-S1: hub alive in
/// ~10 s, exact-dupe opener ready ≤ 60 s).
public enum ScanEvent: Sendable, Equatable {
    case hubBucketsAvailable
    case deckReady(Family)
    case scanCheckpoint(stage: ScanStage, done: Int, total: Int)
    case firstScanComplete
}
