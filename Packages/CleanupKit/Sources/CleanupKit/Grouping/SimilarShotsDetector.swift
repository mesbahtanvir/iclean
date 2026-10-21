import Foundation
import Vision

/// Thresholds for similar shots (research R4).
public enum SimilarThresholds {
    /// Only photos taken this close together are compared.
    public static let window: TimeInterval = 60
    /// Thumbprint correlation for "same moment". Burst frames measure 0.41–0.91,
    /// different photos ≤ 0.35.
    public static let thumbprint = 0.5
    /// Feature-print distance for "same moment", when Vision is available. Burst
    /// frames measure 0.02–0.07, different scenes ≥ 0.13.
    public static let featurePrint = 0.1
    /// When Vision is available it must also agree with the thumbprint, so photos
    /// that merely share a layout are not grouped.
    public static let featurePrintAgreement = 0.15
}

/// Groups shots of the same moment and suggests the best one (Story 3).
public struct SimilarShotsDetector: CategoryDetector {
    public let category = CleanupCategory.similar
    public let needsAnalysis = true
    /// Threads the comparisons may use (spec 009). One runs the plain serial loop.
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
        let photos = items
            .filter { ($0.metadata.kind == .photo || $0.metadata.kind == .livePhoto) && $0.analysis != nil }
            .sorted { ($0.metadata.captureDate ?? .distantPast) < ($1.metadata.captureDate ?? .distantPast) }
        guard photos.count >= 2 else { return [] }

        var uf = UnionFind(count: photos.count)
        if parallelism > 1, photos.count >= parallelThreshold {
            for (i, j) in sameMomentPairsInParallel(photos) { uf.union(i, j) }
        } else {
            let prints = FeaturePrintCache()
            for i in photos.indices {
                guard let di = photos[i].metadata.captureDate else { continue }
                var j = i + 1
                while j < photos.count, let dj = photos[j].metadata.captureDate,
                    dj.timeIntervalSince(di) <= SimilarThresholds.window
                {
                    if isSameMoment(photos[i], photos[j], prints: prints) { uf.union(i, j) }
                    j += 1
                }
            }
        }
        // Burst frames always belong together, even if more than a minute apart.
        var byBurst: [String: Int] = [:]
        for (i, p) in photos.enumerated() {
            guard let burst = p.metadata.burstID else { continue }
            if let first = byBurst[burst] { uf.union(first, i) } else { byBurst[burst] = i }
        }

        return uf.groups().map { indices in
            let members = indices.map { photos[$0] }
            let keepers = KeeperRules.similarKeepers(members)
            return ResultGroup(
                type: .similarShots, members: KeeperRules.ordered(members, keepers: keepers),
                keepers: keepers,
                confidence: members.contains { $0.analysisSource == .cloudPreview } ? .lower : .normal)
        }
    }

    /// The pairs of `photos` (sorted by date) that `isSameMoment` accepts, found by several threads:
    /// the feature prints are decoded once, then each thread takes runs of first photos and tests
    /// them against the photos that follow within the window. Whether a pair is the same moment
    /// depends on the pair alone, so the sets joined from these pairs are the serial loop's.
    func sameMomentPairsInParallel(_ photos: [LibraryItem]) -> [(Int, Int)] {
        let count = photos.count
        let observations = Slots<[FeaturePrintObservation?]>(count: (count + 255) / 256)
        let decodeQueue = WorkQueue(count: (count + 255) / 256)
        let workers = Parallel.workers(for: decodeQueue.count, limit: parallelism)
        Parallel.run(workers: workers) { _ in
            while let block = decodeQueue.take() {
                let range = (block * 256)..<min(count, block * 256 + 256)
                observations.set(
                    block,
                    range.map { k in
                        photos[k].analysis.flatMap { FeaturePrint.decode($0.featurePrint) }
                    })
            }
        }
        let decoded = observations.all.flatMap { $0 ?? [] }
        let queue = WorkQueue(count: (count + 63) / 64)
        let found = Slots<[(Int, Int)]>(count: queue.count)
        Parallel.run(workers: Parallel.workers(for: queue.count, limit: parallelism)) { _ in
            while let block = queue.take() {
                var pairs: [(Int, Int)] = []
                for i in (block * 64)..<min(count, block * 64 + 64) {
                    guard let di = photos[i].metadata.captureDate else { continue }
                    var j = i + 1
                    while j < count, let dj = photos[j].metadata.captureDate,
                        dj.timeIntervalSince(di) <= SimilarThresholds.window
                    {
                        let burst = photos[i].metadata.burstID
                        let sameBurst = burst != nil && burst == photos[j].metadata.burstID
                        let distance =
                            sameBurst
                            ? .infinity
                            : decoded[i].flatMap { a in
                                decoded[j].map { b in FeaturePrint.distance(a, b) }
                            } ?? .infinity
                        if isSameMoment(photos[i], photos[j], featurePrintDistance: distance) {
                            pairs.append((i, j))
                        }
                        j += 1
                    }
                }
                found.set(block, pairs)
            }
        }
        return found.all.flatMap { $0 ?? [] }
    }

    func isSameMoment(_ a: LibraryItem, _ b: LibraryItem, prints: FeaturePrintCache) -> Bool {
        // Frames of one burst need no comparison, so no feature print is decoded for them.
        if let burst = a.metadata.burstID, burst == b.metadata.burstID { return true }
        return isSameMoment(a, b, featurePrintDistance: prints.distance(a, b))
    }

    /// `featurePrintDistance` is `.infinity` when Vision was unavailable for either photo.
    func isSameMoment(_ a: LibraryItem, _ b: LibraryItem, featurePrintDistance fp: Double) -> Bool {
        if let burst = a.metadata.burstID, burst == b.metadata.burstID { return true }
        let t = Thumbprint.similarity(a.analysis?.thumbprint ?? Data(), b.analysis?.thumbprint ?? Data())
        if fp.isFinite {
            return fp < SimilarThresholds.featurePrint
                || (t >= SimilarThresholds.thumbprint && fp < SimilarThresholds.featurePrintAgreement)
        }
        return t >= SimilarThresholds.thumbprint
    }
}
