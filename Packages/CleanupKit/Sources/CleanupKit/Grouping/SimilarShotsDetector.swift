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

    // Levels (spec 011). `medium` is the rule above, unchanged. The others are starting values to be
    // calibrated on real libraries (`ScaleBench --levels-profile`).

    /// "Almost identical": the feature print is nearly the same and the miniatures correlate strongly.
    public static let tightFeaturePrint = 0.04
    public static let tightThumbprint = 0.7
    /// Without a feature print, only the miniatures can say it.
    public static let tightThumbprintWithoutPrint = 0.85
    /// "Same scene": further apart in the feature print, with some agreement of the miniatures.
    public static let wideFeaturePrint = 0.22
    public static let wideThumbprint = 0.3
    public static let wideThumbprintWithoutPrint = 0.35
}

/// Groups shots of the same moment and suggests the best one (Story 3). With levels (spec 011) it can
/// look for almost identical frames only, for the same shot (the default, as before spec 011), or for
/// everything that looks like the same scene.
public struct SimilarShotsDetector: CategoryDetector {
    public let category = CleanupCategory.similar
    public let needsAnalysis = true
    /// Threads the comparisons may use (spec 009). One runs the plain serial loop.
    public let parallelism: Int
    /// Photos below which the serial loop is used, because splitting the work costs more than it
    /// saves. Tests lower it to run the parallel code on a small library.
    let parallelThreshold: Int
    /// The level to list; nil lists the default, `medium`.
    let levels: ResultLevels?

    public init(parallelism: Int = 1, levels: ResultLevels? = nil) {
        self.init(parallelism: parallelism, parallelThreshold: 1_000, levels: levels)
    }

    init(parallelism: Int, parallelThreshold: Int, levels: ResultLevels? = nil) {
        self.parallelism = max(1, parallelism)
        self.parallelThreshold = parallelThreshold
        self.levels = levels
    }

    public func detect(items: [LibraryItem]) -> [ResultGroup] {
        detectLevelled(items: items, all: items).groups
    }

    public func detectLevelled(items: [LibraryItem], all: [LibraryItem]) -> LevelledDetection {
        let chosen = levels?[.similar] ?? CleanupCategory.similar.defaultLevel
        let photos = items
            .filter { ($0.metadata.kind == .photo || $0.metadata.kind == .livePhoto) && $0.analysis != nil }
            .sorted { ($0.metadata.captureDate ?? .distantPast) < ($1.metadata.captureDate ?? .distantPast) }
        guard photos.count >= 2 else {
            return LevelledDetection(groups: [], level: chosen, levels: [])
        }

        // Every pair that is the same moment at some level, with the tightest level it reaches.
        let edges: [Edge]
        if parallelism > 1, photos.count >= parallelThreshold {
            edges = sameMomentPairsInParallel(photos)
        } else {
            let prints = FeaturePrintCache()
            var found: [Edge] = []
            for i in photos.indices {
                guard let di = photos[i].metadata.captureDate else { continue }
                var j = i + 1
                while j < photos.count, let dj = photos[j].metadata.captureDate,
                    dj.timeIntervalSince(di) <= SimilarThresholds.window
                {
                    if let level = pairLevel(photos[i], photos[j], featurePrintDistance: nil, prints: prints) {
                        found.append(Edge(i: i, j: j, level: level))
                    }
                    j += 1
                }
            }
            edges = found
        }
        // Burst frames always belong together, even if more than a minute apart (but a burst is no
        // proof that two frames are almost identical).
        var bursts: [(Int, Int)] = []
        var byBurst: [String: Int] = [:]
        for (i, p) in photos.enumerated() {
            guard let burst = p.metadata.burstID else { continue }
            if let first = byBurst[burst] { bursts.append((first, i)) } else { byBurst[burst] = i }
        }

        func sets(at level: ResultLevel) -> [[Int]] {
            var uf = UnionFind(count: photos.count)
            for e in edges where e.level <= level { uf.union(e.i, e.j) }
            if level >= .medium { for (a, b) in bursts { uf.union(a, b) } }
            return uf.groups()
        }
        let summaries = ResultLevel.allCases.map { level -> LevelSummary in
            let found = sets(at: level)
            let count = found.reduce(0) { $0 + $1.count }
            return LevelSummary(level: level, groups: found.count, photos: count, removable: count - found.count)
        }
        let groups = sets(at: chosen).map { indices in
            let members = indices.map { photos[$0] }
            let keepers = KeeperRules.similarKeepers(members)
            return ResultGroup(
                type: .similarShots, members: KeeperRules.ordered(members, keepers: keepers),
                keepers: keepers,
                confidence: members.contains { $0.analysisSource == .cloudPreview } ? .lower : .normal)
        }
        return LevelledDetection(groups: groups, level: chosen, levels: summaries)
    }

    /// A pair of photos (indices into the sorted list) that is the same moment at `level` or looser.
    struct Edge: Sendable {
        var i: Int
        var j: Int
        var level: ResultLevel
    }

    /// The tightest level at which two photos are the same moment, or nil. `featurePrintDistance` is
    /// `.infinity` when Vision was unavailable for either photo; nil asks the cache to work it out.
    /// At `medium` this is exactly `isSameMoment`.
    func pairLevel(
        _ a: LibraryItem, _ b: LibraryItem, featurePrintDistance known: Double?,
        prints: FeaturePrintCache?
    ) -> ResultLevel? {
        let sameBurst = a.metadata.burstID != nil && a.metadata.burstID == b.metadata.burstID
        let fp = known ?? prints?.distance(a, b) ?? .infinity
        // The miniatures' correlation costs more than the feature print's distance and most pairs do
        // not need it, so it is worked out only when a rule asks for it.
        var correlation: Double?
        func t() -> Double {
            if let correlation { return correlation }
            let value = Thumbprint.similarity(
                a.analysis?.thumbprint ?? Data(), b.analysis?.thumbprint ?? Data())
            correlation = value
            return value
        }
        if fp.isFinite {
            if fp < SimilarThresholds.tightFeaturePrint && t() >= SimilarThresholds.tightThumbprint {
                return .tight
            }
            if sameBurst || fp < SimilarThresholds.featurePrint
                || (fp < SimilarThresholds.featurePrintAgreement && t() >= SimilarThresholds.thumbprint)
            {
                return .medium
            }
            if fp < SimilarThresholds.wideFeaturePrint && t() >= SimilarThresholds.wideThumbprint {
                return .wide
            }
            return nil
        }
        if t() >= SimilarThresholds.tightThumbprintWithoutPrint { return .tight }
        if sameBurst || t() >= SimilarThresholds.thumbprint { return .medium }
        return t() >= SimilarThresholds.wideThumbprintWithoutPrint ? .wide : nil
    }

    /// The pairs of `photos` (sorted by date) that are the same moment at some level, found by several
    /// threads: the feature prints are decoded once, then each thread takes runs of first photos and
    /// tests them against the photos that follow within the window. Whether a pair is the same moment
    /// depends on the pair alone, so the sets joined from these pairs are the serial loop's.
    func sameMomentPairsInParallel(_ photos: [LibraryItem]) -> [Edge] {
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
        let found = Slots<[Edge]>(count: queue.count)
        Parallel.run(workers: Parallel.workers(for: queue.count, limit: parallelism)) { _ in
            while let block = queue.take() {
                var edges: [Edge] = []
                for i in (block * 64)..<min(count, block * 64 + 64) {
                    guard let di = photos[i].metadata.captureDate else { continue }
                    var j = i + 1
                    while j < count, let dj = photos[j].metadata.captureDate,
                        dj.timeIntervalSince(di) <= SimilarThresholds.window
                    {
                        let distance =
                            decoded[i].flatMap { a in
                                decoded[j].map { b in FeaturePrint.distance(a, b) }
                            } ?? .infinity
                        if let level = pairLevel(
                            photos[i], photos[j], featurePrintDistance: distance, prints: nil)
                        {
                            edges.append(Edge(i: i, j: j, level: level))
                        }
                        j += 1
                    }
                }
                found.set(block, edges)
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
