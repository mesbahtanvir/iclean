import Foundation

/// Decides whether two photos' miniatures confirm a duplicate candidate: the fine detail
/// correlates (`DuplicateThresholds.thumbprint`) and the brightness agrees
/// (`DuplicateThresholds.brightness`). The answer is exactly
/// `detailSimilarity >= thumbprint && meanAbsoluteDifference <= brightness`, with the same
/// arithmetic in the same order, reached the cheap way round (spec 008): a library with many
/// look-alike photos has millions of candidate pairs, and recomputing both high-pass images for
/// every pair took 281 seconds for 27,000 photos.
///
/// - A lower bound on the brightness difference from 16 block sums rejects most pairs of different
///   scenes without reading the 1,024 pixels. By the triangle inequality the sum of absolute
///   differences of a block is at least the absolute difference of the block sums, so a pair
///   rejected here has a mean absolute difference above the limit: nothing that would pass is lost.
/// - The brightness difference is exact and checked before the correlation.
/// - Each photo's centred high-pass image is computed once and kept, up to a bound, so the
///   correlation of a pair is one pass over two arrays.
struct ThumbprintMatcher: Sendable {
    private static let blocks = 16

    /// What the correlation needs of one photo, computed once.
    fileprivate struct Profile: Sendable {
        var mean: Double
        var isFlat: Bool
        /// The high-pass image minus its own mean.
        var centered: [Double]
        /// Sum of squares of `centered`.
        var energy: Double
    }

    private let data: [Data]
    private let coarse: [Int32]
    private let isUsable: [Bool]
    private var cacheLimit: Int
    private var profiles: [Int: Profile] = [:]
    /// Set for matchers that run on several threads: the profiles are computed once for all of them.
    private var shared: SharedProfiles?

    init(_ thumbprints: [Data], cacheLimit: Int = 4_000) {
        self.cacheLimit = cacheLimit
        data = thumbprints
        var coarse = [Int32](repeating: 0, count: thumbprints.count * Self.blocks)
        var usable = [Bool](repeating: false, count: thumbprints.count)
        let side = Thumbprint.side
        let blockSide = side / 4
        for (k, t) in thumbprints.enumerated() where t.count == side * side {
            usable[k] = true
            t.withUnsafeBytes { raw in
                let bytes = raw.bindMemory(to: UInt8.self)
                for y in 0..<side {
                    for x in 0..<side {
                        coarse[k * Self.blocks + (y / blockSide) * 4 + x / blockSide] +=
                            Int32(bytes[y * side + x])
                    }
                }
            }
        }
        self.coarse = coarse
        isUsable = usable
    }

    /// A matcher for another thread: shares the miniatures and their block sums (copy on write,
    /// never copied) and, when `shared` is given, the high-pass images too, which are then computed
    /// once for all threads. Without it the copy keeps a cache of its own.
    func forAnotherWorker(cacheLimit: Int, shared: SharedProfiles? = nil) -> ThumbprintMatcher {
        var copy = self
        copy.cacheLimit = cacheLimit
        copy.profiles = [:]
        copy.shared = shared
        return copy
    }

    mutating func confirms(_ i: Int, _ j: Int) -> Bool {
        guard isUsable[i], isUsable[j] else { return false }
        // Cheap lower bound on the sum of absolute differences.
        var bound: Int32 = 0
        for b in 0..<Self.blocks {
            bound += abs(coarse[i * Self.blocks + b] - coarse[j * Self.blocks + b])
        }
        let pixels = Double(Thumbprint.side * Thumbprint.side)
        guard Double(bound) / pixels <= DuplicateThresholds.brightness else { return false }
        // Exact brightness difference, as `Thumbprint.meanAbsoluteDifference` computes it.
        var sum = 0
        data[i].withUnsafeBytes { a in
            data[j].withUnsafeBytes { b in
                for k in 0..<(Thumbprint.side * Thumbprint.side) {
                    sum += abs(Int(a[k]) - Int(b[k]))
                }
            }
        }
        guard Double(sum) / pixels <= DuplicateThresholds.brightness else { return false }

        let a = profile(i)
        let b = profile(j)
        // Flat miniatures (a black frame) match by brightness alone, as `detailSimilarity` says.
        if a.isFlat || b.isFlat {
            return a.isFlat && b.isFlat && abs(a.mean - b.mean) < 4
        }
        // Same sums, same order as `Thumbprint.correlation`.
        guard a.energy > 1e-9, b.energy > 1e-9 else { return 0 >= DuplicateThresholds.thumbprint }
        var sxy = 0.0
        for k in a.centered.indices { sxy += a.centered[k] * b.centered[k] }
        return sxy / (a.energy * b.energy).squareRoot() >= DuplicateThresholds.thumbprint
    }

    private mutating func profile(_ i: Int) -> Profile {
        if let shared { return shared.profile(i) { makeProfile(i) } }
        if let cached = profiles[i] { return cached }
        // Bound the memory: the working set of one bucket is far smaller than the limit.
        if profiles.count >= cacheLimit { profiles.removeAll(keepingCapacity: true) }
        let p = makeProfile(i)
        profiles[i] = p
        return p
    }

    private func makeProfile(_ i: Int) -> Profile {
        let pixels = Thumbprint.values(data[i])!
        let detail = Thumbprint.highPass(pixels)
        let m = Thumbprint.mean(detail)
        var centered = detail
        var energy = 0.0
        for k in detail.indices {
            let d = detail[k] - m
            centered[k] = d
            energy += d * d
        }
        return Profile(
            mean: Thumbprint.mean(pixels), isFlat: Thumbprint.isFlat(pixels), centered: centered,
            energy: energy)
    }
}

/// High-pass profiles computed once and shared by the threads of a parallel build (spec 009).
/// Profiles never change, so a thread that finds one can use it without further locking; the table
/// stops storing at `limit` profiles (about 8 KB each) and computes the rest every time, so its
/// memory is bounded however many photos there are.
final class SharedProfiles: @unchecked Sendable {
    private let slots: UnsafeMutablePointer<ThumbprintMatcher.Profile?>
    private let count: Int
    private let limit: Int
    private let stripes = (0..<64).map { _ in NSLock() }
    private let totalLock = NSLock()
    private var stored = 0

    init(count: Int, limit: Int) {
        self.count = count
        self.limit = limit
        slots = .allocate(capacity: max(1, count))
        slots.initialize(repeating: nil, count: max(1, count))
    }

    deinit {
        slots.deinitialize(count: max(1, count))
        slots.deallocate()
    }

    fileprivate func profile(
        _ i: Int, compute: () -> ThumbprintMatcher.Profile
    ) -> ThumbprintMatcher.Profile {
        let lock = stripes[i & 63]
        if let found = lock.withLock({ slots[i] }) { return found }
        let made = compute()
        let room = totalLock.withLock { () -> Bool in
            guard stored < limit else { return false }
            stored += 1
            return true
        }
        if room {
            lock.withLock { slots[i] = made }
        }
        return made
    }
}
