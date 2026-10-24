import Foundation

public enum BurstThresholds {
    /// Frames of one burst that must be in the library for it to be listed (spec 015 FR-001).
    public static let minimumFrames = 2
}

/// Every burst with two or more frames in the library, one group each, the frame worth keeping
/// suggested (spec 015, Story 1). Needs only metadata, so a burst whose frames are in the cloud is
/// listed too; the keeper rule then falls back to the frame Photos shows.
public struct BurstDetector: CategoryDetector {
    public let category = CleanupCategory.bursts
    public let needsAnalysis = false

    public init() {}

    public func detect(items: [LibraryItem]) -> [ResultGroup] {
        var byBurst: [String: [LibraryItem]] = [:]
        for item in items where item.metadata.kind.isStillImage {
            guard let burst = item.metadata.burstID else { continue }
            byBurst[burst, default: []].append(item)
        }
        return byBurst.values
            .filter { $0.count >= BurstThresholds.minimumFrames }
            .map { frames -> (Date, ResultGroup) in
                let keepers = KeeperRules.burstKeepers(frames)
                let group = ResultGroup(
                    type: .burst, members: KeeperRules.ordered(frames, keepers: keepers),
                    keepers: keepers,
                    confidence: frames.contains { $0.analysisSource == .cloudPreview }
                        ? .lower : .normal)
                let newest = frames.compactMap(\.metadata.captureDate).max() ?? .distantPast
                return (newest, group)
            }
            // Newest burst first; the id breaks ties so the order is the same on every build.
            .sorted { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1.id < $1.1.id }
            .map(\.1)
    }
}
