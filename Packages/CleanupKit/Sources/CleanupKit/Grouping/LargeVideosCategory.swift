import Foundation

/// The 50 largest videos, largest first. Nothing is pre-selected (Story 6, FR-004c).
public struct LargeVideosCategory: CategoryDetector {
    public static let limit = 50

    public let category = CleanupCategory.largeVideos
    public let needsAnalysis = false

    public init() {}

    public func detect(items: [LibraryItem]) -> [ResultGroup] {
        items
            .filter { $0.metadata.kind == .video }
            .sorted { $0.effectiveByteSize > $1.effectiveByteSize }
            .prefix(Self.limit)
            .map { ResultGroup(type: .single, members: [$0.assetID]) }
    }
}
