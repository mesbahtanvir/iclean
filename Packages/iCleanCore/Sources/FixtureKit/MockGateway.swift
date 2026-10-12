import Foundation
import PhotoGateway
import ScanEngine

/// In-memory gateway for unit tests and previews (SCAN_PIPELINE.md §13):
/// synthetic assets with synthetic pixels, no PhotoKit anywhere.
public final class MockGateway: PhotoLibraryGateway, @unchecked Sendable {
    public struct FixtureAsset: Sendable {
        public var stub: AssetStub
        public var thumbnail: GrayThumbnail?
        public var resource: ResourceInfo?
        public var vision: VisionSignals?
        public var originalAvailability: Availability
        public var byteHash: Data?
        public var embedding: [Double]? // toy embedding for distance computation

        public init(
            stub: AssetStub,
            thumbnail: GrayThumbnail?,
            resource: ResourceInfo? = nil,
            vision: VisionSignals? = nil,
            originalAvailability: Availability = .local,
            byteHash: Data? = nil,
            embedding: [Double]? = nil
        ) {
            self.stub = stub
            self.thumbnail = thumbnail
            self.resource = resource
            self.vision = vision
            self.originalAvailability = originalAvailability
            self.byteHash = byteHash
            self.embedding = embedding
        }
    }

    private let lock = NSLock()
    private var assets: [String: FixtureAsset] = [:]
    private var albums: [AlbumInfo] = []
    public var commitPlans: [CommitChunkPlan] = []
    public var cancelNextCommit = false

    public init(assets: [FixtureAsset] = [], albums: [AlbumInfo] = []) {
        for asset in assets { self.assets[asset.stub.id] = asset }
        self.albums = albums
    }

    public func add(_ asset: FixtureAsset) {
        lock.lock()
        defer { lock.unlock() }
        assets[asset.stub.id] = asset
    }

    private func snapshot() -> [String: FixtureAsset] {
        lock.lock()
        defer { lock.unlock() }
        return assets
    }

    // MARK: PhotoLibraryGateway

    public func enumerateAssets(batchSize: Int) -> AsyncThrowingStream<[AssetStub], Error> {
        let all = snapshot().values
            .map(\.stub)
            .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
        return AsyncThrowingStream { continuation in
            var index = 0
            while index < all.count {
                let end = min(index + batchSize, all.count)
                continuation.yield(Array(all[index..<end]))
                index = end
            }
            continuation.finish()
        }
    }

    public func persistentChanges(since token: Data?) -> AsyncThrowingStream<ChangeSet, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish() // fixtures don't mutate mid-test by default
        }
    }

    public func userAlbums() async throws -> [AlbumInfo] { albums }

    public func grayThumbnail(assetId: String, maxDimension: Int, allowNetwork: Bool) async -> ThumbnailResult {
        guard let asset = snapshot()[assetId] else { return .failed("missing fixture") }
        guard let thumbnail = asset.thumbnail else { return .needsConnection }
        return .ok(thumbnail)
    }

    public func probeOriginalAvailability(assetId: String) async -> Availability {
        snapshot()[assetId]?.originalAvailability ?? .unknown
    }

    public func byteHashIfLocal(assetId: String) async -> Data? {
        guard let asset = snapshot()[assetId], asset.originalAvailability == .local else { return nil }
        return asset.byteHash
    }

    public func resourceInfo(assetId: String) async -> ResourceInfo? {
        snapshot()[assetId]?.resource
    }

    public func visionSignals(assetId: String, maxDimension: Int) async -> VisionSignals? {
        snapshot()[assetId]?.vision
    }

    public func confirmNoFaces(assetId: String) async -> Bool {
        (snapshot()[assetId]?.vision?.faceCount ?? 1) == 0
    }

    public func featureDistances(assetIds: [String], maxDimension: Int) async -> FeatureDistanceComputer? {
        let all = snapshot()
        var embeddings: [String: [Double]] = [:]
        for id in assetIds {
            if let embedding = all[id]?.embedding { embeddings[id] = embedding }
        }
        guard !embeddings.isEmpty else { return nil }
        let captured = embeddings
        return FeatureDistanceComputer(visionRevision: 2) { a, b in
            guard let ea = captured[a], let eb = captured[b], ea.count == eb.count else { return nil }
            var sum = 0.0
            for index in 0..<ea.count {
                let delta = ea[index] - eb[index]
                sum += delta * delta
            }
            return sum.squareRoot()
        }
    }

    public func cloudIdentifiers(forLocalIds ids: [String]) async -> [String: String] {
        Dictionary(uniqueKeysWithValues: ids.map { ($0, "cloud-\($0)") })
    }

    public func localIdentifiers(forCloudIds ids: [String]) async -> [String: String] {
        Dictionary(uniqueKeysWithValues: ids.compactMap { cloudId in
            cloudId.hasPrefix("cloud-") ? (cloudId, String(cloudId.dropFirst(6))) : nil
        })
    }

    public func performCommitChunk(_ plan: CommitChunkPlan) async throws {
        if cancelNextCommit {
            cancelNextCommit = false
            throw CommitChunkError.userCancelled
        }
        lock.lock()
        commitPlans.append(plan)
        for id in plan.deleteIds { assets.removeValue(forKey: id) }
        lock.unlock()
    }

    public func existingAssetIds(among ids: [String]) async -> Set<String> {
        let all = snapshot()
        return Set(ids.filter { all[$0] != nil })
    }

    public func modificationDates(for ids: [String]) async -> [String: Date] {
        let all = snapshot()
        var out: [String: Date] = [:]
        for id in ids {
            if let date = all[id]?.stub.modifiedAt { out[id] = date }
        }
        return out
    }
}

/// Synthetic pixel factories for fixture libraries (SCAN_PIPELINE.md §13.1).
public enum FixturePixels {
    /// Deterministic pseudo-noise image — sharp, textured.
    public static func noise(width: Int = 64, height: Int = 64, seed: UInt64) -> GrayThumbnail {
        var state = seed == 0 ? 0x9e3779b97f4a7c15 : seed
        var pixels = [UInt8](repeating: 0, count: width * height)
        for index in 0..<pixels.count {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            pixels[index] = UInt8(truncatingIfNeeded: state)
        }
        return GrayThumbnail(width: width, height: height, pixels: pixels)
    }

    public static func flat(width: Int = 64, height: Int = 64, value: UInt8) -> GrayThumbnail {
        GrayThumbnail(width: width, height: height, pixels: [UInt8](repeating: value, count: width * height))
    }

    /// Box-blur an image `passes` times — the blur ladder.
    public static func blurred(_ source: GrayThumbnail, passes: Int) -> GrayThumbnail {
        var pixels = source.pixels
        let width = source.width
        let height = source.height
        for _ in 0..<passes {
            var next = pixels
            for y in 1..<(height - 1) {
                for x in 1..<(width - 1) {
                    let index = y * width + x
                    let sum = Int(pixels[index]) + Int(pixels[index - 1]) + Int(pixels[index + 1])
                        + Int(pixels[index - width]) + Int(pixels[index + width])
                    next[index] = UInt8(sum / 5)
                }
            }
            pixels = next
        }
        return GrayThumbnail(width: width, height: height, pixels: pixels)
    }

    /// Flip a few pixels — a recompressed near-duplicate.
    public static func perturbed(_ source: GrayThumbnail, flips: Int, seed: UInt64) -> GrayThumbnail {
        var pixels = source.pixels
        var state = seed | 1
        for _ in 0..<flips {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            let index = Int(state % UInt64(pixels.count))
            pixels[index] = pixels[index] &+ 24
        }
        return GrayThumbnail(width: source.width, height: source.height, pixels: pixels)
    }
}
