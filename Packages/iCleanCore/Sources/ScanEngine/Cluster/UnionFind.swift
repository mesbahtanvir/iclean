import Foundation

/// Union-find with path compression. Determinism: components are reported with
/// members sorted and keyed by their smallest member, so shuffled ingestion
/// orders yield identical clusters (SCAN_PIPELINE.md §13.3).
public struct UnionFind {
    private var parent: [Int]
    private var rank: [Int]

    public init(count: Int) {
        parent = Array(0..<count)
        rank = [Int](repeating: 0, count: count)
    }

    public mutating func find(_ x: Int) -> Int {
        var root = x
        while parent[root] != root { root = parent[root] }
        var current = x
        while parent[current] != root {
            let next = parent[current]
            parent[current] = root
            current = next
        }
        return root
    }

    public mutating func union(_ a: Int, _ b: Int) {
        let rootA = find(a)
        let rootB = find(b)
        guard rootA != rootB else { return }
        if rank[rootA] < rank[rootB] {
            parent[rootA] = rootB
        } else if rank[rootA] > rank[rootB] {
            parent[rootB] = rootA
        } else {
            parent[rootB] = rootA
            rank[rootA] += 1
        }
    }

    /// Components with ≥ minSize members, each sorted, ordered by smallest member.
    public mutating func components(minSize: Int = 2) -> [[Int]] {
        var groups: [Int: [Int]] = [:]
        for index in 0..<parent.count {
            groups[find(index), default: []].append(index)
        }
        return groups.values
            .filter { $0.count >= minSize }
            .map { $0.sorted() }
            .sorted { $0[0] < $1[0] }
    }
}
