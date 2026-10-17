import Foundation
import PhotoGateway

/// S7 — turns clusters and verdicts into typed, explained, protection-gated
/// proposals (SCAN_PIPELINE.md §5-S7).
public struct ProposalEmitter: Sendable {
    public struct ProtectionContext: Sendable {
        public let favoriteIds: Set<String>
        public let editedIds: Set<String>
        public let albumMemberIds: Set<String>

        public init(favoriteIds: Set<String>, editedIds: Set<String>, albumMemberIds: Set<String>) {
            self.favoriteIds = favoriteIds
            self.editedIds = editedIds
            self.albumMemberIds = albumMemberIds
        }
    }

    public init() {}

    // MARK: Exact/near duplicates

    /// Tier 0. The ONLY action allowed to include protected photos — the
    /// protected copy is always the keeper (DESIGN.md §9.3).
    public func exactDuplicates(
        clusters: [DupeClusterer.DupeCluster],
        suppressed: Set<String>
    ) -> [ProposalDraft] {
        clusters.compactMap { cluster in
            let members = cluster.memberIds.filter { !suppressed.contains($0) }
            guard !members.isEmpty else { return nil }
            let reason = ReasonParams(
                key: cluster.byteVerified ? "reason.dupe.identical" : "reason.dupe.nearCertain"
            )
            return ProposalDraft(
                actionType: .exactDuplicate,
                unit: .cluster,
                memberIds: members,
                keeperId: cluster.keeperId,
                reason: reason,
                regretTier: 0,
                confidence: cluster.byteVerified ? 1.0 : 0.97,
                estBytes: cluster.estBytesFreed
            )
        }
    }

    // MARK: Similar keep-best (Tier 3 — never batched, DESIGN.md Decision Log #11)

    public func similarKeepBest(
        cluster: SimilarClusterer.SimilarCluster,
        kernel: KeepBestKernel.Result,
        estBytes: Int64,
        baseConfidence: Double,
        protection: ProtectionContext,
        suppressed: Set<String>
    ) -> ProposalDraft? {
        // Protected photos are never deletion candidates here — they may remain
        // as keepers only (DESIGN.md §9.3).
        let candidates = cluster.memberIds.filter { id in
            id != kernel.keeperId
                && !protection.favoriteIds.contains(id)
                && !protection.editedIds.contains(id)
                && !suppressed.contains(id)
        }
        guard !candidates.isEmpty else { return nil }

        let confidence = baseConfidence * (1.0 - 0.5 * cluster.narrativeDemotion)
        let reason: ReasonParams
        if let keeper = kernel.keeperId {
            let chips = kernel.keeperChips.map(\.rawValue).joined(separator: ", ")
            reason = ReasonParams(
                key: "reason.similar.keepBest",
                args: [
                    "count": .int(Int64(cluster.memberIds.count)),
                    "chips": .string(chips.isEmpty ? "best overall" : chips),
                ]
            )
            return ProposalDraft(
                actionType: .similarKeepBest,
                unit: .cluster,
                memberIds: candidates.sorted(),
                keeperId: keeper,
                reason: reason,
                regretTier: 3,
                confidence: confidence,
                estBytes: estBytes
            )
        } else {
            // Humility layout: the kernel could not crown a keeper (SCAN_PIPELINE.md §7).
            reason = ReasonParams(
                key: "reason.similar.pickFavorite",
                args: ["count": .int(Int64(cluster.memberIds.count))]
            )
            return ProposalDraft(
                actionType: .similarKeepBest,
                unit: .cluster,
                memberIds: candidates.sorted(),
                keeperId: nil,
                reason: reason,
                regretTier: 3,
                confidence: confidence * 0.8,
                estBytes: estBytes,
                humility: true
            )
        }
    }

    // MARK: Junk singles

    public func junkSingle(
        actionType: ActionType,
        assetId: String,
        reason: ReasonParams,
        confidence: Double,
        estBytes: Int64,
        protection: ProtectionContext,
        suppressed: Set<String>
    ) -> ProposalDraft? {
        // Tier-4 hard exclusions (DESIGN.md §9.3): favorites and edited photos
        // are never junk candidates; album members appear badged in drill-ins
        // (per-item decks), which junk singles are.
        guard !protection.favoriteIds.contains(assetId),
              !protection.editedIds.contains(assetId),
              !suppressed.contains(assetId)
        else { return nil }

        let tier: Int
        switch actionType {
        case .blankFrame, .corruptFile, .pocketShot: tier = 1
        default: tier = 2
        }
        return ProposalDraft(
            actionType: actionType,
            unit: .photo,
            memberIds: [assetId],
            keeperId: nil,
            reason: reason,
            regretTier: tier,
            confidence: confidence,
            estBytes: estBytes
        )
    }

    // MARK: Screenshot review deck (review-only in MVP — DESIGN.md §15)

    public func screenshotReview(
        assetId: String,
        ageMonths: Int,
        estBytes: Int64,
        suppressed: Set<String>
    ) -> ProposalDraft? {
        guard !suppressed.contains(assetId) else { return nil }
        return ProposalDraft(
            actionType: .screenshotReview,
            unit: .photo,
            memberIds: [assetId],
            keeperId: nil,
            reason: ReasonParams(
                key: "reason.screenshot.aged",
                args: ["ageMonths": .int(Int64(ageMonths))]
            ),
            regretTier: 2,
            confidence: 0.9,
            estBytes: estBytes
        )
    }

    /// DESIGN.md §10 ordering score, materialized into proposal.score by S6.
    public static func deckScore(
        estBytes: Int64,
        confidence: Double,
        decisionCostSeconds: Double,
        regretTier: Int
    ) -> Double {
        let gb = Double(estBytes) / 1_073_741_824.0
        let regretPenalty = Double(regretTier) * 0.05
        return (gb * confidence) / max(decisionCostSeconds, 0.5) - regretPenalty
    }
}
