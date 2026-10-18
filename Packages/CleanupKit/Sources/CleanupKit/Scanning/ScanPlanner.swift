import Foundation

/// What a scan has to do, computed from the library and the store (pure, 003 plan).
struct ScanPlan: Sendable {
    /// Stored items no longer in the library.
    var gone: Set<String>
    /// Stored items whose metadata changed without needing re-analysis.
    var refreshed: [LibraryItem]
    /// Items to analyze, in library order.
    var toAnalyze: [AssetMetadata]
}

enum ScanPlanner {
    static func plan(
        library: [AssetMetadata], stored: [LibraryItem], kind: ScanKind, policy: ScanRetryPolicy,
        features: ProFeatures = .free
    ) -> ScanPlan {
        let storedByID = Dictionary(
            stored.map { ($0.assetID, $0) }, uniquingKeysWith: { a, _ in a })
        let currentIDs = Set(library.map(\.assetID))
        var refreshed: [LibraryItem] = []
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
            if existing.metadata != m {
                var updated = existing
                updated.metadata = m
                refreshed.append(updated)
            }
        }
        return ScanPlan(
            gone: Set(storedByID.keys).subtracting(currentIDs), refreshed: refreshed,
            toAnalyze: toAnalyze)
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
