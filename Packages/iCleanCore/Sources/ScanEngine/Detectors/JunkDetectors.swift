import Foundation
import PhotoGateway

/// Quality-failure detectors over cheap + Vision signals (DESIGN.md §4.3).
/// Pure functions: signal in, verdict out. Thresholds come from calibration
/// operating points; the values here are the shipped defaults' semantics.
public enum JunkDetectors {
    public enum BlurVerdict: Sendable, Equatable {
        case none
        /// Per-photo swipe deck (medium regret).
        case borderline
        /// Severe + no face + no saliency may enter the pre-checked batch —
        /// but only after the 1024-px no-face confirmation (SCAN_PIPELINE.md §5-S4).
        case severe
    }

    public static func blur(
        laplacianVariance: Double,
        severeBelow: Double,
        borderlineBelow: Double,
        faceCount: Int?,
        saliencyArea: Double?
    ) -> BlurVerdict {
        guard laplacianVariance < borderlineBelow else { return .none }
        let hasFace = (faceCount ?? 0) > 0
        let hasSubject = (saliencyArea ?? 0) > 0.02
        if laplacianVariance < severeBelow && !hasFace && !hasSubject {
            return .severe
        }
        return .borderline
    }

    /// Night mode, concerts, candles are dark on purpose: dark alone is weak —
    /// require the histogram concentration AND absence of a detectable subject.
    public static func isDark(
        meanLuminance: Double,
        bottomConcentration: Double,
        faceCount: Int?,
        saliencyArea: Double?
    ) -> Bool {
        meanLuminance < 24
            && bottomConcentration > 0.85
            && (faceCount ?? 0) == 0
            && (saliencyArea ?? 0) < 0.02
    }

    /// Essentially zero false positives (DESIGN.md §4.3).
    public static func isBlankFrame(pixelVariance: Double) -> Bool {
        pixelVariance < 4
    }

    /// Compound pocket-shot signal — 4+ agreeing signals reach batch confidence
    /// (DESIGN.md §4.3). Face gate is re-confirmed at 1024 px before batching.
    public static func isPocketShot(
        laplacianVariance: Double,
        meanLuminance: Double,
        pixelVariance: Double,
        faceCount: Int?,
        saliencyArea: Double?
    ) -> Bool {
        var agreeing = 0
        if meanLuminance < 32 { agreeing += 1 }
        if laplacianVariance < 12 { agreeing += 1 }
        if (faceCount ?? 0) == 0 { agreeing += 1 }
        if (saliencyArea ?? 0) < 0.01 { agreeing += 1 }
        if pixelVariance < 120 { agreeing += 1 }
        return agreeing >= 4
    }

    /// Screenshot age buckets for the review deck (DESIGN.md §4.4 — review-only
    /// in MVP; batch queue-all ships with OCR subtyping in v1.x).
    public enum ScreenshotAgeBucket: String, Sendable, Codable {
        case recent // < 30 days
        case months // 30 days – 1 year
        case old // > 1 year
    }

    public static func screenshotBucket(createdAt: Date?, now: Date) -> ScreenshotAgeBucket {
        guard let createdAt else { return .old }
        let age = now.timeIntervalSince(createdAt)
        if age < 30 * 86_400 { return .recent }
        if age < 365 * 86_400 { return .months }
        return .old
    }
}
