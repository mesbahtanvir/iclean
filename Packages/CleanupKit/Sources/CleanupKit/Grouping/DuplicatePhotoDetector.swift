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

    public init() {}

    public func detect(items: [LibraryItem]) -> [ResultGroup] {
        let photos = items.filter {
            ($0.metadata.kind == .photo || $0.metadata.kind == .livePhoto) && $0.analysis != nil
        }
        let groups = DuplicateGrouping.group(photos)
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
        _ items: [LibraryItem], extraCheck: (LibraryItem, LibraryItem) -> Bool = { _, _ in true }
    ) -> [[LibraryItem]] {
        let hashes = items.map { $0.analysis?.dHash ?? 0 }
        let pairs = HashIndex(maxDistance: DuplicateThresholds.hashDistance).candidatePairs(hashes)
        var uf = UnionFind(count: items.count)
        for (i, j) in pairs {
            let a = items[i]
            let b = items[j]
            // Edited versions are never duplicates of their originals.
            guard a.metadata.hasAdjustments == b.metadata.hasAdjustments else { continue }
            guard sameAspect(a.metadata, b.metadata), extraCheck(a, b) else { continue }
            let ta = a.analysis?.thumbprint ?? Data()
            let tb = b.analysis?.thumbprint ?? Data()
            guard Thumbprint.detailSimilarity(ta, tb) >= DuplicateThresholds.thumbprint,
                Thumbprint.meanAbsoluteDifference(ta, tb) <= DuplicateThresholds.brightness
            else { continue }
            uf.union(i, j)
        }
        return uf.groups().map { $0.map { items[$0] } }
    }

    static func sameAspect(_ a: AssetMetadata, _ b: AssetMetadata) -> Bool {
        let ra = a.aspectRatio
        let rb = b.aspectRatio
        guard ra > 0, rb > 0 else { return false }
        return abs(ra - rb) / max(ra, rb) <= DuplicateThresholds.aspectRatio
    }
}
