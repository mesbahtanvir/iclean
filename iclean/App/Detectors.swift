import CleanupKit

/// The detectors each user story adds, and the analyzer they need.
enum Detectors {
    static var all: [any CategoryDetector] {
        [
            DuplicatePhotoDetector(),
            SimilarShotsDetector(),
            BlurDetector(),
            ScreenshotsCategory(),
            DuplicateVideoDetector(),
            LargeVideosCategory(),
        ]
    }

    static var analyzer: Analyzer { DefaultAnalyzer() }
}
