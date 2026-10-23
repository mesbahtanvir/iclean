import CleanupKit

/// The detectors each user story adds, and the analyzer they need.
enum Detectors {
    static func all(_ features: ProFeatures, levels: ResultLevels? = nil) -> [any CategoryDetector] {
        StandardPipeline.detectors(features, levels: levels)
    }

    static var analyzer: Analyzer { StandardPipeline.analyzer }
}
