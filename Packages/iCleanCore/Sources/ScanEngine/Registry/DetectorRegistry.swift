import Foundation

/// Static detector registry — the single source of truth for scheduling,
/// backfills, calibration mapping, reason validation, and the metric harness
/// (SCAN_PIPELINE.md §11).
public struct DetectorDescriptor: Sendable, Hashable {
    public let id: String
    public let version: Int
    public let stage: ScanStage
    public let requiredSignals: [String]
    public let templateIds: [String]
    public let actionTypes: [ActionType]

    public init(
        id: String,
        version: Int,
        stage: ScanStage,
        requiredSignals: [String],
        templateIds: [String],
        actionTypes: [ActionType]
    ) {
        self.id = id
        self.version = version
        self.stage = stage
        self.requiredSignals = requiredSignals
        self.templateIds = templateIds
        self.actionTypes = actionTypes
    }
}

public enum DetectorRegistry {
    /// MVP detector set (DESIGN.md §15). New detectors add rows here —
    /// content, never vocabulary.
    public static let all: [DetectorDescriptor] = [
        DetectorDescriptor(
            id: "exact-dupe", version: 1, stage: .s2,
            requiredSignals: ["phash", "fileSize"],
            templateIds: ["reason.dupe.identical", "reason.dupe.nearCertain"],
            actionTypes: [.exactDuplicate]
        ),
        DetectorDescriptor(
            id: "near-dupe", version: 1, stage: .s2,
            requiredSignals: ["phash", "fileSize"],
            templateIds: ["reason.dupe.nearDuplicate"],
            actionTypes: [.nearDuplicate]
        ),
        DetectorDescriptor(
            id: "original-edited-pair", version: 1, stage: .s3,
            requiredSignals: ["phash", "isEdited"],
            templateIds: ["reason.pair.originalEdited"],
            actionTypes: [.originalEditedPair]
        ),
        DetectorDescriptor(
            id: "burst-collapse", version: 1, stage: .s4,
            requiredSignals: ["burstId", "keepBestKernel"],
            templateIds: ["reason.burst.keepBest"],
            actionTypes: [.burstCollapse]
        ),
        DetectorDescriptor(
            id: "similar-keep-best", version: 1, stage: .s4,
            requiredSignals: ["featurePrint", "phash", "keepBestKernel"],
            templateIds: ["reason.similar.keepBest", "reason.similar.pickFavorite"],
            actionTypes: [.similarKeepBest]
        ),
        DetectorDescriptor(
            id: "blur", version: 1, stage: .s4, // verdict needs face presence
            requiredSignals: ["lapVar", "faceCount", "saliencyArea"],
            templateIds: ["reason.junk.blurry"],
            actionTypes: [.blurry]
        ),
        DetectorDescriptor(
            id: "dark", version: 1, stage: .s4,
            requiredSignals: ["meanLum", "bottomConcentration", "faceCount"],
            templateIds: ["reason.junk.dark"],
            actionTypes: [.darkShot]
        ),
        DetectorDescriptor(
            id: "blank", version: 1, stage: .s2,
            requiredSignals: ["pixelVar"],
            templateIds: ["reason.junk.blank"],
            actionTypes: [.blankFrame]
        ),
        DetectorDescriptor(
            id: "pocket", version: 1, stage: .s4,
            requiredSignals: ["lapVar", "meanLum", "pixelVar", "faceCount", "saliencyArea"],
            templateIds: ["reason.junk.pocket"],
            actionTypes: [.pocketShot]
        ),
        DetectorDescriptor(
            id: "corrupt", version: 1, stage: .s2,
            requiredSignals: [],
            templateIds: ["reason.junk.corrupt"],
            actionTypes: [.corruptFile]
        ),
        DetectorDescriptor(
            id: "screenshot-review", version: 1, stage: .s1,
            requiredSignals: ["subtypes"],
            templateIds: ["reason.screenshot.aged"],
            actionTypes: [.screenshotReview]
        ),
    ]

    public static func descriptor(id: String) -> DetectorDescriptor? {
        all.first { $0.id == id }
    }

    public static func descriptor(for actionType: ActionType) -> DetectorDescriptor? {
        all.first { $0.actionTypes.contains(actionType) }
    }

    public static func currentVersion(stage: ScanStage) -> Int {
        all.filter { $0.stage == stage }.map(\.version).max() ?? 1
    }
}

/// Render-time catalog: templateId → localized format string. The pipeline
/// never formats; unknown templateIds invalidate the proposal
/// (SCAN_PIPELINE.md §5-S7).
public enum ReasonCatalog {
    public static let knownTemplateIds: Set<String> = Set(
        DetectorRegistry.all.flatMap(\.templateIds)
    )

    public static func isRenderable(_ params: ReasonParams) -> Bool {
        knownTemplateIds.contains(params.key)
    }

    /// English fallback rendering (real localization lands with Localizable.strings;
    /// the CI harness renders every emitted reason through here — §13).
    public static func render(_ params: ReasonParams) -> String? {
        func int(_ name: String) -> Int64? {
            if case .int(let value)? = params.args[name] { return value }
            return nil
        }
        func str(_ name: String) -> String? {
            if case .string(let value)? = params.args[name] { return value }
            return nil
        }
        func dbl(_ name: String) -> Double? {
            if case .double(let value)? = params.args[name] { return value }
            return nil
        }

        switch params.key {
        case "reason.dupe.identical":
            return "Identical copy — byte-for-byte the same file"
        case "reason.dupe.nearCertain":
            return "Near-certain copy — same shot, same size"
        case "reason.dupe.nearDuplicate":
            guard let kept = str("keptQuality") else { return nil }
            return "Same image, lower quality — keeping the \(kept) version"
        case "reason.pair.originalEdited":
            return "Original of an edit you kept"
        case "reason.burst.keepBest":
            guard let count = int("count") else { return nil }
            return "Best of \(count) burst frames"
        case "reason.similar.keepBest":
            guard let count = int("count"), let chips = str("chips") else { return nil }
            return "Best of \(count) — \(chips)"
        case "reason.similar.pickFavorite":
            guard let count = int("count") else { return nil }
            return "These \(count) are nearly identical — pick your favorite"
        case "reason.junk.blurry":
            guard let score = dbl("sharpness") else { return nil }
            return "Blurry — sharpness \(Int(score.rounded()))/100"
        case "reason.junk.dark":
            return "Too dark to see anything"
        case "reason.junk.blank":
            return "Blank frame"
        case "reason.junk.pocket":
            return "Pocket shot — dark, blurry, no subject"
        case "reason.junk.corrupt":
            return "Unreadable file"
        case "reason.screenshot.aged":
            guard let months = int("ageMonths") else { return nil }
            return "Screenshot from \(months) months ago"
        default:
            return nil // unknown template → proposal invalidates (DESIGN.md §9.4)
        }
    }
}
