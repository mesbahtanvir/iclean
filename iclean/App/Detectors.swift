import CleanupKit

/// The detectors each user story adds, and the analyzer they need.
enum Detectors {
    static func all(levels: ResultLevels? = nil) -> [any CategoryDetector] {
        StandardPipeline.detectors(levels: levels)
    }

    static var analyzer: Analyzer { StandardPipeline.analyzer }
}
