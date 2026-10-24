import Foundation

/// All screen recordings, newest first, none selected (spec 015, Story 3). Needs only metadata:
/// no frame is opened, so it works in the free app (004 FR-004a), and a recording that was never
/// analyzed is listed too.
public struct ScreenRecordingsCategory: CategoryDetector {
    public let category = CleanupCategory.screenRecordings
    public let needsAnalysis = false

    public init() {}

    public func detect(items: [LibraryItem]) -> [ResultGroup] {
        items
            .filter { $0.metadata.kind == .screenRecording }
            .sorted { a, b in
                (a.metadata.captureDate ?? .distantPast) > (b.metadata.captureDate ?? .distantPast)
            }
            .map { ResultGroup(type: .single, members: [$0.assetID]) }
    }
}
