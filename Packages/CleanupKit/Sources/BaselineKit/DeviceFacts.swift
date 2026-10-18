import CleanupKit
import Foundation

/// What the baseline run says about the device it ran on, so reports from different devices
/// can be compared side by side.
public struct DeviceFacts: Codable, Sendable, Hashable {
    public var platform: String
    /// The hardware identifier, for example `iPhone18,1` or `Mac15,6`; on a simulator, the
    /// device it simulates.
    public var model: String
    public var osVersion: String
    public var isSimulator: Bool
    public var physicalMemoryMB: Int
    public var cores: Int
    public var thermalState: String
    public var lowPowerMode: Bool
    public var buildConfiguration: String

    public static func current() -> DeviceFacts {
        let env = ProcessInfo.processInfo.environment
        let model: String
        #if targetEnvironment(simulator)
            model = env["SIMULATOR_MODEL_IDENTIFIER"] ?? hardware("hw.machine")
        #elseif os(macOS)
            model = hardware("hw.model")
        #else
            model = hardware("hw.machine")
        #endif
        let platform: String
        #if os(macOS)
            platform = "macOS"
        #elseif os(visionOS)
            platform = "visionOS"
        #elseif os(tvOS)
            platform = "tvOS"
        #else
            platform = model.hasPrefix("iPad") ? "iPadOS" : "iOS"
        #endif
        #if DEBUG
            let config = "debug"
        #else
            let config = "release"
        #endif
        let info = ProcessInfo.processInfo
        return DeviceFacts(
            platform: platform, model: model, osVersion: info.operatingSystemVersionString,
            isSimulator: isSimulator, physicalMemoryMB: Int(info.physicalMemory / 1_048_576),
            cores: info.activeProcessorCount, thermalState: describe(info.thermalState),
            lowPowerMode: info.isLowPowerModeEnabled, buildConfiguration: config)
    }

    private static var isSimulator: Bool {
        #if targetEnvironment(simulator)
            true
        #else
            false
        #endif
    }

    private static func hardware(_ name: String) -> String {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var value = [CChar](repeating: 0, count: size)
        sysctlbyname(name, &value, &size, nil, 0)
        return String(cString: value)
    }

    private static func describe(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}
