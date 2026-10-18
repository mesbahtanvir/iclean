import Foundation

/// What the Pro version unlocks. The free app runs with `.free`.
///
/// This is only a switch: nothing here knows about purchases. The app decides which value to
/// hand to the scan and the results builder, so the unlock can be wired in one place later.
public struct ProFeatures: Sendable, Equatable {
    /// Analyze videos and group copies of the same video (the Duplicate Videos category).
    /// Free: videos are never analyzed; Large Videos still lists them by file size.
    public var videoAnalysis: Bool

    public init(videoAnalysis: Bool = false) {
        self.videoAnalysis = videoAnalysis
    }

    public static let free = ProFeatures()
    public static let pro = ProFeatures(videoAnalysis: true)
}
