import Foundation

/// The analyzer and the detectors the app uses, in one place. The app, the baseline
/// library check and the host tests all take them from here, so they cannot drift apart.
public enum StandardPipeline {
    /// In category order; an item is listed in the first category that matches it. Video
    /// analysis is a Pro feature: the free app has no Duplicate Videos detector, so videos
    /// only reach Large Videos.
    public static func detectors(_ features: ProFeatures = .free) -> [any CategoryDetector] {
        var all: [any CategoryDetector] = [
            DuplicatePhotoDetector(),
            SimilarShotsDetector(),
            BlurDetector(),
            ScreenshotsCategory(),
        ]
        if features.videoAnalysis { all.append(DuplicateVideoDetector()) }
        all.append(LargeVideosCategory())
        return all
    }

    public static var analyzer: Analyzer { DefaultAnalyzer() }
}
