import Foundation

/// Resource governors checked at every batch boundary (SCAN_PIPELINE.md §8).
/// Platform sensors (thermal state, battery, memory pressure) are injected as
/// closures by the app layer so the engine stays platform-agnostic.
public enum GovernorDecision: Sendable, Equatable {
    case proceed
    case reduceBatch // halve batch size
    case pauseHeavy // pause S4; S2 halved
    case pauseAll // everything but UI-driven prefetch
}

public struct GovernorInputs: Sendable {
    /// 0 = nominal, 1 = fair, 2 = serious, 3 = critical (mirrors ProcessInfo.ThermalState).
    public var thermalLevel: @Sendable () -> Int
    public var isLowPowerMode: @Sendable () -> Bool
    public var batteryFraction: @Sendable () -> Double // 0…1; -1 = unknown
    public var isCharging: @Sendable () -> Bool
    public var isMemoryConstrained: @Sendable () -> Bool

    public init(
        thermalLevel: @escaping @Sendable () -> Int = { 0 },
        isLowPowerMode: @escaping @Sendable () -> Bool = { false },
        batteryFraction: @escaping @Sendable () -> Double = { -1 },
        isCharging: @escaping @Sendable () -> Bool = { true },
        isMemoryConstrained: @escaping @Sendable () -> Bool = { false }
    ) {
        self.thermalLevel = thermalLevel
        self.isLowPowerMode = isLowPowerMode
        self.batteryFraction = batteryFraction
        self.isCharging = isCharging
        self.isMemoryConstrained = isMemoryConstrained
    }
}

public struct Governor: Sendable {
    private let inputs: GovernorInputs

    public init(inputs: GovernorInputs) {
        self.inputs = inputs
    }

    public func decision() -> GovernorDecision {
        let thermal = inputs.thermalLevel()
        if thermal >= 3 { return .pauseAll } // critical
        if thermal >= 2 { return .pauseHeavy } // serious → pause S4
        let battery = inputs.batteryFraction()
        if inputs.isLowPowerMode() || (battery >= 0 && battery < 0.2 && !inputs.isCharging()) {
            return .pauseHeavy
        }
        if inputs.isMemoryConstrained() { return .reduceBatch }
        return .proceed
    }
}
