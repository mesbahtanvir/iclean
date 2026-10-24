import Foundation

/// The analyzer and the detectors the app uses, in one place. The app, the baseline
/// library check and the host tests all take them from here, so they cannot drift apart.
public enum StandardPipeline {
    /// In category order; an item is listed in the first category that matches it. Video
    /// analysis is a Pro feature: the free app has no Duplicate Videos detector, so videos
    /// only reach Large Videos.
    ///
    /// `parallelism` is how many threads the pair comparisons may use (spec 009). It never changes
    /// what is found; the default follows the platform (every core on a Mac, one on a phone).
    ///
    /// `levels` holds how far Similar Shots and Unimportant look (spec 011); nil lists their defaults.
    public static func detectors(
        _ features: ProFeatures = .free, parallelism: Int = ScanProfile.current.buildParallelism,
        levels: ResultLevels? = nil
    ) -> [any CategoryDetector] {
        var all: [any CategoryDetector] = [
            DuplicatePhotoDetector(parallelism: parallelism),
            BurstDetector(),
            SimilarShotsDetector(parallelism: parallelism, levels: levels),
            BlurDetector(),
            UnimportantDetector(levels: levels),
            ScreenshotsCategory(),
            ScreenRecordingsCategory(),
        ]
        if features.videoAnalysis { all.append(DuplicateVideoDetector(parallelism: parallelism)) }
        all.append(LargeVideosCategory())
        return all
    }

    public static var analyzer: Analyzer { DefaultAnalyzer() }
}
