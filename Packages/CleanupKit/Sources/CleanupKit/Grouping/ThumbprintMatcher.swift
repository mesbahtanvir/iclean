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
struct ThumbprintMatcher {
    private static let blocks = 16

    /// What the correlation needs of one photo, computed once.
    private struct Profile {
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
    private let cacheLimit: Int
    private var profiles: [Int: Profile] = [:]

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
        if let cached = profiles[i] { return cached }
        // Bound the memory: the working set of one bucket is far smaller than the limit.
        if profiles.count >= cacheLimit { profiles.removeAll(keepingCapacity: true) }
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
        let p = Profile(
            mean: Thumbprint.mean(pixels), isFlat: Thumbprint.isFlat(pixels), centered: centered,
            energy: energy)
        profiles[i] = p
        return p
    }
}
