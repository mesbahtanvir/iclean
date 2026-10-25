import Foundation

/// Which items to suggest keeping in a group (FR-008).
public enum KeeperRules {
    /// Duplicates: every favorite; otherwise one copy, chosen in this order:
    ///
    /// 1. a copy whose date can be right beats one whose date cannot (none, a default such as
    ///    1970 or 2001, the future);
    /// 2. the highest resolution;
    /// 3. among those, a copy dated more than a year later than the earliest of them loses: a
    ///    copy is made after the photo, so the much later date is the date of the copy;
    /// 4. the copy whose date and details are more likely to be the real ones: a date that is
    ///    only the moment of saving, a bulk-import stamp or a bare midnight counts against a
    ///    copy, and so does a missing location when another copy has one (see `DateCredibility`);
    /// 5. among copies that tie so far, one dated more than an hour later than the earliest of
    ///    them loses;
    /// 6. the best file quality (largest file);
    /// 7. the oldest, then the identifier.
    ///
    /// `context` carries library-wide facts (how many photos share a timestamp); without it only
    /// facts inside the group are used.
    public static func duplicateKeepers(_ items: [LibraryItem], context: DateContext = .empty)
        -> Set<String>
    {
        let favorites = items.filter { $0.metadata.isFavorite }
        if !favorites.isEmpty { return Set(favorites.map(\.assetID)) }
        let assessments = DateCredibility.assess(items, context: context)
        let ranks = DuplicateRank.ranks(items, assessments)
        guard let best = ranks.min(by: { $0.rank < $1.rank }) else { return [] }
        return [best.id]
    }

    /// What to tell the person about the dates of a group of copies, by asset id. Empty when
    /// nothing separates the copies: every copy has the same reasons, or none has any.
    public static func dateNotes(_ items: [LibraryItem], context: DateContext = .empty)
        -> [String: [DateReason]]
    {
        guard items.count > 1 else { return [:] }
        let assessments = DateCredibility.assess(items, context: context)
        let distinct = Set(
            assessments.values.map { $0.reasons.sorted { $0.rawValue < $1.rawValue } })
        guard distinct.count > 1 else { return [:] }
        return assessments.compactMapValues { $0.reasons.isEmpty ? nil : $0.reasons }
    }

    /// Sort key for choosing a duplicate keeper; the smallest is the best. The two "later than the
    /// earliest" fields are worked out once for the whole group (see `ranks`), so the order is a
    /// plain total order and the same on every run, whatever order the copies come in.
    struct DuplicateRank: Comparable {
        var impossibleDate: Bool
        var pixels: Int
        /// More than a year later than the earliest believable date of the best copies.
        var farFromEarliest: Bool
        var softPenalty: Int
        /// More than an hour later than the earliest date of the copies that tie so far.
        var laterThanTied: Bool
        var bytes: Int64
        var date: Date
        var id: String

        static func ranks(_ items: [LibraryItem], _ assessments: [String: DateAssessment])
            -> [(id: String, rank: DuplicateRank)]
        {
            struct Facts {
                var item: LibraryItem
                var impossible: Bool
                var pixels: Int
                var soft: Int
                var date: Date?
            }
            let facts = items.map { item in
                let a = assessments[item.assetID]
                let date = item.metadata.captureDate
                return Facts(
                    item: item, impossible: a?.isImpossible ?? (date == nil),
                    pixels: item.metadata.pixelCount, soft: a?.softPenalty ?? 0, date: date)
            }
            // The best copies: a possible date and the most pixels.
            let possible = facts.filter { !$0.impossible }
            let bestPixels = possible.map(\.pixels).max()
            let earliestBest = possible.filter { $0.pixels == bestPixels }.compactMap(\.date).min()
            // The earliest date inside each set of copies that tie on the earlier keys.
            struct Tie: Hashable {
                var impossible: Bool
                var pixels: Int
                var far: Bool
                var soft: Int
            }
            func isFar(_ f: Facts) -> Bool {
                guard !f.impossible, f.pixels == bestPixels, let earliest = earliestBest,
                    let date = f.date
                else { return false }
                return date.timeIntervalSince(earliest) > DateThresholds.farFromEarliest
            }
            var earliestInTie: [Tie: Date] = [:]
            for f in facts {
                guard let date = f.date else { continue }
                let tie = Tie(
                    impossible: f.impossible, pixels: f.pixels, far: isFar(f), soft: f.soft)
                earliestInTie[tie] = min(earliestInTie[tie] ?? date, date)
            }
            return facts.map { f in
                let far = isFar(f)
                let tie = Tie(impossible: f.impossible, pixels: f.pixels, far: far, soft: f.soft)
                // Impossible dates are not compared with each other: file size decides among them.
                let later =
                    f.impossible
                    ? false
                    : f.date.flatMap { date in
                        earliestInTie[tie].map {
                            date.timeIntervalSince($0) > DateThresholds.sameMoment
                        }
                    } ?? false
                let rank = DuplicateRank(
                    impossibleDate: f.impossible, pixels: f.pixels, farFromEarliest: far,
                    softPenalty: f.soft, laterThanTied: later, bytes: f.item.effectiveByteSize,
                    date: f.date ?? .distantFuture, id: f.item.assetID)
                return (f.item.assetID, rank)
            }
        }

        static func < (a: Self, b: Self) -> Bool {
            if a.impossibleDate != b.impossibleDate { return !a.impossibleDate }
            if a.pixels != b.pixels { return a.pixels > b.pixels }
            if a.farFromEarliest != b.farFromEarliest { return !a.farFromEarliest }
            if a.softPenalty != b.softPenalty { return a.softPenalty < b.softPenalty }
            if a.laterThanTied != b.laterThanTied { return !a.laterThanTied }
            if a.bytes != b.bytes { return a.bytes > b.bytes }
            if a.date != b.date { return a.date < b.date }
            return a.id < b.id
        }
    }

    /// Similar shots: every favorite; otherwise the sharpest, with face capture
    /// quality breaking near-ties (sharpness within 0.02).
    public static func similarKeepers(_ items: [LibraryItem]) -> Set<String> {
        let favorites = items.filter { $0.metadata.isFavorite }
        if !favorites.isEmpty { return Set(favorites.map(\.assetID)) }
        guard let best = items.min(by: similarOrder) else { return [] }
        return [best.assetID]
    }

    /// Bursts (spec 015 FR-002): every frame the person picked in Photos; else every favourite;
    /// else, when some frame has a face, the sharpest among the frames whose face quality is within
    /// 0.02 of the best; else the sharpest; else, when no frame was analyzed, the frame Photos
    /// shows; else the first by capture order. Kept frames are added by the builder, as everywhere.
    public static func burstKeepers(_ frames: [LibraryItem]) -> Set<String> {
        let picked = frames.filter { $0.metadata.burstPick == .userPick }
        if !picked.isEmpty { return Set(picked.map(\.assetID)) }
        let favorites = frames.filter { $0.metadata.isFavorite }
        if !favorites.isEmpty { return Set(favorites.map(\.assetID)) }
        let analyzed = frames.filter { $0.analysis != nil }
        if !analyzed.isEmpty {
            let faced = analyzed.filter { $0.analysis?.faceQuality != nil }
            if let bestFace = faced.compactMap({ $0.analysis?.faceQuality }).max() {
                let near = faced.filter { ($0.analysis?.faceQuality ?? -1) >= bestFace - 0.02 }
                if let best = near.min(by: sharpestOrder) { return [best.assetID] }
            }
            if let best = analyzed.min(by: sharpestOrder) { return [best.assetID] }
        }
        if let shown = frames.first(where: { $0.metadata.representsBurst }) {
            return [shown.assetID]
        }
        return ordered(frames, keepers: []).first.map { [$0] } ?? []
    }

    /// Sharpest first; the identifier breaks ties.
    static func sharpestOrder(_ a: LibraryItem, _ b: LibraryItem) -> Bool {
        let sa = a.analysis?.sharpness ?? 0
        let sb = b.analysis?.sharpness ?? 0
        return sa != sb ? sa > sb : a.assetID < b.assetID
    }

    static func similarOrder(_ a: LibraryItem, _ b: LibraryItem) -> Bool {
        let sa = a.analysis?.sharpness ?? 0
        let sb = b.analysis?.sharpness ?? 0
        if abs(sa - sb) > 0.02 { return sa > sb }
        let fa = a.analysis?.faceQuality ?? -1
        let fb = b.analysis?.faceQuality ?? -1
        if fa != fb { return fa > fb }
        if sa != sb { return sa > sb }
        return a.assetID < b.assetID
    }

    /// Display order for a group: keepers first, then the rest by date.
    static func ordered(_ items: [LibraryItem], keepers: Set<String>) -> [String] {
        items.sorted { a, b in
            let ka = keepers.contains(a.assetID)
            let kb = keepers.contains(b.assetID)
            if ka != kb { return ka }
            let da = a.metadata.captureDate ?? .distantFuture
            let db = b.metadata.captureDate ?? .distantFuture
            return da == db ? a.assetID < b.assetID : da < db
        }.map(\.assetID)
    }
}
