import Foundation
import PhotoGateway

/// Exact/near-duplicate clustering (SCAN_PIPELINE.md §6.2). Layered,
/// cheapest-first; deterministic under shuffled input.
public enum DupeClusterer {
    /// Fast-path seed key (SCAN_PIPELINE.md §5-S1): dimensions alone are
    /// degenerate — capture time is what makes groups small.
    public struct SeedKey: Hashable, Sendable {
        public let width: Int
        public let height: Int
        public let createdAtSecond: Int64 // rounded to 1 s; -1 for undated
        public let durationHalfSeconds: Int64 // rounded to 0.5 s

        public init(stub: AssetStub) {
            width = stub.pixelWidth
            height = stub.pixelHeight
            createdAtSecond = stub.createdAt.map { Int64($0.timeIntervalSince1970.rounded()) } ?? -1
            durationHalfSeconds = Int64((stub.duration * 2).rounded())
        }
    }

    public struct Candidate: Sendable {
        public let stub: AssetStub
        public let phash: UInt64?
        public let fileSize: Int64?
        public let isEdited: Bool
        public let inAlbum: Bool
        public let byteHash: Data?

        public init(
            stub: AssetStub,
            phash: UInt64?,
            fileSize: Int64?,
            isEdited: Bool = false,
            inAlbum: Bool = false,
            byteHash: Data? = nil
        ) {
            self.stub = stub
            self.phash = phash
            self.fileSize = fileSize
            self.isEdited = isEdited
            self.inAlbum = inAlbum
            self.byteHash = byteHash
        }
    }

    public struct DupeCluster: Sendable {
        public let memberIds: [String]
        public let keeperId: String
        /// True only when byte hashes proved identity — the card may say
        /// "identical copy"; metadata+pHash matches say "near-certain copy"
        /// (DESIGN.md §4.1).
        public let byteVerified: Bool
        public let estBytesFreed: Int64
        public let sizesAreEstimates: Bool
    }

    public static let exactConfirmRadius = 2 // pHash Hamming ≤ 2 confirms (DESIGN.md §4.1)

    /// Partition one seed group into confirmed clusters:
    /// pHash ≤ 2 connectivity via union-find, then split by fileSize when known.
    public static func confirmClusters(in group: [Candidate]) -> [DupeCluster] {
        // Deterministic base order.
        let members = group.sorted { $0.stub.id < $1.stub.id }
        guard members.count >= 2 else { return [] }

        var unionFind = UnionFind(count: members.count)
        for i in 0..<members.count {
            for j in (i + 1)..<members.count {
                guard let hashA = members[i].phash, let hashB = members[j].phash else { continue }
                guard PerceptualHash.hamming64(hashA, hashB) <= exactConfirmRadius else { continue }
                // fileSize splits residual false merges — but only when both known.
                if let sizeA = members[i].fileSize, let sizeB = members[j].fileSize, sizeA != sizeB {
                    // Different bytes: not an exact-dupe pair (may still be a near-dupe
                    // pair via the band index path; that action re-evaluates separately).
                    continue
                }
                // Intentional edits can hash near-identically: dimension ratio is
                // already equal (seed key), so check the edited flag (DESIGN.md §4.1).
                if members[i].isEdited != members[j].isEdited { continue }
                unionFind.union(i, j)
            }
        }

        return unionFind.components(minSize: 2).map { component in
            let clusterMembers = component.map { members[$0] }
            let keeper = pickKeeper(clusterMembers)
            let doomed = clusterMembers.filter { $0.stub.id != keeper.stub.id }
            let byteVerified = clusterMembers.allSatisfy { $0.byteHash != nil }
                && Set(clusterMembers.compactMap(\.byteHash)).count == 1
            let freed = doomed.reduce(Int64(0)) { $0 + ($1.fileSize ?? 0) }
            let anyEstimate = doomed.contains { $0.fileSize == nil }
            return DupeCluster(
                memberIds: doomed.map(\.stub.id).sorted(),
                keeperId: keeper.stub.id,
                byteVerified: byteVerified,
                estBytesFreed: freed,
                sizesAreEstimates: anyEstimate
            )
        }
    }

    /// Keeper preference (SCAN_PIPELINE.md §6.2): favorite > in-album >
    /// richest metadata > highest resolution > earliest > id.
    public static func pickKeeper(_ members: [Candidate]) -> Candidate {
        members.min { a, b in
            if a.stub.isFavorite != b.stub.isFavorite { return a.stub.isFavorite }
            if a.inAlbum != b.inAlbum { return a.inAlbum }
            let richnessA = metadataRichness(a)
            let richnessB = metadataRichness(b)
            if richnessA != richnessB { return richnessA > richnessB }
            let pixelsA = a.stub.pixelWidth * a.stub.pixelHeight
            let pixelsB = b.stub.pixelWidth * b.stub.pixelHeight
            if pixelsA != pixelsB { return pixelsA > pixelsB }
            let dateA = a.stub.createdAt ?? .distantFuture
            let dateB = b.stub.createdAt ?? .distantFuture
            if dateA != dateB { return dateA < dateB }
            return a.stub.id < b.stub.id
        }!
    }

    private static func metadataRichness(_ candidate: Candidate) -> Int {
        var score = 0
        if candidate.stub.locationBucket != nil { score += 1 }
        if candidate.stub.createdAt != nil { score += 1 }
        if candidate.isEdited { score += 1 }
        return score
    }

    /// Fast-path group ranking: memberCount × estimated bytes, descending —
    /// biggest wins confirm first (SCAN_PIPELINE.md §5-S1).
    public static func rankSeedGroups<Key: Hashable>(
        _ groups: [Key: [AssetStub]]
    ) -> [(key: Key, members: [AssetStub])] {
        groups
            .filter { $0.value.count >= 2 }
            .map { (key: $0.key, members: $0.value) }
            .sorted { a, b in
                let scoreA = a.members.count * (a.members.first.map { $0.pixelWidth * $0.pixelHeight } ?? 0)
                let scoreB = b.members.count * (b.members.first.map { $0.pixelWidth * $0.pixelHeight } ?? 0)
                if scoreA != scoreB { return scoreA > scoreB }
                return (a.members.first?.id ?? "") < (b.members.first?.id ?? "")
            }
    }
}
