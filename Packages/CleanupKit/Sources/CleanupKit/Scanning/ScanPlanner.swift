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
}

enum ScanPlanner {
    /// - Parameter deferVision: leave out the Vision work no detector can read for a photo, and
    ///   analyze again the stored photos that now need what they skipped (spec 010). False plans as
    ///   spec 009 did: every photo gets all of it.
    static func plan(
        library: [AssetMetadata], stored: [StoredItemSummary], kind: ScanKind,
        policy: ScanRetryPolicy, deferVision: Bool = true
    ) -> ScanPlan {
        let storedByID = Dictionary(
            stored.map { ($0.assetID, $0) }, uniquingKeysWith: { a, _ in a })
        let currentIDs = Set(library.map(\.assetID))
        let demand = deferVision ? VisionDemand(library: library) : nil
        var refreshed: [AssetMetadata] = []
        var toAnalyze: [AssetMetadata] = []
        var repairs: [AssetMetadata] = []
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
            // A photo stored without Vision work that the library now demands: a photo arrived within
            // a minute of it, its date or burst changed (spec 010). Judged on the library as it is
            // now, never on whether this photo's own metadata changed. A quick check repairs too: the
            // photos it analyzes are the ones that made these demanding.
            if let demand, existing.analysisSource.hasAnalysis,
                !existing.skippedVision.isDisjoint(with: demand.work(for: m))
            {
                toAnalyze.append(m)
                repairs.append(m)
                continue
            }
            if existing.metadata != m { refreshed.append(m) }
        }
        let ordered = newestFirst(toAnalyze)
        var skipVision: [String: VisionWork] = [:]
        if let demand {
            for m in ordered where !needsNoAnalysis(m) {
                let skipped = demand.skipped(for: m)
                if !skipped.isEmpty { skipVision[m.assetID] = skipped }
            }
        }
        return ScanPlan(
            gone: Set(storedByID.keys).subtracting(currentIDs), refreshed: refreshed,
            toAnalyze: ordered,
            quickWins: ordered.filter { needsNoAnalysis($0) },
            repairs: newestFirst(repairs), skipVision: skipVision)
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

    /// Splits ids into chunks of `size`, numbered from `firstSequence`.
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
