import Foundation
import PhotoGateway

/// Similar-shot clustering within a session window (SCAN_PIPELINE.md §6.3).
/// Edge predicate: featurePrintDistance ≤ θ AND pHash Hamming ≤ H_sim — both
/// pairwise; the band index plays no role here. Embeddings are transient:
/// the caller hands in a FeatureDistanceComputer and discards it afterward.
public enum SimilarClusterer {
    public struct Config: Sendable {
        public var theta: Double
        public var hammingSimMax: Int
        public var maxCardMembers: Int

        /// Shipped starting points for feature-print revision 2
        /// (calibration.json regenerates per revision — SCAN_PIPELINE.md §6.3).
        public init(theta: Double = 0.55, hammingSimMax: Int = 26, maxCardMembers: Int = 12) {
            self.theta = theta
            self.hammingSimMax = hammingSimMax
            self.maxCardMembers = maxCardMembers
        }
    }

    public struct Member: Sendable {
        public let id: String
        public let phash: UInt64?
        public let capturedAt: Date?

        public init(id: String, phash: UInt64?, capturedAt: Date?) {
            self.id = id
            self.phash = phash
            self.capturedAt = capturedAt
        }
    }

    public struct SimilarCluster: Sendable {
        public let memberIds: [String] // all members incl. eventual keeper, sorted
        /// Confidence demotion for narrative sequences: wide time spread and
        /// large internal distances lower confidence rather than suppressing
        /// (SCAN_PIPELINE.md §6.3, DESIGN.md §4.2).
        public let narrativeDemotion: Double // 0 (none) … 1 (heavy)
    }

    public static func cluster(
        members: [Member],
        distances: FeatureDistanceComputer,
        config: Config = Config()
    ) -> [SimilarCluster] {
        let sorted = members.sorted { $0.id < $1.id } // determinism
        guard sorted.count >= 2 else { return [] }

        var unionFind = UnionFind(count: sorted.count)
        var edgeDistances: [Double] = []

        for i in 0..<sorted.count {
            for j in (i + 1)..<sorted.count {
                guard let distance = distances.distance(sorted[i].id, sorted[j].id),
                      distance <= config.theta
                else { continue }
                if let hashA = sorted[i].phash, let hashB = sorted[j].phash {
                    guard PerceptualHash.hamming64(hashA, hashB) <= config.hammingSimMax else { continue }
                }
                unionFind.union(i, j)
                edgeDistances.append(distance)
            }
        }

        var clusters: [SimilarCluster] = []
        for component in unionFind.components(minSize: 2) {
            let clusterMembers = component.map { sorted[$0] }
            for piece in splitOversized(clusterMembers, maxSize: config.maxCardMembers) {
                clusters.append(
                    SimilarCluster(
                        memberIds: piece.map(\.id).sorted(),
                        narrativeDemotion: narrativeDemotion(piece)
                    )
                )
            }
        }
        return clusters
    }

    /// Clusters > 12 pre-split on the largest internal time gaps — 12 is the
    /// most a card filmstrip can be audited at (DESIGN.md §7).
    private static func splitOversized(_ members: [Member], maxSize: Int) -> [[Member]] {
        guard members.count > maxSize else { return [members] }
        let byTime = members.sorted {
            let l = $0.capturedAt ?? .distantPast
            let r = $1.capturedAt ?? .distantPast
            return l == r ? $0.id < $1.id : l < r
        }
        var bestIndex = byTime.count / 2
        var bestGap: TimeInterval = -1
        for index in 1..<byTime.count {
            let gap = (byTime[index].capturedAt ?? .distantPast)
                .timeIntervalSince(byTime[index - 1].capturedAt ?? .distantPast)
            if gap > bestGap {
                bestGap = gap
                bestIndex = index
            }
        }
        let left = Array(byTime[..<bestIndex])
        let right = Array(byTime[bestIndex...])
        return splitOversized(left, maxSize: maxSize) + splitOversized(right, maxSize: maxSize)
    }

    /// Narrative sequences (kid opening a present) look like similar clusters
    /// but each frame matters: time spread across the cluster is the proxy.
    private static func narrativeDemotion(_ members: [Member]) -> Double {
        let dates = members.compactMap(\.capturedAt).sorted()
        guard let first = dates.first, let last = dates.last, dates.count >= 2 else { return 0 }
        let spread = last.timeIntervalSince(first)
        // ≤ 10 s: burst-like, no demotion. ≥ 120 s: heavy demotion.
        return min(1.0, max(0.0, (spread - 10) / 110))
    }
}
