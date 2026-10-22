import Foundation

/// Thresholds for duplicate detection (research R3). Starting values; tuned by the
/// accuracy tests.
public enum DuplicateThresholds {
    /// Maximum differing dHash bits for a candidate. Generous, because heavy
    /// recompression flips several bits in smooth areas; the thumbprint confirms.
    public static let hashDistance = 10
    /// Minimum thumbprint detail correlation to confirm a candidate. Copies measure
    /// ≥ 0.88 even after heavy recompression; crops, different photos and different
    /// blurry photos ≤ 0.16. Burst frames where nothing moved can exceed this and are
    /// then treated as duplicates, which is the useful outcome for near-identical shots.
    public static let thumbprint = 0.85
    /// Maximum average brightness difference (0…255) between thumbprints. Copies
    /// measure ≤ 9.3; burst frames with a moving subject ≥ 13; low-detail scenes
    /// (sky, walls) that only share a layout usually far more.
    public static let brightness = 11.0
    /// Maximum relative difference in aspect ratio.
    public static let aspectRatio = 0.01
}

/// Finds exact and near-exact duplicate photos (Story 1, FR-002).
public struct DuplicatePhotoDetector: CategoryDetector {
    public let category = CleanupCategory.duplicates
    public let needsAnalysis = true
    /// Threads the pair confirmation may use (spec 009). One runs the plain serial loop.
    public let parallelism: Int
    /// Photos below which the serial loop is used, because splitting the work costs more than it
    /// saves. Tests lower it to run the parallel code on a small library.
    let parallelThreshold: Int

    public init(parallelism: Int = 1) {
        self.init(parallelism: parallelism, parallelThreshold: 1_000)
    }

    init(parallelism: Int, parallelThreshold: Int) {
        self.parallelism = max(1, parallelism)
        self.parallelThreshold = parallelThreshold
    }

    public func detect(items: [LibraryItem]) -> [ResultGroup] {
        let photos = items.filter {
            ($0.metadata.kind == .photo || $0.metadata.kind == .livePhoto) && $0.analysis != nil
        }
        let groups = DuplicateGrouping.group(
            photos, parallelism: parallelism, parallelThreshold: parallelThreshold)
        // How many photos share each timestamp, over everything that is being examined.
        let context = DateContext(items: items)
        return groups.map { members in
            let keepers = KeeperRules.duplicateKeepers(members, context: context)
            return ResultGroup(
                type: .duplicatePhotos, members: KeeperRules.ordered(members, keepers: keepers),
                keepers: keepers,
                confidence: members.contains { $0.analysisSource == .cloudPreview }
                    ? .lower : .normal,
                dateNotes: KeeperRules.dateNotes(members, context: context))
        }
    }
}

/// Shared by photo and video duplicate detection.
enum DuplicateGrouping {
    static func group(
        _ items: [LibraryItem], extraCheck: (@Sendable (LibraryItem, LibraryItem) -> Bool)? = nil,
        parallelism: Int = 1, parallelThreshold: Int = 1_000
    ) -> [[LibraryItem]] {
        if parallelism > 1, items.count >= parallelThreshold {
            return groupInParallel(items, extraCheck: extraCheck, workers: parallelism)
        }
        let hashes = items.map { $0.analysis?.dHash ?? 0 }
        var matcher = ThumbprintMatcher(items.map { $0.analysis?.thumbprint ?? Data() })
        // Read once, so the loop over millions of candidate pairs never copies an item.
        let edited = items.map(\.metadata.hasAdjustments)
        let ratio = items.map(\.metadata.aspectRatio)
        var uf = UnionFind(count: items.count)
        HashIndex(maxDistance: DuplicateThresholds.hashDistance).forEachCandidatePair(hashes) {
            i, j in
            // Two photos already known to be copies of one another need no second proof.
            guard uf.find(i) != uf.find(j) else { return }
            // Edited versions are never duplicates of their originals.
            guard edited[i] == edited[j], sameAspect(ratio[i], ratio[j]) else { return }
            if let extraCheck, !extraCheck(items[i], items[j]) { return }
            guard matcher.confirms(i, j) else { return }
            uf.union(i, j)
        }
        return uf.groups().map { $0.map { items[$0] } }
    }

    /// The same groups as the serial loop, found by several threads. The groups are the connected
    /// sets of the pairs that pass every test, and whether a pair passes does not depend on the
    /// order the pairs are tried in. Each worker takes slabs of candidate pairs, joins what it
    /// confirms in its own union-find (skipping pairs it already knows to be joined, as the serial
    /// loop does) and keeps the confirmed pairs that joined two sets. Joining every worker's list
    /// in a fresh union-find gives the sets of all pairs, and `groups()` lists them by smallest
    /// member, the same order as before.
    static func groupInParallel(
        _ items: [LibraryItem], extraCheck: (@Sendable (LibraryItem, LibraryItem) -> Bool)?,
        workers requested: Int
    ) -> [[LibraryItem]] {
        let hashes = items.map { $0.analysis?.dHash ?? 0 }
        let matcher = ThumbprintMatcher(items.map { $0.analysis?.thumbprint ?? Data() })
        let edited = items.map(\.metadata.hasAdjustments)
        let ratio = items.map(\.metadata.aspectRatio)
        let index = HashIndex(maxDistance: DuplicateThresholds.hashDistance)
        let buckets = index.buckets(hashes)
        let slabs = index.slabs(buckets, targetPairs: 20_000)
        let workers = Parallel.workers(for: slabs.count, limit: requested)
        // High-pass images are computed once for all threads, up to about 130 MB of them.
        let shared = SharedProfiles(count: items.count, limit: 16_384)
        let queue = WorkQueue(count: slabs.count)
        let found = Collector<[(Int, Int)]>()
        Parallel.run(workers: workers) { _ in
            var matcher = matcher.forAnotherWorker(cacheLimit: 0, shared: shared)
            var joined = UnionFind(count: items.count)
            var edges: [(Int, Int)] = []
            while let k = queue.take() {
                index.forEachCandidatePair(in: slabs[k], buckets: buckets, hashes: hashes) {
                    i, j in
                    guard joined.find(i) != joined.find(j) else { return }
                    guard edited[i] == edited[j], sameAspect(ratio[i], ratio[j]) else { return }
                    if let extraCheck, !extraCheck(items[i], items[j]) { return }
                    guard matcher.confirms(i, j) else { return }
                    joined.union(i, j)
                    edges.append((i, j))
                }
            }
            found.add(edges)
        }
        var uf = UnionFind(count: items.count)
        for edges in found.all { for (i, j) in edges { uf.union(i, j) } }
        return uf.groups().map { $0.map { items[$0] } }
    }

    static func sameAspect(_ a: AssetMetadata, _ b: AssetMetadata) -> Bool {
        sameAspect(a.aspectRatio, b.aspectRatio)
    }

    static func sameAspect(_ ra: Double, _ rb: Double) -> Bool {
        guard ra > 0, rb > 0 else { return false }
        return abs(ra - rb) / max(ra, rb) <= DuplicateThresholds.aspectRatio
    }
}
