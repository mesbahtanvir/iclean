import CoreGraphics
import Foundation

/// Analyzes one preview image. Pure: no library or storage access.
public protocol Analyzer: Sendable {
    func analyze(_ image: CGImage, metadata: AssetMetadata) async throws -> Analysis
}

public struct DefaultAnalyzer: Analyzer {
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
        // Aesthetics only matters for still photos that could be flagged as blurry.
        let isPhoto = metadata.kind == .photo || metadata.kind == .livePhoto
        let aesthetics = isPhoto ? await Aesthetics.score(image) : nil
        let faces = isPhoto ? await FaceQuality.score(image) : nil
        return Analysis(
            dHash: hash, thumbprint: Thumbprint.compute(image), featurePrint: print,
            sharpness: sharpness, aestheticsScore: aesthetics, faceQuality: faces)
    }
}
