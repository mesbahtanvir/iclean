import Foundation
import PhotoGateway

/// Time/place sessionization (SCAN_PIPELINE.md §6.1). Sessions are the unit of
/// similarity clustering, dirty-marking, and Vision scheduling.
public enum Sessionizer {
    public static let gapSeconds: TimeInterval = 600 // 10 min
    public static let softSplitSize = 300

    public struct Input: Sendable, Hashable {
        public let id: String
        public let date: Date? // nil createdAt falls back to modifiedAt upstream; nil here = undated
        public let bucket: LocationBucket?

        public init(id: String, date: Date?, bucket: LocationBucket?) {
            self.id = id
            self.date = date
            self.bucket = bucket
        }
    }

    public struct SessionDraft: Sendable, Equatable {
        public let memberIds: [String]
        public let startAt: Date?
        public let endAt: Date?
        public let isUndated: Bool
    }

    /// Splits on gap > 10 min or location Chebyshev distance > 1 between
    /// consecutive assets; hasLocation == false inherits the running bucket and
    /// never triggers a jump. Undated assets form one excluded session.
    /// Giant sessions soft-split at 300 members on the largest internal gaps.
    public static func sessionize(_ inputs: [Input]) -> [SessionDraft] {
        var dated = inputs.filter { $0.date != nil }
        let undated = inputs.filter { $0.date == nil }

        // Sort by (date, id) — the id tiebreak makes shuffled input deterministic.
        dated.sort {
            let l = $0.date ?? .distantPast
            let r = $1.date ?? .distantPast
            return l == r ? $0.id < $1.id : l < r
        }

        var sessions: [[Input]] = []
        var current: [Input] = []
        var runningBucket: LocationBucket?

        for input in dated {
            if let last = current.last {
                let gap = input.date!.timeIntervalSince(last.date!)
                var jumped = false
                if let bucket = input.bucket, let running = runningBucket {
                    jumped = bucket.chebyshev(to: running) > 1
                }
                if gap > gapSeconds || jumped {
                    sessions.append(current)
                    current = []
                    runningBucket = nil
                }
            }
            current.append(input)
            if let bucket = input.bucket { runningBucket = bucket }
        }
        if !current.isEmpty { sessions.append(current) }

        // Soft-split oversized sessions on their largest internal gaps.
        var drafts: [SessionDraft] = []
        for session in sessions {
            for piece in softSplit(session) {
                drafts.append(
                    SessionDraft(
                        memberIds: piece.map(\.id),
                        startAt: piece.first?.date,
                        endAt: piece.last?.date,
                        isUndated: false
                    )
                )
            }
        }
        if !undated.isEmpty {
            drafts.append(
                SessionDraft(
                    memberIds: undated.map(\.id).sorted(),
                    startAt: nil,
                    endAt: nil,
                    isUndated: true // excluded from similarity clustering
                )
            )
        }
        return drafts
    }

    private static func softSplit(_ session: [Input]) -> [[Input]] {
        guard session.count > softSplitSize else { return [session] }

        // Split at the single largest internal gap, then recurse.
        var bestIndex = session.count / 2
        var bestGap: TimeInterval = -1
        for index in 1..<session.count {
            let gap = session[index].date!.timeIntervalSince(session[index - 1].date!)
            if gap > bestGap {
                bestGap = gap
                bestIndex = index
            }
        }
        let left = Array(session[..<bestIndex])
        let right = Array(session[bestIndex...])
        return softSplit(left) + softSplit(right)
    }

    /// The incremental re-segmentation window: [start of previous session,
    /// end of next session] around a mutated asset (SCAN_PIPELINE.md §6.1).
    /// Callers fetch that slice, re-run `sessionize`, and diff.
    public static func resegmentationWindow(
        around date: Date,
        sessionSpans: [(startAt: Date, endAt: Date)]
    ) -> (from: Date, to: Date) {
        let sorted = sessionSpans.sorted { $0.startAt < $1.startAt }
        var from = date
        var to = date
        for (index, span) in sorted.enumerated() {
            if date >= span.startAt && date <= span.endAt {
                from = index > 0 ? sorted[index - 1].startAt : span.startAt
                to = index + 1 < sorted.count ? sorted[index + 1].endAt : span.endAt
                return (from, to)
            }
            if date < span.startAt {
                from = index > 0 ? sorted[index - 1].startAt : date
                to = span.endAt
                return (from, to)
            }
        }
        if let last = sorted.last {
            from = last.startAt
        }
        return (from, to)
    }
}
