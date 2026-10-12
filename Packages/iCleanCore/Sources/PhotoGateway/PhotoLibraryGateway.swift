import Foundation

/// The single seam between the pipeline and PhotoKit. Everything above this
/// protocol is Sendable value types, which is what makes fixture testing
/// possible (SCAN_PIPELINE.md §12, §13).
public protocol PhotoLibraryGateway: Sendable {
    // MARK: S0 — enumeration & change tracking

    /// Full-library enumeration with includeAllBurstAssets semantics
    /// (burst members must exist as rows — SCAN_PIPELINE.md §5-S0).
    /// Yields batches so S0 can transact per ~2,000 assets.
    func enumerateAssets(batchSize: Int) -> AsyncThrowingStream<[AssetStub], Error>

    /// Persistent change history since `token` (nil = from library start).
    /// Yields batches, each carrying the token to persist with that batch.
    /// Throws `GatewayError.expiredChangeToken` when the token is invalid,
    /// which triggers the full re-diff fallback (SCAN_PIPELINE.md §5-S0).
    func persistentChanges(since token: Data?) -> AsyncThrowingStream<ChangeSet, Error>

    // MARK: S1.5 — albums (user-created only; SCAN_PIPELINE.md §5-S1.5)

    func userAlbums() async throws -> [AlbumInfo]

    // MARK: S2 — thumbnails & availability probes

    /// ~512 px grayscale, isNetworkAccessAllowed = false. This probes the
    /// DERIVATIVE only — a success says nothing about the original.
    func grayThumbnail(assetId: String, maxDimension: Int, allowNetwork: Bool) async -> ThumbnailResult

    /// Lazy original-bytes probe (requestImageDataAndOrientation / requestAVAsset
    /// with network disabled) — only for detectors that need original bytes.
    func probeOriginalAvailability(assetId: String) async -> Availability

    /// SHA-256 of original bytes; nil unless the original is local.
    func byteHashIfLocal(assetId: String) async -> Data?

    // MARK: S3 — resource introspection

    func resourceInfo(assetId: String) async -> ResourceInfo?

    // MARK: S4 — Vision passes

    /// Faces + landmarks-derived eyes-open + capture quality + saliency in one
    /// handler pass over the thumbnail (SCAN_PIPELINE.md §5-S4).
    func visionSignals(assetId: String, maxDimension: Int) async -> VisionSignals?

    /// Confirming face pass at 1024-px best-local before batch eligibility
    /// on a no-face basis (SCAN_PIPELINE.md §5-S4).
    func confirmNoFaces(assetId: String) async -> Bool

    /// Embeddings for one session window; nil when the Vision revision is
    /// unrecognized (similar detector disables — SCAN_PIPELINE.md §6.3).
    func featureDistances(assetIds: [String], maxDimension: Int) async -> FeatureDistanceComputer?

    // MARK: §9 — device-restore remap

    func cloudIdentifiers(forLocalIds: [String]) async -> [String: String]
    func localIdentifiers(forCloudIds: [String]) async -> [String: String]

    // MARK: Commit (APP_PLATFORM.md §2)

    /// One atomic performChanges block. Throws CommitChunkError.userCancelled
    /// when the user declines the system dialog (whole chunk rolled back).
    func performCommitChunk(_ plan: CommitChunkPlan) async throws

    /// Post-commit existence check for receipt math and journal recovery.
    func existingAssetIds(among ids: [String]) async -> Set<String>

    /// Modification dates for pre-commit re-validation.
    func modificationDates(for ids: [String]) async -> [String: Date]
}

public enum GatewayError: Error, Sendable {
    case expiredChangeToken
    case notAuthorized
    case unavailable(String)
}
