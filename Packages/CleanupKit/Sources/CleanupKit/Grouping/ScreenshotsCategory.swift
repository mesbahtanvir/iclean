import Foundation

/// All screenshots, newest first, all pre-selected (Story 4, FR-004a).
/// Needs only metadata, so screenshots that were not scanned are listed too.
public struct ScreenshotsCategory: CategoryDetector {
    public let category = CleanupCategory.screenshots
    public let needsAnalysis = false

    public init() {}

    public func detect(items: [LibraryItem]) -> [ResultGroup] {
        items
            .filter { $0.metadata.kind == .screenshot }
            .sorted { ($0.metadata.captureDate ?? .distantPast) > ($1.metadata.captureDate ?? .distantPast) }
            .map { ResultGroup(type: .single, members: [$0.assetID]) }
    }
}
