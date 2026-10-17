import Foundation
import PhotoGateway

// MARK: - Stages & scan state (SCAN_PIPELINE.md §4, §11)

public enum ScanStage: String, Sendable, Codable, CaseIterable {
    case s1 // metadata
    case s2 // thumbnail + cheap math
    case s3 // resource introspection
    case s4 // Vision passes
    case face1024 // confirming face pass (detector-specific, created on demand)
}

public enum StageStatus: Int, Sendable, Codable {
    case pending = 0
    case done = 1
    case failed = 2
    case needsConnection = 3
}

// MARK: - Decision units & action types (DESIGN.md §4, §6)

public enum DecisionUnit: String, Sendable, Codable {
    case photo
    case cluster
    case batch
    case rule
}

/// MVP action types (DESIGN.md §15). v1.x families extend this enum.
public enum ActionType: String, Sendable, Codable, CaseIterable {
    case exactDuplicate
    case nearDuplicate
    case originalEditedPair
    case burstCollapse
    case similarKeepBest
    case blurry
    case darkShot
    case blankFrame
    case pocketShot
    case corruptFile
    case screenshotReview

    /// Deck family for pile tiles and deck filtering (DESIGN.md §6).
    public var family: Family {
        switch self {
        case .exactDuplicate, .nearDuplicate, .originalEditedPair: return .duplicates
        case .burstCollapse, .similarKeepBest: return .similar
        case .blurry, .darkShot, .blankFrame, .pocketShot, .corruptFile: return .junk
        case .screenshotReview: return .screenshots
        }
    }

    /// Tier-3 / §5.7 trap categories are permanently capped — the confidence
    /// ladder can never promote them to batch (DESIGN.md Decision Log #11).
    public var maxUnit: DecisionUnit {
        switch self {
        case .similarKeepBest, .screenshotReview: return .cluster // screenshots review-only in MVP
        case .blurry, .darkShot: return .photo
        default: return .batch
        }
    }
}

public enum Family: String, Sendable, Codable, CaseIterable {
    case duplicates
    case similar
    case junk
    case screenshots
}

// MARK: - Signals (wide row — SCAN_PIPELINE.md §4)

public struct AssetSignals: Sendable, Codable, Hashable {
    public var assetId: String
    public var phash: UInt64?
    public var dhash: UInt64?
    public var laplacianVariance: Double?
    public var meanLuminance: Double?
    public var luminanceBottomConcentration: Double?
    public var pixelVariance: Double?
    public var cornerBlobSuspect: Bool?
    public var faceCount: Int?
    public var bestFaceQuality: Double?
    public var eyesOpenMin: Double?
    public var saliencyArea: Double?
    public var noFacesConfirmedAt1024: Bool?

    public init(assetId: String) {
        self.assetId = assetId
    }
}

// MARK: - Reason params (SCAN_PIPELINE.md §5-S7 contract)

public enum ReasonValue: Sendable, Codable, Hashable {
    case int(Int64)
    case double(Double)
    case string(String)

    private enum CodingKeys: String, CodingKey { case t, v }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .t) {
        case "i": self = .int(try container.decode(Int64.self, forKey: .v))
        case "d": self = .double(try container.decode(Double.self, forKey: .v))
        default: self = .string(try container.decode(String.self, forKey: .v))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .int(let value):
            try container.encode("i", forKey: .t)
            try container.encode(value, forKey: .v)
        case .double(let value):
            try container.encode("d", forKey: .t)
            try container.encode(value, forKey: .v)
        case .string(let value):
            try container.encode("s", forKey: .t)
            try container.encode(value, forKey: .v)
        }
    }
}

/// `{"key": templateId, "v": 1, "args": {...}}` — raw values only; formatting
/// and localization happen at render time via ReasonCatalog. An unknown
/// templateId at render time invalidates the proposal (DESIGN.md §9.4).
public struct ReasonParams: Sendable, Codable, Hashable {
    public let key: String
    public let v: Int
    public let args: [String: ReasonValue]

    public init(key: String, v: Int = 1, args: [String: ReasonValue] = [:]) {
        self.key = key
        self.v = v
        self.args = args
    }
}

// MARK: - Proposal drafts (S7 output)

public struct ProposalDraft: Sendable, Hashable {
    public let actionType: ActionType
    public let unit: DecisionUnit
    public let memberIds: [String] // deletion candidates (keeper excluded)
    public let keeperId: String?
    public let reason: ReasonParams
    public let regretTier: Int // DESIGN.md §9.1 tiers 0-3
    public let confidence: Double
    public let estBytes: Int64
    public let humility: Bool // kernel couldn't crown a keeper (SCAN_PIPELINE.md §7)

    public init(
        actionType: ActionType,
        unit: DecisionUnit,
        memberIds: [String],
        keeperId: String?,
        reason: ReasonParams,
        regretTier: Int,
        confidence: Double,
        estBytes: Int64,
        humility: Bool = false
    ) {
        self.actionType = actionType
        self.unit = unit
        self.memberIds = memberIds
        self.keeperId = keeperId
        self.reason = reason
        self.regretTier = regretTier
        self.confidence = confidence
        self.estBytes = estBytes
        self.humility = humility
    }

    /// Deterministic identity: unchanged regenerations upsert onto the same row
    /// (SCAN_PIPELINE.md §5-S7). FNV-1a 128-bit over the canonical string —
    /// collision-resistant enough for a per-library keyspace, dependency-free.
    public var dedupeKey: String {
        var canonical = actionType.rawValue
        canonical += "|"
        canonical += memberIds.sorted().joined(separator: ",")
        canonical += "|"
        canonical += keeperId ?? "-"
        return FNV.hash128Hex(canonical)
    }
}

/// FNV-1a in two independent 64-bit lanes (different offset bases) — a cheap,
/// dependency-free 128-bit fingerprint.
public enum FNV {
    public static func hash64(_ string: String, offset: UInt64 = 0xcbf29ce484222325) -> UInt64 {
        var hash = offset
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }

    public static func hash128Hex(_ string: String) -> String {
        let a = hash64(string)
        let b = hash64(string, offset: 0x84222325cbf29ce4)
        return String(format: "%016llx%016llx", a, b)
    }
}
