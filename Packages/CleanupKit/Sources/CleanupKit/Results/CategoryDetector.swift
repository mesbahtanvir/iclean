import Foundation

public enum GroupType: String, Sendable, Codable {
    case duplicatePhotos, similarShots, duplicateVideos
    /// A single flagged item (blurry, screenshot, large video).
    case single
}

public enum Confidence: String, Sendable, Codable {
    case normal
    /// Based only on a low-resolution preview (FR-014).
    case lower
}

/// A group of items, or a single flagged item, within a category.
public struct ResultGroup: Sendable, Hashable, Identifiable {
    /// Stable: derived from the sorted member IDs.
    public let id: String
    public var type: GroupType
    /// Members in display order.
    public var members: [String]
    public var keepers: Set<String>
    public var confidence: Confidence

    public init(
        type: GroupType, members: [String], keepers: Set<String> = [],
        confidence: Confidence = .normal
    ) {
        self.id = Self.stableID(type: type, members: members)
        self.type = type
        self.members = members
        self.keepers = keepers
        self.confidence = confidence
    }

    public static func stableID(type: GroupType, members: [String]) -> String {
        var hasher = StableHasher()
        hasher.combine(type.rawValue)
        members.sorted().forEach { hasher.combine($0) }
        return hasher.hex
    }

    /// Members that are candidates for removal.
    public var removable: [String] { members.filter { !keepers.contains($0) } }
}

/// Finds the items for one category. Each user story adds one.
public protocol CategoryDetector: Sendable {
    var category: CleanupCategory { get }
    /// False for categories that need only metadata (screenshots, large videos),
    /// so items that were not scanned can still be listed.
    var needsAnalysis: Bool { get }
    /// `items` contains only items not already listed in an earlier category.
    func detect(items: [LibraryItem]) -> [ResultGroup]
}

/// FNV-1a: stable across launches, unlike `Hasher`.
struct StableHasher {
    private var value: UInt64 = 0xcbf2_9ce4_8422_2325
    mutating func combine(_ string: String) {
        for byte in string.utf8 {
            value ^= UInt64(byte)
            value = value &* 0x0000_0100_0000_01b3
        }
        value ^= 0xff
    }
    var hex: String { String(value, radix: 16) }
}
