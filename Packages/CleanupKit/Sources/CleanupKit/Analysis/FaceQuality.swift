import CoreGraphics
import Vision

/// Best face capture quality in an image (0…1), or nil when there are no faces or
/// Vision is unavailable. Used to pick the best of several similar shots.
public enum FaceQuality {
    public static func score(_ image: CGImage) async -> Double? {
        guard let faces = try? await DetectFaceCaptureQualityRequest().perform(on: image) else {
            return nil
        }
        return faces.compactMap { $0.captureQuality?.score }.max().map(Double.init)
    }
}
