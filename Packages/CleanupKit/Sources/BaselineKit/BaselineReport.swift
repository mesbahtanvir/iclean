import Foundation

public enum BaselineStatus: String, Codable, Sendable {
    case pass, fail, skipped
}

/// One checked statement about the run.
public struct BaselineCheck: Codable, Sendable, Hashable {
    public var id: String
    public var title: String
    public var status: BaselineStatus
    /// A short explanation, with the offending assets when it failed.
    public var detail: String

    public init(_ id: String, _ title: String, _ status: BaselineStatus, _ detail: String = "") {
        self.id = id
        self.title = title
        self.status = status
        self.detail = detail
    }
}

/// The outcome of one baseline run on one device. Everything is plain data, so reports
/// from different devices can be compared line by line.
public struct BaselineReport: Codable, Sendable {
    public var schema = 1
    public var fixtureVersion: Int
    public var fixtureName: String
    public var startedAt: Date
    public var device: DeviceFacts
    /// What this device could do, which explains skipped or degraded checks.
    public var capabilities: [String: String]
    public var timings: [String: Double]
    public var counts: [String: Int]
    public var metrics: [String: Double]
    public var checks: [BaselineCheck]

    public var failed: [BaselineCheck] { checks.filter { $0.status == .fail } }
    public var passed: Bool { failed.isEmpty }

    /// One line per check, then the verdict.
    public func summary() -> String {
        var lines: [String] = []
        for c in checks {
            let mark = c.status == .pass ? "PASS " : c.status == .fail ? "FAIL " : "SKIP "
            lines.append("\(mark)\(c.id) — \(c.title)" + (c.detail.isEmpty ? "" : " (\(c.detail))"))
        }
        let ran = checks.filter { $0.status != .skipped }.count
        let ok = checks.filter { $0.status == .pass }.count
        let speed = timings["itemsPerSecond"].map { String(format: "%.1f items/s", $0) } ?? "n/a"
        lines.append(
            "BASELINE \(passed ? "PASS" : "FAIL") \(ok)/\(ran) checks | \(device.platform) "
                + "\(device.model) \(device.osVersion)\(device.isSimulator ? " (simulator)" : "") | \(speed)")
        return lines.joined(separator: "\n")
    }

    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}
