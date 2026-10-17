import Foundation

/// Thresholds for blur detection (research R5). Strict on purpose: only obviously
/// blurry photos are flagged (FR-003).
public enum BlurThresholds {
    /// Sharpness (0…1, see `Sharpness`). Sharp photos measure ≥ 0.70, soft ones
    /// 0.63–0.68, clearly blurry ones ≤ 0.52.
    public static let sharpness = 0.55
    /// Vision aesthetics score (-1…1). Used only when available.
    public static let aesthetics = 0.0
}

/// Flags obviously blurry photos, blurriest first (Story 2).
public struct BlurDetector: CategoryDetector {
    public let category = CleanupCategory.blurry
    public let needsAnalysis = true

    public init() {}

    public func detect(items: [LibraryItem]) -> [ResultGroup] {
        items
            .filter(isBlurry)
            .sorted { ($0.analysis?.sharpness ?? 0) < ($1.analysis?.sharpness ?? 0) }
            .map { item in
                ResultGroup(
                    type: .single, members: [item.assetID],
                    confidence: item.analysisSource == .cloudPreview ? .lower : .normal)
            }
    }

    func isBlurry(_ item: LibraryItem) -> Bool {
        let m = item.metadata
        // Screenshots and videos are never "blurry photos"; portrait and long-exposure
        // shots are blurry on purpose (FR-003a).
        guard m.kind == .photo || m.kind == .livePhoto, !m.isPortrait, !m.isLongExposure,
            let analysis = item.analysis
        else { return false }
        guard analysis.sharpness < BlurThresholds.sharpness else { return false }
        if let aesthetics = analysis.aestheticsScore {
            return aesthetics < BlurThresholds.aesthetics
        }
        return true
    }
}
