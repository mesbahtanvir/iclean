import CleanupKit

/// The detectors each user story adds, and the analyzer they need.
enum Detectors {
    static func all(_ features: ProFeatures) -> [any CategoryDetector] {
        StandardPipeline.detectors(features)
    }

    static var analyzer: Analyzer { StandardPipeline.analyzer }
}
