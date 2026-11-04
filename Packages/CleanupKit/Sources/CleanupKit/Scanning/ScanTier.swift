import Foundation

/// How much of a photo a kind of cleanup has to read (spec 017). Tiers run in order, cheapest first.
/// The results of one can be reviewed and removed as soon as it is done, and the next starts by itself
/// unless the device or the person says otherwise.
public enum ScanTier: Int, Sendable, Codable, CaseIterable, Comparable {
    /// Library information only: no photo is opened. Screenshots, screen recordings, large videos and
    /// bursts.
    case instant = 0
    /// One preview of each photo and cheap arithmetic on it (hash, miniature, sharpness): duplicates
    /// and blurry photos.
    case photos = 1
    /// Vision on the same preview (feature print, face quality): similar shots, unimportant photos,
    /// and the better keeper of a burst.
    case deep = 2

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The categories this tier completes, in category order.
    public var categories: [CleanupCategory] {
        CleanupCategory.allCases.filter { $0.tier == self }
    }
}

extension CleanupCategory {
    /// The tier that completes this category (spec 017). The one place this is written down.
    public var tier: ScanTier {
        switch self {
        case .bursts, .screenshots, .screenRecordings, .largeVideos, .livePhotos: .instant
        case .duplicates, .blurry, .dark: .photos
        case .similar, .unimportant: .deep
        }
    }
}

/// Why the deep tier does not start by itself (spec 017 FR-010). The person can always start it.
public enum DeepWait: String, Sendable, Codable {
    /// Low Power Mode is on: the Neural Engine work is the part a low-power phone should not start alone.
    case lowPowerMode
}

/// What one tier is doing, in the words a screen needs (spec 017 FR-013).
public enum TierState: Sendable, Hashable {
    /// Not started; it starts by itself when the tier before it is done.
    case waiting
    /// Running: `done` of `total` items of this tier's job.
    case running(done: Int, total: Int)
    /// Finished.
    case ready
    /// Not running, and it will not start by itself, for this reason.
    case waitingFor(DeepWait)
    /// Not run, with this many photos still owed it. The person can start it.
    case notRun(owed: Int)

    public var isFinished: Bool { self == .ready }
}

/// One state per tier, derived from a scan's progress and nothing else, so every screen describes the
/// tiers the same way (spec 017 FR-013).
public struct ScanTierStatus: Sendable, Hashable {
    public var instant: TierState
    public var photos: TierState
    public var deep: TierState

    public init(instant: TierState, photos: TierState, deep: TierState) {
        self.instant = instant
        self.photos = photos
        self.deep = deep
    }

    public subscript(tier: ScanTier) -> TierState {
        switch tier {
        case .instant: instant
        case .photos: photos
        case .deep: deep
        }
    }

    /// The tiers of a scan that is running or has just ended. Nil when the progress is not that of a
    /// tiered scan (a one-pass job, a scan that has not started), and a screen then shows the one bar.
    ///
    /// Quick wins are ready as soon as any job reports: the plan stores them before the first event.
    public init?(_ p: ScanProgress) {
        guard let tier = p.tier, p.state != .idle else { return nil }
        let ended = p.state == .completed || p.state == .stopped
        let job = TierState.running(done: p.processed, total: p.total)
        switch tier {
        case .instant:
            return nil
        case .photos:
            if !ended {
                self.init(
                    instant: .ready, photos: job,
                    deep: p.deepWait.map(TierState.waitingFor) ?? .waiting)
            } else if p.state == .completed {
                self.init(instant: .ready, photos: .ready, deep: Self.afterPhotos(p))
            } else {
                self.init(
                    instant: .ready, photos: .notRun(owed: max(0, p.total - p.processed)),
                    deep: .waiting)
            }
        case .deep:
            let deep: TierState
            if !ended {
                deep = job
            } else {
                deep = p.state == .completed ? .ready : .notRun(owed: p.deepRemaining)
            }
            self.init(instant: .ready, photos: .ready, deep: deep)
        }
    }

    /// The deep tier after a photos job that ran to the end and did not start the deep job.
    private static func afterPhotos(_ p: ScanProgress) -> TierState {
        if p.deepRemaining == 0 { return .ready }
        return p.deepWait.map(TierState.waitingFor) ?? .notRun(owed: p.deepRemaining)
    }
}
