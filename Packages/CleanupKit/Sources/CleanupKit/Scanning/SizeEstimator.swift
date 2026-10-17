import Foundation

/// Estimates storage size when the real size cannot be read on the phone (research R7).
public enum SizeEstimator {
    public static func estimate(_ metadata: AssetMetadata) -> Int64 {
        if metadata.kind.isVideo {
            let seconds = metadata.duration ?? 0
            let bytesPerSecond: Double = max(metadata.pixelWidth, metadata.pixelHeight) > 1920
                ? 3_000_000 : 1_000_000
            return Int64(seconds * bytesPerSecond)
        }
        return Int64(Double(metadata.pixelCount) * 0.35)
    }
}
