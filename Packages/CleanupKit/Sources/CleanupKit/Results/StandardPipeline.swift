import Foundation

/// The analyzer and the detectors the app uses, in one place. The app, the baseline
/// library check and the host tests all take them from here, so they cannot drift apart.
public enum StandardPipeline {
    /// In category order; an item is listed in the first category that matches it. Videos are
    /// never analyzed (004 FR-004a, 016), so there is no video detector and a video only reaches
    /// Large Videos.
    ///
    /// `parallelism` is how many threads the pair comparisons may use (spec 009). It never changes
    /// what is found; the default follows the platform (every core on a Mac, one on a phone).
    ///
    /// `levels` holds how far Similar Shots and Unimportant look (spec 011); nil lists their defaults.
    public static func detectors(
        parallelism: Int = ScanProfile.current.buildParallelism, levels: ResultLevels? = nil
    ) -> [any CategoryDetector] {
        [
            DuplicatePhotoDetector(parallelism: parallelism),
            BurstDetector(),
            SimilarShotsDetector(parallelism: parallelism, levels: levels),
            BlurDetector(),
            UnimportantDetector(levels: levels),
            ScreenshotsCategory(),
            ScreenRecordingsCategory(),
            LargeVideosCategory(),
        ]
    }

    public static var analyzer: Analyzer { DefaultAnalyzer() }
}
