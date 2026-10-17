import CoreGraphics
import Vision

/// Apple's on-device aesthetics score, from -1 (poor) to 1 (great). Used as the
/// second blur signal (research R5).
public enum Aesthetics {
    public static func score(_ image: CGImage) async -> Double? {
        guard let observation = try? await CalculateImageAestheticsScoresRequest().perform(on: image)
        else { return nil }
        return Double(observation.overallScore)
    }
}
