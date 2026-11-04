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

    /// Not Vision work but a modifier of a request: do exactly the work named and nothing more. Without
    /// it an analyzer may run the face pass for a photo that only Unimportant reads (spec 011); the photo
    /// check of a tiered scan decides that itself, later (spec 017). It is never stored: a skip record
    /// is `all` less what was done, and `all` does not contain it.
    public static let exact = VisionWork(rawValue: 1 << 2)

    public static let all: VisionWork = [.featurePrint, .faceQuality]
}
