import Foundation

/// Operating-point calibration (SCAN_PIPELINE.md §7). Ships as a bundled
/// calibration.json keyed by (detectorId, visionRevision); the fixture harness
/// regenerates it per revision. An unrecognized revision at runtime DISABLES
/// the affected detector rather than running uncalibrated (§6.3).
public struct OperatingPoint: Sendable, Codable, Hashable {
    public let threshold: Double
    public let precision: Double
    public let recall: Double

    public init(threshold: Double, precision: Double, recall: Double) {
        self.threshold = threshold
        self.precision = precision
        self.recall = recall
    }
}

public struct CalibrationTable: Sendable, Codable {
    public let detectorId: String
    public let visionRevision: Int? // nil for non-Vision detectors
    /// Ordered strictest → loosest.
    public let points: [OperatingPoint]
    public let defaultIndex: Int

    public init(detectorId: String, visionRevision: Int?, points: [OperatingPoint], defaultIndex: Int) {
        self.detectorId = detectorId
        self.visionRevision = visionRevision
        self.points = points
        self.defaultIndex = defaultIndex
    }

    public func point(stepOffset: Int) -> OperatingPoint {
        let index = min(max(defaultIndex + stepOffset, 0), points.count - 1)
        return points[index]
    }
}

public struct CalibrationFile: Sendable, Codable {
    public let tables: [CalibrationTable]

    public func table(detectorId: String, visionRevision: Int?) -> CalibrationTable? {
        tables.first { $0.detectorId == detectorId && $0.visionRevision == visionRevision }
    }
}

/// Per-user adaptation state (one row per detector — SCAN_PIPELINE.md §7).
public struct UserCalibration: Sendable, Codable, Hashable {
    public var detectorId: String
    public var stepOffset: Int
    public var decisionsSinceChange: Int

    public init(detectorId: String, stepOffset: Int = 0, decisionsSinceChange: Int = 0) {
        self.detectorId = detectorId
        self.stepOffset = stepOffset
        self.decisionsSinceChange = decisionsSinceChange
    }
}

public struct DecisionSample: Sendable {
    public let accepted: Bool
    public let restoredFromStaging: Bool

    public init(accepted: Bool, restoredFromStaging: Bool = false) {
        self.accepted = accepted
        self.restoredFromStaging = restoredFromStaging
    }
}

public enum CalibrationStepper {
    public static let windowSize = 20
    public static let rejectionTightenRate = 0.30
    public static let relaxAfterDecisions = 50
    public static let relaxBelowRejectionRate = 0.10

    /// Evaluated after each decision over the trailing `windowSize` decisions
    /// for the mapped action type (SCAN_PIPELINE.md §7):
    /// - latest decision was a staging restore ⇒ +2 (tighter)
    /// - rejection > 30% over the window ⇒ +1
    /// - 50+ consecutive decisions under 10% rejection ⇒ −1 (relax)
    public static func step(
        state: UserCalibration,
        trailingDecisions: [DecisionSample]
    ) -> UserCalibration {
        var next = state
        next.decisionsSinceChange += 1

        guard !trailingDecisions.isEmpty else { return next }

        if trailingDecisions.last?.restoredFromStaging == true {
            next.stepOffset += 2
            next.decisionsSinceChange = 0
            return next
        }

        let window = trailingDecisions.suffix(windowSize)
        let rejectionRate = Double(window.filter { !$0.accepted }.count) / Double(window.count)

        if window.count >= windowSize, rejectionRate > rejectionTightenRate {
            next.stepOffset += 1
            next.decisionsSinceChange = 0
        } else if next.decisionsSinceChange >= relaxAfterDecisions,
                  rejectionRate < relaxBelowRejectionRate,
                  next.stepOffset > 0 {
            next.stepOffset -= 1
            next.decisionsSinceChange = 0
        }
        return next
    }
}
