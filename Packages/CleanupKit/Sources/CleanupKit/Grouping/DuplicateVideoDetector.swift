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
    public let parallelism: Int

    public init(parallelism: Int = 1) { self.parallelism = max(1, parallelism) }

    public func detect(items: [LibraryItem]) -> [ResultGroup] {
        let videos = items.filter { $0.metadata.kind == .video && $0.analysis != nil }
        let groups = DuplicateGrouping.group(
            videos,
            extraCheck: { a, b in
                guard let da = a.metadata.duration, let db = b.metadata.duration else {
                    return false
                }
                return abs(da - db) <= DuplicateVideoThresholds.duration
            }, parallelism: parallelism)
        let context = DateContext(items: items)
        return groups.map { members in
            let keepers = KeeperRules.duplicateKeepers(members, context: context)
            return ResultGroup(
                type: .duplicateVideos, members: KeeperRules.ordered(members, keepers: keepers),
                keepers: keepers,
                confidence: members.contains { $0.analysisSource == .cloudPreview }
                    ? .lower : .normal,
                dateNotes: KeeperRules.dateNotes(members, context: context))
        }
    }
}
