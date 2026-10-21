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
    /// Items that need no analysis to be listed: screenshots, and videos in the free app. They are
    /// stored at once, so Screenshots and Large Videos can be reviewed before any photo is opened
    /// (spec 008, quick wins). They stay in `toAnalyze`, so counts and chunks are unchanged.
    var quickWins: [AssetMetadata]
}

enum ScanPlanner {
    static func plan(
        library: [AssetMetadata], stored: [StoredItemSummary], kind: ScanKind,
        policy: ScanRetryPolicy, features: ProFeatures = .free
    ) -> ScanPlan {
        let storedByID = Dictionary(
            stored.map { ($0.assetID, $0) }, uniquingKeysWith: { a, _ in a })
        let currentIDs = Set(library.map(\.assetID))
        var refreshed: [AssetMetadata] = []
        var toAnalyze: [AssetMetadata] = []
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
            // Videos stored without analysis (the free app) are analyzed once Pro is on, on a
            // full scan the user starts. A quick check never starts that work (001 FR-005a).
            if kind == .full, features.videoAnalysis, m.kind.isVideo,
                existing.analysisSource == .metadataOnly
            {
                toAnalyze.append(m)
                continue
            }
            if existing.metadata != m { refreshed.append(m) }
        }
        let newestFirst = newestFirst(toAnalyze)
        return ScanPlan(
            gone: Set(storedByID.keys).subtracting(currentIDs), refreshed: refreshed,
            toAnalyze: newestFirst,
            quickWins: newestFirst.filter { needsNoAnalysis($0, features: features) })
    }

    /// Whether an item is listed from its metadata alone (spec 008 FR-003): screenshots are
    /// never grouped with photos, and the free app does not analyze videos (004 FR-004a).
    static func needsNoAnalysis(_ m: AssetMetadata, features: ProFeatures) -> Bool {
        m.kind == .screenshot || (m.kind.isVideo && !features.videoAnalysis)
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
    static func chunks(
        jobID: UUID, assetIDs: [String], size: Int, firstSequence: Int = 0
    ) -> [ScanChunk] {
        let size = min(max(1, size), ScanChunk.maxSize)
        return stride(from: 0, to: assetIDs.count, by: size).enumerated().map { n, start in
            ScanChunk(
                jobID: jobID, sequence: firstSequence + n,
                assetIDs: Array(assetIDs[start..<min(start + size, assetIDs.count)]))
        }
    }
}
