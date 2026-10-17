import Foundation

/// Thresholds for similar shots (research R4).
public enum SimilarThresholds {
    /// Only photos taken this close together are compared.
    public static let window: TimeInterval = 60
    /// Thumbprint correlation for "same moment". Burst frames measure 0.41–0.91,
    /// different photos ≤ 0.35.
    public static let thumbprint = 0.5
    /// Feature-print distance for "same moment", when Vision is available. Burst
    /// frames measure 0.02–0.07, different scenes ≥ 0.13.
    public static let featurePrint = 0.1
    /// When Vision is available it must also agree with the thumbprint, so photos
    /// that merely share a layout are not grouped.
    public static let featurePrintAgreement = 0.15
}

/// Groups shots of the same moment and suggests the best one (Story 3).
public struct SimilarShotsDetector: CategoryDetector {
    public let category = CleanupCategory.similar
    public let needsAnalysis = true

    public init() {}

    public func detect(items: [LibraryItem]) -> [ResultGroup] {
        let photos = items
            .filter { ($0.metadata.kind == .photo || $0.metadata.kind == .livePhoto) && $0.analysis != nil }
            .sorted { ($0.metadata.captureDate ?? .distantPast) < ($1.metadata.captureDate ?? .distantPast) }
        guard photos.count >= 2 else { return [] }

        let prints = FeaturePrintCache()
        var uf = UnionFind(count: photos.count)
        for i in photos.indices {
            guard let di = photos[i].metadata.captureDate else { continue }
            var j = i + 1
            while j < photos.count, let dj = photos[j].metadata.captureDate,
                dj.timeIntervalSince(di) <= SimilarThresholds.window
            {
                if isSameMoment(photos[i], photos[j], prints: prints) { uf.union(i, j) }
                j += 1
            }
        }
        // Burst frames always belong together, even if more than a minute apart.
        var byBurst: [String: Int] = [:]
        for (i, p) in photos.enumerated() {
            guard let burst = p.metadata.burstID else { continue }
            if let first = byBurst[burst] { uf.union(first, i) } else { byBurst[burst] = i }
        }

        return uf.groups().map { indices in
            let members = indices.map { photos[$0] }
            let keepers = KeeperRules.similarKeepers(members)
            return ResultGroup(
                type: .similarShots, members: KeeperRules.ordered(members, keepers: keepers),
                keepers: keepers,
                confidence: members.contains { $0.analysisSource == .cloudPreview } ? .lower : .normal)
        }
    }

    func isSameMoment(_ a: LibraryItem, _ b: LibraryItem, prints: FeaturePrintCache) -> Bool {
        if let burst = a.metadata.burstID, burst == b.metadata.burstID { return true }
        let t = Thumbprint.similarity(a.analysis?.thumbprint ?? Data(), b.analysis?.thumbprint ?? Data())
        let fp = prints.distance(a, b)  // .infinity when Vision was unavailable
        if fp.isFinite {
            return fp < SimilarThresholds.featurePrint
                || (t >= SimilarThresholds.thumbprint && fp < SimilarThresholds.featurePrintAgreement)
        }
        return t >= SimilarThresholds.thumbprint
    }
}
