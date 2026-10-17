import Foundation

/// Thresholds for duplicate videos (research R6).
public enum DuplicateVideoThresholds {
    /// Maximum difference in length, in seconds.
    public static let duration = 0.5
}

/// Finds copies of the same video from metadata and the poster frame, so videos
/// stored only in iCloud never need downloading (Story 5, FR-004b).
public struct DuplicateVideoDetector: CategoryDetector {
    public let category = CleanupCategory.duplicateVideos
    public let needsAnalysis = true

    public init() {}

    public func detect(items: [LibraryItem]) -> [ResultGroup] {
        let videos = items.filter { $0.metadata.kind == .video && $0.analysis != nil }
        let groups = DuplicateGrouping.group(videos) { a, b in
            guard let da = a.metadata.duration, let db = b.metadata.duration else { return false }
            return abs(da - db) <= DuplicateVideoThresholds.duration
        }
        return groups.map { members in
            let keepers = KeeperRules.duplicateKeepers(members)
            return ResultGroup(
                type: .duplicateVideos, members: KeeperRules.ordered(members, keepers: keepers),
                keepers: keepers,
                confidence: members.contains { $0.analysisSource == .cloudPreview } ? .lower : .normal)
        }
    }
}
