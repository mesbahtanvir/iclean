import Foundation

/// What a scan has to do, computed from the library and the store (pure, 003 plan).
struct ScanPlan: Sendable {
    /// Stored items no longer in the library.
    var gone: Set<String>
    /// Stored items whose metadata changed without needing re-analysis. Only the metadata is
    /// written back; the analysis stays (spec 008: no fingerprint is read to plan a scan).
    var refreshed: [AssetMetadata]
    /// Items to analyze, newest first.
    var toAnalyze: [AssetMetadata]
    /// Items that need no analysis to be listed: screenshots and videos. They are
    /// stored at once, so Screenshots and Large Videos can be reviewed before any photo is opened
    /// (spec 008, quick wins). They stay in `toAnalyze`, so counts and chunks are unchanged.
    var quickWins: [AssetMetadata]
    /// Stored photos analyzed without some Vision work that the library now demands, because a
    /// neighbour arrived, a date or burst changed (spec 010). They are in `toAnalyze` as well.
    var repairs: [AssetMetadata] = []
    /// The Vision work to leave out, by asset id, for the items in `toAnalyze` that skip any. Empty when
    /// the plan does not defer (spec 010).
    var skipVision: [String: VisionWork] = [:]
    /// Burst frames to store from their metadata before any photo is opened, so Bursts can be reviewed
    /// at once (spec 017 FR-003). Only a photo check plans any. They stay in `toAnalyze`.
    var listedEarly: [AssetMetadata] = []
    /// Photos that will still be owed Vision work once this plan has run (spec 017): the size of the
    /// deep tier, as far as the library and what is stored can tell. Empty for a plan that does not
    /// tier.
    var deepOwed: Set<String> = []
}

/// Which part of the work a plan is for (spec 017).
enum PlanScope: Sendable, Equatable {
    /// Everything in one pass, each photo given the Vision work the library demands for it: every
    /// scan of specs 008 to 016.
    case all
    /// The quick check of a tiered scan. Like `all` for new and changed photos, but a stored photo that
    /// is owed Vision work is analyzed only if it changed, or lies within the similar-shots window of
    /// something that did. The rest of what is owed is the deep tier's, which the person starts
    /// (spec 017 FR-011, 001 FR-005a).
    case changes
    /// The photo check: new and changed photos with no Vision work at all, and no repairs.
    case photos
    /// The deep check: the Vision work still owed, wherever it is, and any new or changed photo.
    case deep
}

enum ScanPlanner {
    /// - Parameter deferVision: leave out the Vision work no detector can read for a photo, and
    ///   analyze again the stored photos that now need what they skipped (spec 010). False plans as
    ///   spec 009 did: every photo gets all of it. A tiered scope always defers.
    /// - Parameter scope: which part of the work the plan is for (spec 017); `all` is the scan of every
    ///   build before tiers.
    static func plan(
        library: [AssetMetadata], stored: [StoredItemSummary], kind: ScanKind,
        policy: ScanRetryPolicy, deferVision: Bool = true, scope: PlanScope = .all
    ) -> ScanPlan {
        let storedByID = Dictionary(
            stored.map { ($0.assetID, $0) }, uniquingKeysWith: { a, _ in a })
        let currentIDs = Set(library.map(\.assetID))
        let demand = (deferVision || scope != .all) ? VisionDemand(library: library) : nil
        var refreshed: [AssetMetadata] = []
        var toAnalyze: [AssetMetadata] = []
        var repairs: [AssetMetadata] = []
        // Stored photos the library as it is now owes Vision work (a tiered scope only), and what.
        var owed: [AssetMetadata] = []
        var wantedBy: [String: VisionWork] = [:]
        for m in library {
            guard let existing = storedByID[m.assetID],
                existing.metadata.modificationDate == m.modificationDate
            else {
                toAnalyze.append(m)
                continue
            }
            // An item that was not analyzed last time gets another chance on a full
            // scan, a bounded number of times (003 FR-008).
            if kind == .full, existing.analysisSource == .notScanned,
                existing.scanAttempts < policy.crossScanAttempts
            {
                toAnalyze.append(m)
                continue
            }
            // Stored from its metadata before it was opened (spec 017): complete only for a kind that
            // needs no analysis. A burst frame listed early and then left behind by a stopped scan is
            // not.
            if existing.analysisSource == .metadataOnly, !needsNoAnalysis(m) {
                toAnalyze.append(m)
                continue
            }
            if let demand, existing.analysisSource.hasAnalysis {
                if scope == .all {
                    // A photo stored without Vision work that the library now demands: a photo
                    // arrived within a minute of it, its date or burst changed (spec 010). Judged on
                    // the library as it is now, never on whether this photo's own metadata changed. A
                    // quick check repairs too: the photos it analyzes are the ones that made these
                    // demanding.
                    if !existing.skippedVision.isDisjoint(with: demand.work(for: m)) {
                        toAnalyze.append(m)
                        repairs.append(m)
                        continue
                    }
                } else {
                    let wanted = wantedWork(m, stored: existing, demand: demand)
                    if !existing.skippedVision.isDisjoint(with: wanted) {
                        owed.append(m)
                        wantedBy[m.assetID] = wanted
                        continue
                    }
                }
            }
            if existing.metadata != m { refreshed.append(m) }
        }

        // Which of the owed photos this plan analyzes, and which it leaves for the deep tier.
        var chosen: [AssetMetadata] = []
        switch scope {
        case .all, .photos:
            break
        case .deep:
            chosen = owed
        case .changes:
            let changedOwed = owed.filter { storedByID[$0.assetID]?.metadata != $0 }
            let changedIDs = Set(changedOwed.map(\.assetID))
            // Only a photo can be a neighbour: a new screenshot or video changes nobody's demand.
            let triggers = DateWindow(
                (toAnalyze + refreshed + changedOwed)
                    .filter { VisionDemand.isGroupable($0.kind) }.compactMap(\.captureDate))
            chosen = owed.filter {
                changedIDs.contains($0.assetID) || triggers.hasDate(near: $0.captureDate)
            }
        }
        let chosenIDs = Set(chosen.map(\.assetID))
        toAnalyze += chosen
        repairs += chosen
        // An owed photo left for later still gets its metadata refreshed.
        for m in owed where !chosenIDs.contains(m.assetID) {
            if storedByID[m.assetID]?.metadata != m { refreshed.append(m) }
        }

        let ordered = newestFirst(toAnalyze)
        var skipVision: [String: VisionWork] = [:]
        if scope == .photos {
            // The photo check asks for no Vision work at all; the deep check asks for it later.
            for m in ordered where !needsNoAnalysis(m) { skipVision[m.assetID] = .all }
        } else if let demand {
            for m in ordered where !needsNoAnalysis(m) {
                let skipped =
                    wantedBy[m.assetID].map { VisionWork.all.subtracting($0) }
                    ?? demand.skipped(for: m)
                if !skipped.isEmpty { skipVision[m.assetID] = skipped }
            }
        }

        var deepOwed: Set<String> = []
        switch scope {
        case .all, .deep:
            break
        case .photos:
            // What is already owed, and every photo this plan is about to store without work the
            // library demands for it.
            deepOwed = Set(owed.map(\.assetID))
            if let demand {
                for m in ordered where !needsNoAnalysis(m) && !demand.work(for: m).isEmpty {
                    deepOwed.insert(m.assetID)
                }
            }
        case .changes:
            deepOwed = Set(owed.map(\.assetID)).subtracting(chosenIDs)
        }

        return ScanPlan(
            gone: Set(storedByID.keys).subtracting(currentIDs), refreshed: refreshed,
            toAnalyze: ordered,
            quickWins: ordered.filter { needsNoAnalysis($0) },
            repairs: newestFirst(repairs), skipVision: skipVision,
            listedEarly: scope == .photos
                ? burstFramesNotYetStored(ordered, library: library, stored: storedByID) : [],
            deepOwed: deepOwed)
    }

    /// The Vision work some detector can read for a stored photo, by the library as it is now: what its
    /// neighbours and its burst demand (spec 010), and the face pass of a soft photo nothing protects,
    /// which Unimportant reads (spec 011). The photo check never runs that pass; this is where it is
    /// asked for.
    static func wantedWork(
        _ m: AssetMetadata, stored: StoredItemSummary, demand: VisionDemand
    ) -> VisionWork {
        var work = demand.work(for: m)
        if let sharpness = stored.sharpness,
            UnimportantDetector.isCandidate(m, sharpness: sharpness)
        {
            work.insert(.faceQuality)
        }
        return work
    }

    /// Frames of a burst of two or more that no scan has stored yet, whose group the library describes
    /// without opening a photo (spec 017 FR-003). A frame already stored keeps its analysis until it is
    /// analyzed again.
    private static func burstFramesNotYetStored(
        _ ordered: [AssetMetadata], library: [AssetMetadata], stored: [String: StoredItemSummary]
    ) -> [AssetMetadata] {
        var frames: [String: Int] = [:]
        for m in library where m.kind.isStillImage {
            if let burst = m.burstID { frames[burst, default: 0] += 1 }
        }
        return ordered.filter { m in
            guard !needsNoAnalysis(m), stored[m.assetID] == nil, let burst = m.burstID else {
                return false
            }
            return (frames[burst] ?? 0) >= BurstThresholds.minimumFrames
        }
    }

    /// Whether an item is listed from its metadata alone (spec 008 FR-003): screenshots are
    /// never grouped with photos, and videos are never analyzed (004 FR-004a, 016).
    static func needsNoAnalysis(_ m: AssetMetadata) -> Bool {
        m.kind == .screenshot || m.kind.isVideo
    }

    /// Newest first, so the photos the person is likeliest to care about are checked, and
    /// reviewable, first. The order is stable: items with equal dates keep their library order,
    /// and items without a date go last.
    static func newestFirst(_ items: [AssetMetadata]) -> [AssetMetadata] {
        items.enumerated().sorted { a, b in
            let da = a.element.captureDate ?? .distantPast
            let db = b.element.captureDate ?? .distantPast
            return da != db ? da > db : a.offset < b.offset
        }.map(\.element)
    }

    /// Splits ids into chunks of `size`, numbered from `firstSequence`. `skipVision` is the plan's
    /// decision about Vision work, which each chunk carries for its own items (spec 010).
    static func chunks(
        jobID: UUID, assetIDs: [String], size: Int, firstSequence: Int = 0,
        skipVision: [String: VisionWork] = [:]
    ) -> [ScanChunk] {
        let size = min(max(1, size), ScanChunk.maxSize)
        return stride(from: 0, to: assetIDs.count, by: size).enumerated().map { n, start in
            var chunk = ScanChunk(
                jobID: jobID, sequence: firstSequence + n,
                assetIDs: Array(assetIDs[start..<min(start + size, assetIDs.count)]))
            if !skipVision.isEmpty {
                for (i, id) in chunk.assetIDs.enumerated() {
                    if let work = skipVision[id] { chunk.skipVision(work, at: i) }
                }
            }
            return chunk
        }
    }
}

/// Whether a date lies within the similar-shots window of any of a set of dates: the same test
/// `VisionDemand` and `SimilarShotsDetector` make, `later - earlier <= window`, on the same doubles.
struct DateWindow: Sendable {
    private let sorted: [Double]

    init(_ dates: [Date]) {
        sorted = dates.map(\.timeIntervalSinceReferenceDate).sorted()
    }

    func hasDate(near date: Date?) -> Bool {
        guard let date = date?.timeIntervalSinceReferenceDate, !sorted.isEmpty else {
            return false
        }
        let window = SimilarThresholds.window
        // The first date t with `date - t <= window`. Every later date is further after `date` than
        // it, so if this one is more than a window after `date`, none is near.
        var low = 0
        var high = sorted.count
        while low < high {
            let mid = (low + high) / 2
            if date - sorted[mid] <= window { high = mid } else { low = mid + 1 }
        }
        return low < sorted.count && sorted[low] - date <= window
    }
}
