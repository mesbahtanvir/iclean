import Foundation

/// The two Vision requests of an analysis that only some photos need (spec 010). Everything else the
/// analyzer computes (hash, miniature, sharpness, aesthetics) is read for every photo.
public struct VisionWork: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// `FeaturePrint.compute`: read only by `SimilarShotsDetector`, for photos with a neighbour.
    public static let featurePrint = VisionWork(rawValue: 1 << 0)
    /// `FaceQuality.score`: read only by `KeeperRules.similarKeepers`, for photos that can be grouped.
    public static let faceQuality = VisionWork(rawValue: 1 << 1)

    public static let all: VisionWork = [.featurePrint, .faceQuality]
}
