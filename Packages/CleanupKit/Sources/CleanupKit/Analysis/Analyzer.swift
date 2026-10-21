import CoreGraphics
import Foundation

/// Analyzes one preview image. Pure: no library or storage access.
public protocol Analyzer: Sendable {
    func analyze(_ image: CGImage, metadata: AssetMetadata) async throws -> Analysis
}

public struct DefaultAnalyzer: Analyzer {
    /// How far above the blur threshold a photo still gets an aesthetics score.
    static let aestheticsMargin = 0.05

    public init() {}

    public func analyze(_ image: CGImage, metadata: AssetMetadata) async throws -> Analysis {
        let hash = dHash(image)
        // Vision can be unavailable (for example on some simulators). Similarity is then
        // skipped, but hashing, thumbprints and sharpness still work.
        let print: Data
        do {
            print = try await FeaturePrint.compute(image)
        } catch {
            Log.scan.error("Feature print failed: \(error.localizedDescription, privacy: .public)")
            print = Data()
        }
        let sharpness = Sharpness.score(image)
        // Aesthetics is the second blur signal and nothing else reads it. `BlurDetector` asks for it
        // only for a still, not portrait or long-exposure photo whose sharpness is already below
        // the blur threshold, so the Vision request is skipped for every other photo (a margin
        // keeps small threshold changes safe). It was 3 of the 13 ms a photo cost.
        let isPhoto = metadata.kind == .photo || metadata.kind == .livePhoto
        let mayBeBlurry =
            isPhoto && !metadata.isPortrait && !metadata.isLongExposure
            && sharpness < BlurThresholds.sharpness + Self.aestheticsMargin
        let aesthetics = mayBeBlurry ? await Aesthetics.score(image) : nil
        let faces = isPhoto ? await FaceQuality.score(image) : nil
        return Analysis(
            dHash: hash, thumbprint: Thumbprint.compute(image), featurePrint: print,
            sharpness: sharpness, aestheticsScore: aesthetics, faceQuality: faces)
    }
}
