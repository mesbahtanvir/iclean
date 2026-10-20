/// Finds pairs of 64-bit hashes within a small Hamming distance without comparing
/// every pair. The hash is split into (maxDistance + 1) chunks: by the pigeonhole
/// principle, two hashes within `maxDistance` bits share at least one identical chunk.
struct HashIndex {
    let maxDistance: Int
    private let chunks: [(shift: UInt64, mask: UInt64)]

    init(maxDistance: Int) {
        self.maxDistance = maxDistance
        let count = maxDistance + 1
        var chunks: [(UInt64, UInt64)] = []
        var start = 0
        for i in 0..<count {
            let bits = 64 / count + (i < 64 % count ? 1 : 0)
            let mask: UInt64 = bits == 64 ? .max : (1 << UInt64(bits)) - 1
            chunks.append((UInt64(start), mask))
            start += bits
        }
        self.chunks = chunks
    }

    /// Index pairs (i < j) whose hashes are within `maxDistance` bits.
    func candidatePairs(_ hashes: [UInt64]) -> [(Int, Int)] {
        var pairs: [(Int, Int)] = []
        forEachCandidatePair(hashes) { pairs.append(($0, $1)) }
        return pairs
    }

    /// The same pairs, one at a time and in the same order, without holding them: a library with
    /// many look-alike photos has millions of candidate pairs (9.8 million for 27,000 photos of
    /// the large demo library), which as an array was hundreds of MB (spec 008).
    func forEachCandidatePair(_ hashes: [UInt64], _ body: (Int, Int) -> Void) {
        for (c, chunk) in chunks.enumerated() {
            var buckets: [UInt64: [Int]] = [:]
            for (i, h) in hashes.enumerated() {
                buckets[(h >> chunk.shift) & chunk.mask, default: []].append(i)
            }
            for bucket in buckets.values where bucket.count > 1 {
                for a in 0..<bucket.count {
                    for b in (a + 1)..<bucket.count {
                        let i = bucket[a]
                        let j = bucket[b]
                        // Report each pair once: only in the first chunk where it matches.
                        if sharesEarlierChunk(hashes[i], hashes[j], before: c) { continue }
                        if hammingDistance(hashes[i], hashes[j]) <= maxDistance {
                            body(min(i, j), max(i, j))
                        }
                    }
                }
            }
        }
    }

    private func sharesEarlierChunk(_ a: UInt64, _ b: UInt64, before c: Int) -> Bool {
        for k in 0..<c where (a >> chunks[k].shift) & chunks[k].mask == (b >> chunks[k].shift) & chunks[k].mask {
            return true
        }
        return false
    }
}

/// Union-find for building groups from linked pairs.
struct UnionFind {
    private var parent: [Int]

    init(count: Int) { parent = Array(0..<count) }

    mutating func find(_ x: Int) -> Int {
        var x = x
        while parent[x] != x {
            parent[x] = parent[parent[x]]
            x = parent[x]
        }
        return x
    }

    mutating func union(_ a: Int, _ b: Int) {
        let ra = find(a)
        let rb = find(b)
        if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
    }

    /// Sets with at least `minSize` members, as index lists.
    mutating func groups(minSize: Int = 2) -> [[Int]] {
        var byRoot: [Int: [Int]] = [:]
        for i in parent.indices { byRoot[find(i), default: []].append(i) }
        return byRoot.values.filter { $0.count >= minSize }.sorted { $0[0] < $1[0] }
    }
}
