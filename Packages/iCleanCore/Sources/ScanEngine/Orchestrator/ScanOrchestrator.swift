import Foundation
import PhotoGateway

/// The pipeline coordinator (SCAN_PIPELINE.md §8, §12). Single actor: owns the
/// priority ladder, governors, batch dispatch, and is the only component that
/// mutates scan_state. Batches are the checkpoint unit — a kill costs at most
/// one batch.
public actor ScanOrchestrator {
    public struct Config: Sendable {
        public var enumerationBatchSize = 2_000
        public var s2BatchSize = 32
        public var s2Width = 4
        public var s3BatchSize = 64
        public var s3Width = 8
        public var s4BatchSize = 16
        public var s4Width = 2
        public var thumbnailDimension = 512
        public var openerTargetClusters = 15 // deckReady(.duplicates) threshold
        public var openerDeadline: TimeInterval = 60

        public init() {}
    }

    private let gateway: any PhotoLibraryGateway
    private let store: any PipelineStore
    private let governor: Governor
    private let emitter = ProposalEmitter()
    private var config: Config

    // Fast-path state (SCAN_PIPELINE.md §5-S1).
    private var fastPathGroups: [[AssetStub]] = []
    private var confirmedOpenerClusters = 0
    private var scanStartedAt: Date?
    private var duplicatesDeckReady = false
    private var running = false

    private let events: AsyncStream<ScanEvent>.Continuation
    public nonisolated let eventStream: AsyncStream<ScanEvent>

    public init(gateway: any PhotoLibraryGateway, store: any PipelineStore, governor: Governor, config: Config = Config()) {
        self.gateway = gateway
        self.store = store
        self.governor = governor
        self.config = config
        var continuation: AsyncStream<ScanEvent>.Continuation!
        self.eventStream = AsyncStream { continuation = $0 }
        self.events = continuation
    }

    // MARK: - Entry points

    /// First run: full enumeration → S1 instant work → ladder loop.
    public func runFullScan() async {
        guard !running else { return }
        running = true
        defer { running = false }
        scanStartedAt = Date()

        do {
            try await enumerateAndSeed()
            try await ingestAlbums()
            events.yield(.hubBucketsAvailable)
            try await ladderLoop(allowedPriorities: 2...7)
            events.yield(.firstScanComplete)
        } catch is CancellationError {
            // Resumable: everything committed per batch.
        } catch {
            // Errors are per-batch; a thrown error here means enumeration failed.
        }
    }

    /// Incremental run (foreground change or maintenance).
    public func runIncremental() async {
        guard !running else { return }
        running = true
        defer { running = false }

        do {
            let token = try await store.loadChangeToken()
            if token == nil {
                try await enumerateAndSeed() // no token yet: full pass
            } else {
                do {
                    for try await change in gateway.persistentChanges(since: token) {
                        try await apply(change: change)
                    }
                } catch GatewayError.expiredChangeToken {
                    try await fullReDiff()
                }
            }
            try await ingestAlbums()
            try await ladderLoop(allowedPriorities: 2...7)
        } catch {}
    }

    /// Background task lane: ladder priorities 5–7 only, nothing UI-facing
    /// (SCAN_PIPELINE.md §8). `shouldContinue` is the BG expiration flag,
    /// checked at every batch boundary.
    public func runBackground(shouldContinue: @escaping @Sendable () -> Bool) async {
        guard !running else { return }
        running = true
        defer { running = false }
        try? await ladderLoop(allowedPriorities: 5...7, shouldContinue: shouldContinue)
    }

    public func hasPendingWork() async -> Bool {
        (try? await store.pendingWorkExists()) ?? false
    }

    public func onAppForeground() async {
        try? await store.resetNeedsConnection(now: Date())
    }

    // MARK: - S0: enumeration & diff

    private func enumerateAndSeed() async throws {
        var seedGroups: [DupeClusterer.SeedKey: [AssetStub]] = [:]
        var sessionInputs: [Sessionizer.Input] = []

        for try await batch in gateway.enumerateAssets(batchSize: config.enumerationBatchSize) {
            try Task.checkCancellation()
            try await store.upsertAssets(batch)
            try await runS1Instant(batch)

            for stub in batch where stub.mediaKind == .image {
                seedGroups[DupeClusterer.SeedKey(stub: stub), default: []].append(stub)
                sessionInputs.append(
                    Sessionizer.Input(
                        id: stub.id,
                        date: stub.createdAt ?? stub.modifiedAt,
                        bucket: stub.locationBucket
                    )
                )
            }
        }

        // Fast path: ranked seed groups with ≥ 2 members (SCAN_PIPELINE.md §5-S1).
        fastPathGroups = DupeClusterer.rankSeedGroups(seedGroups).map(\.members)

        // Sessionization from metadata alone.
        let drafts = Sessionizer.sessionize(sessionInputs)
        _ = try await store.replaceSessions(drafts)
    }

    private func fullReDiff() async throws {
        // Token expired: fetch all identifiers, set-difference against the DB —
        // no signal recomputation for unchanged assets (SCAN_PIPELINE.md §5-S0).
        let known = try await store.allAssetIds()
        var seen = Set<String>()
        for try await batch in gateway.enumerateAssets(batchSize: config.enumerationBatchSize) {
            try await store.upsertAssets(batch.filter { !known.contains($0.id) })
            for stub in batch { seen.insert(stub.id) }
        }
        let deleted = known.subtracting(seen)
        if !deleted.isEmpty {
            try await store.markAssetsDeleted(ids: Array(deleted), at: Date())
            try await store.invalidateProposals(touchingAssetIds: Array(deleted))
        }
    }

    private func apply(change: ChangeSet) async throws {
        try await store.upsertAssets(change.inserted + change.updated)
        try await runS1Instant(change.inserted)
        if !change.deletedIds.isEmpty {
            try await store.markAssetsDeleted(ids: change.deletedIds, at: Date())
            try await store.invalidateProposals(touchingAssetIds: change.deletedIds)
        }
        // Content changed → fair to re-propose (SCAN_PIPELINE.md §5-S7).
        try await store.clearSuppressions(assetIds: change.updated.map(\.id))
        try await store.invalidateProposals(touchingAssetIds: change.updated.map(\.id))
        // Token persisted in the same logical step as its batch (§9).
        try await store.saveChangeToken(change.token)
    }

    // MARK: - S1: instant detectors (metadata only)

    private func runS1Instant(_ batch: [AssetStub]) async throws {
        guard !batch.isEmpty else { return }
        let now = Date()
        var drafts: [ProposalDraft] = []
        let suppressed = try await store.suppressedAssetIds(actionType: .screenshotReview)

        for stub in batch where stub.subtypes.contains(.screenshot) {
            let bucket = JunkDetectors.screenshotBucket(createdAt: stub.createdAt, now: now)
            guard bucket != .recent else { continue } // recent screenshots stay out of the deck
            let ageMonths = stub.createdAt.map { Int(now.timeIntervalSince($0) / 2_592_000) } ?? 24
            if let draft = emitter.screenshotReview(
                assetId: stub.id,
                ageMonths: ageMonths,
                estBytes: Int64(stub.pixelWidth * stub.pixelHeight / 2),
                suppressed: suppressed
            ) {
                drafts.append(draft)
            }
        }
        if !drafts.isEmpty {
            try await store.upsertProposals(drafts, clusterSessionId: nil)
        }
        try await store.recordStageOutcome(
            assetIds: batch.map(\.id), stage: .s1, status: .done,
            version: DetectorRegistry.currentVersion(stage: .s1), now: now
        )
    }

    // MARK: - S1.5: albums

    private func ingestAlbums() async throws {
        let albums = try await gateway.userAlbums()
        try await store.replaceAlbums(albums)
    }

    // MARK: - The ladder loop (SCAN_PIPELINE.md §8)

    private func ladderLoop(
        allowedPriorities: ClosedRange<Int>,
        shouldContinue: @escaping @Sendable () -> Bool = { true }
    ) async throws {
        while shouldContinue() {
            try Task.checkCancellation()

            let decision = governor.decision()
            if decision == .pauseAll { return }
            let batchScale = decision == .reduceBatch ? 2 : 1
            let heavyPaused = decision == .pauseHeavy

            var didWork = false

            // Priority 3: dupe fast path (S2+S3 over seed groups).
            if allowedPriorities.contains(3), !fastPathGroups.isEmpty {
                let group = fastPathGroups.removeFirst()
                try await processFastPathGroup(group)
                checkOpenerReady()
                didWork = true
            }
            // Priority 4: S2 for remaining assets.
            else if allowedPriorities.contains(4),
                    try await runStageBatch(.s2, batchScale: batchScale) {
                didWork = true
            }
            // Priority 5: S4 (skipped when heavy is paused).
            else if allowedPriorities.contains(5), !heavyPaused,
                    try await runStageBatch(.s4, batchScale: batchScale) {
                didWork = true
            }
            // Priority 6: S5–S7 for cluster-eligible sessions.
            else if allowedPriorities.contains(6),
                    let sessionId = try await store.sessionsReadyForClustering(now: Date()).first {
                try await clusterSession(sessionId)
                didWork = true
            }
            // Priority 7: S3 backfill.
            else if allowedPriorities.contains(7),
                    try await runStageBatch(.s3, batchScale: batchScale) {
                didWork = true
            }

            if !didWork {
                checkOpenerReady(force: true)
                return // drained
            }
        }
    }

    private func checkOpenerReady(force: Bool = false) {
        guard !duplicatesDeckReady else { return }
        let deadlineHit = scanStartedAt.map { Date().timeIntervalSince($0) >= config.openerDeadline } ?? false
        // Ready at the first of: queue drained / ≥ N clusters / 60 s (SCAN_PIPELINE.md §5-S1).
        if force || fastPathGroups.isEmpty || confirmedOpenerClusters >= config.openerTargetClusters || deadlineHit {
            duplicatesDeckReady = true
            events.yield(.deckReady(.duplicates))
        }
    }

    // MARK: - Fast path: S2 + S3 for one seed group, then confirm clusters

    private func processFastPathGroup(_ group: [AssetStub]) async throws {
        var candidates: [DupeClusterer.Candidate] = []

        for stub in group {
            let thumbnail = await gateway.grayThumbnail(
                assetId: stub.id, maxDimension: config.thumbnailDimension, allowNetwork: false
            )
            var phash: UInt64?
            if case let .ok(thumb) = thumbnail {
                var signals = AssetSignals(assetId: stub.id)
                let cheap = PixelMath.cheapSignals(thumb)
                signals.phash = PerceptualHash.pHash64(thumb)
                signals.dhash = PerceptualHash.dHash64(thumb)
                signals.laplacianVariance = cheap.laplacianVariance
                signals.meanLuminance = cheap.meanLuminance
                signals.luminanceBottomConcentration = cheap.luminanceBottomConcentration
                signals.pixelVariance = cheap.pixelVariance
                signals.cornerBlobSuspect = cheap.cornerBlobSuspect
                try await store.writeSignals([signals])
                phash = signals.phash
            }

            let info = await gateway.resourceInfo(assetId: stub.id)
            if let info {
                try await store.writeResourceInfo(assetId: stub.id, info: info)
            }

            let membership = try await store.albumMembership(ids: [stub.id])
            candidates.append(
                DupeClusterer.Candidate(
                    stub: stub,
                    phash: phash,
                    fileSize: info?.fileSize,
                    isEdited: info?.isEdited ?? false,
                    inAlbum: !(membership[stub.id] ?? []).isEmpty,
                    byteHash: await gateway.byteHashIfLocal(assetId: stub.id)
                )
            )
        }

        let now = Date()
        try await store.recordStageOutcome(
            assetIds: group.map(\.id), stage: .s2, status: .done,
            version: DetectorRegistry.currentVersion(stage: .s2), now: now
        )
        try await store.recordStageOutcome(
            assetIds: group.map(\.id), stage: .s3, status: .done,
            version: DetectorRegistry.currentVersion(stage: .s3), now: now
        )

        let clusters = DupeClusterer.confirmClusters(in: candidates)
        guard !clusters.isEmpty else { return }
        let suppressed = try await store.suppressedAssetIds(actionType: .exactDuplicate)
        let drafts = emitter.exactDuplicates(clusters: clusters, suppressed: suppressed)
        try await store.upsertProposals(drafts, clusterSessionId: nil)
        confirmedOpenerClusters += drafts.count
    }

    // MARK: - Generic stage batches

    /// Returns true if any work was done.
    private func runStageBatch(_ stage: ScanStage, batchScale: Int) async throws -> Bool {
        let now = Date()
        let version = DetectorRegistry.currentVersion(stage: stage)
        let limit: Int
        switch stage {
        case .s2: limit = max(1, config.s2BatchSize / batchScale)
        case .s3: limit = max(1, config.s3BatchSize / batchScale)
        case .s4, .face1024: limit = max(1, config.s4BatchSize / batchScale)
        case .s1: limit = config.enumerationBatchSize
        }

        let ids = try await store.nextBatch(stage: stage, limit: limit, now: now, currentVersion: version)
        guard !ids.isEmpty else { return false }

        switch stage {
        case .s2: try await runS2(ids: ids, now: now, version: version)
        case .s3: try await runS3(ids: ids, now: now, version: version)
        case .s4: try await runS4(ids: ids, now: now, version: version)
        default: break
        }
        return true
    }

    private func runS2(ids: [String], now: Date, version: Int) async throws {
        var done: [String] = []
        var needsConnection: [String] = []
        var failed: [String] = []
        var signalsBatch: [AssetSignals] = []
        var corruptDrafts: [ProposalDraft] = []

        let stubs = try await store.assetStubs(ids: ids)
        let stubsById = Dictionary(uniqueKeysWithValues: stubs.map { ($0.id, $0) })
        let suppressedCorrupt = try await store.suppressedAssetIds(actionType: .corruptFile)
        let suppressedBlank = try await store.suppressedAssetIds(actionType: .blankFrame)
        let protection = ProposalEmitter.ProtectionContext(
            favoriteIds: Set(stubs.filter(\.isFavorite).map(\.id)),
            editedIds: [], // edited arrives at S3; blank/corrupt don't gate on it
            albumMemberIds: []
        )

        for id in ids {
            let result = await gateway.grayThumbnail(
                assetId: id, maxDimension: config.thumbnailDimension, allowNetwork: false
            )
            switch result {
            case .ok(let thumb):
                var signals = AssetSignals(assetId: id)
                let cheap = PixelMath.cheapSignals(thumb)
                signals.phash = PerceptualHash.pHash64(thumb)
                signals.dhash = PerceptualHash.dHash64(thumb)
                signals.laplacianVariance = cheap.laplacianVariance
                signals.meanLuminance = cheap.meanLuminance
                signals.luminanceBottomConcentration = cheap.luminanceBottomConcentration
                signals.pixelVariance = cheap.pixelVariance
                signals.cornerBlobSuspect = cheap.cornerBlobSuspect
                signalsBatch.append(signals)
                done.append(id)

                // Blank frames need nothing else — emit immediately (Tier 1).
                if JunkDetectors.isBlankFrame(pixelVariance: cheap.pixelVariance),
                   let stub = stubsById[id],
                   let draft = emitter.junkSingle(
                       actionType: .blankFrame,
                       assetId: id,
                       reason: ReasonParams(key: "reason.junk.blank"),
                       confidence: 0.99,
                       estBytes: Int64(stub.pixelWidth * stub.pixelHeight / 2),
                       protection: protection,
                       suppressed: suppressedBlank
                   ) {
                    corruptDrafts.append(draft)
                }
            case .needsConnection:
                needsConnection.append(id)
            case .failed:
                failed.append(id)
                // Repeated local failure = the corrupt-file detector
                // (SCAN_PIPELINE.md §11). Emission handled once retries cap.
                if let stub = stubsById[id],
                   let draft = emitter.junkSingle(
                       actionType: .corruptFile,
                       assetId: id,
                       reason: ReasonParams(key: "reason.junk.corrupt"),
                       confidence: 0.9,
                       estBytes: Int64(stub.pixelWidth * stub.pixelHeight / 4),
                       protection: protection,
                       suppressed: suppressedCorrupt
                   ) {
                    corruptDrafts.append(draft)
                }
            }
        }

        // One transaction-equivalent checkpoint per batch.
        try await store.writeSignals(signalsBatch)
        if !corruptDrafts.isEmpty {
            try await store.upsertProposals(corruptDrafts, clusterSessionId: nil)
        }
        try await store.recordStageOutcome(assetIds: done, stage: .s2, status: .done, version: version, now: now)
        try await store.recordStageOutcome(assetIds: needsConnection, stage: .s2, status: .needsConnection, version: version, now: now)
        try await store.recordStageOutcome(assetIds: failed, stage: .s2, status: .failed, version: version, now: now)
    }

    private func runS3(ids: [String], now: Date, version: Int) async throws {
        var done: [String] = []
        var failed: [String] = []
        for id in ids {
            if let info = await gateway.resourceInfo(assetId: id) {
                try await store.writeResourceInfo(assetId: id, info: info)
                done.append(id)
            } else {
                failed.append(id)
            }
        }
        try await store.recordStageOutcome(assetIds: done, stage: .s3, status: .done, version: version, now: now)
        try await store.recordStageOutcome(assetIds: failed, stage: .s3, status: .failed, version: version, now: now)
    }

    private func runS4(ids: [String], now: Date, version: Int) async throws {
        var done: [String] = []
        var failed: [String] = []
        var updates: [AssetSignals] = []

        let existing = try await store.signals(ids: ids)
        for id in ids {
            guard let vision = await gateway.visionSignals(assetId: id, maxDimension: config.thumbnailDimension) else {
                failed.append(id)
                continue
            }
            var signals = existing[id] ?? AssetSignals(assetId: id)
            signals.faceCount = vision.faceCount
            signals.bestFaceQuality = vision.bestFaceQuality
            signals.eyesOpenMin = vision.eyesOpenMin
            signals.saliencyArea = vision.saliencyBox?.area
            updates.append(signals)
            done.append(id)
        }

        try await store.writeSignals(updates)
        try await store.recordStageOutcome(assetIds: done, stage: .s4, status: .done, version: version, now: now)
        try await store.recordStageOutcome(assetIds: failed, stage: .s4, status: .failed, version: version, now: now)

        // Junk verdicts need S4 face/saliency — emit for this batch now.
        try await emitJunkVerdicts(ids: done)
    }

    private func emitJunkVerdicts(ids: [String]) async throws {
        let signals = try await store.signals(ids: ids)
        let stubs = try await store.assetStubs(ids: ids)
        let stubsById = Dictionary(uniqueKeysWithValues: stubs.map { ($0.id, $0) })
        let resources = try await store.resourceInfos(ids: ids)
        let membership = try await store.albumMembership(ids: ids)

        let protection = ProposalEmitter.ProtectionContext(
            favoriteIds: Set(stubs.filter(\.isFavorite).map(\.id)),
            editedIds: Set(resources.filter { $0.value.isEdited }.map(\.key)),
            albumMemberIds: Set(membership.filter { !$0.value.isEmpty }.map(\.key))
        )
        let suppressedBlur = try await store.suppressedAssetIds(actionType: .blurry)
        let suppressedDark = try await store.suppressedAssetIds(actionType: .darkShot)
        let suppressedPocket = try await store.suppressedAssetIds(actionType: .pocketShot)

        var drafts: [ProposalDraft] = []
        for (id, signal) in signals {
            guard let stub = stubsById[id], stub.mediaKind == .image,
                  !stub.subtypes.contains(.screenshot)
            else { continue }
            let bytes = resources[id]?.fileSize ?? Int64(stub.pixelWidth * stub.pixelHeight / 2)

            if let lapVar = signal.laplacianVariance {
                let verdict = JunkDetectors.blur(
                    laplacianVariance: lapVar,
                    severeBelow: 8,
                    borderlineBelow: 25,
                    faceCount: signal.faceCount,
                    saliencyArea: signal.saliencyArea
                )
                if verdict != .none {
                    // Sharp-sibling routing happens at S5 (keep-best wins over blurry);
                    // here we emit the per-photo verdict.
                    let normalized = min(99, Int((lapVar / 25.0) * 100.0))
                    if let draft = emitter.junkSingle(
                        actionType: .blurry,
                        assetId: id,
                        reason: ReasonParams(key: "reason.junk.blurry", args: ["sharpness": .double(Double(normalized))]),
                        confidence: verdict == .severe ? 0.92 : 0.7,
                        estBytes: bytes,
                        protection: protection,
                        suppressed: suppressedBlur
                    ) {
                        drafts.append(draft)
                    }
                }
            }

            if let meanLum = signal.meanLuminance,
               let concentration = signal.luminanceBottomConcentration,
               JunkDetectors.isDark(
                   meanLuminance: meanLum,
                   bottomConcentration: concentration,
                   faceCount: signal.faceCount,
                   saliencyArea: signal.saliencyArea
               ),
               let draft = emitter.junkSingle(
                   actionType: .darkShot,
                   assetId: id,
                   reason: ReasonParams(key: "reason.junk.dark"),
                   confidence: 0.75,
                   estBytes: bytes,
                   protection: protection,
                   suppressed: suppressedDark
               ) {
                drafts.append(draft)
            }

            if let lapVar = signal.laplacianVariance,
               let meanLum = signal.meanLuminance,
               let pixelVar = signal.pixelVariance,
               JunkDetectors.isPocketShot(
                   laplacianVariance: lapVar,
                   meanLuminance: meanLum,
                   pixelVariance: pixelVar,
                   faceCount: signal.faceCount,
                   saliencyArea: signal.saliencyArea
               ),
               let draft = emitter.junkSingle(
                   actionType: .pocketShot,
                   assetId: id,
                   reason: ReasonParams(key: "reason.junk.pocket"),
                   confidence: 0.9,
                   estBytes: bytes,
                   protection: protection,
                   suppressed: suppressedPocket
               ) {
                drafts.append(draft)
            }
        }
        if !drafts.isEmpty {
            try await store.upsertProposals(drafts, clusterSessionId: nil)
        }
    }

    // MARK: - S5–S7 per session (priority 6)

    private func clusterSession(_ sessionId: Int64) async throws {
        let members = try await store.sessionMembers(sessionId: sessionId)
        guard members.count >= 2 else {
            try await store.markSessionClean(sessionId: sessionId)
            return
        }

        let imageMembers = members.filter { $0.mediaKind == .image && !$0.subtypes.contains(.screenshot) }
        guard imageMembers.count >= 2 else {
            try await store.markSessionClean(sessionId: sessionId)
            return
        }

        // Transient embeddings for this window only (SCAN_PIPELINE.md §6.3).
        guard let distances = await gateway.featureDistances(
            assetIds: imageMembers.map(\.id), maxDimension: config.thumbnailDimension
        ) else {
            try await store.markSessionClean(sessionId: sessionId)
            return // unrecognized Vision revision → similar detector disabled
        }

        let signals = try await store.signals(ids: imageMembers.map(\.id))
        let resources = try await store.resourceInfos(ids: imageMembers.map(\.id))
        let membership = try await store.albumMembership(ids: imageMembers.map(\.id))

        let clusterInputs = imageMembers.map { stub in
            SimilarClusterer.Member(
                id: stub.id,
                phash: signals[stub.id]?.phash,
                capturedAt: stub.createdAt
            )
        }
        let clusters = SimilarClusterer.cluster(members: clusterInputs, distances: distances)
        guard !clusters.isEmpty else {
            try await store.markSessionClean(sessionId: sessionId)
            return
        }

        let protection = ProposalEmitter.ProtectionContext(
            favoriteIds: Set(imageMembers.filter(\.isFavorite).map(\.id)),
            editedIds: Set(resources.filter { $0.value.isEdited }.map(\.key)),
            albumMemberIds: Set(membership.filter { !$0.value.isEmpty }.map(\.key))
        )
        let suppressed = try await store.suppressedAssetIds(actionType: .similarKeepBest)
        let stubsById = Dictionary(uniqueKeysWithValues: imageMembers.map { ($0.id, $0) })

        var drafts: [ProposalDraft] = []
        for cluster in clusters {
            let kernelMembers = cluster.memberIds.compactMap { id -> KeepBestKernel.Member? in
                guard let stub = stubsById[id] else { return nil }
                let signal = signals[id]
                return KeepBestKernel.Member(
                    id: id,
                    sharpness: signal?.laplacianVariance,
                    faceCount: signal?.faceCount,
                    bestFaceQuality: signal?.bestFaceQuality,
                    eyesOpenMin: signal?.eyesOpenMin,
                    saliencyArea: signal?.saliencyArea,
                    megapixels: Double(stub.pixelWidth * stub.pixelHeight) / 1_000_000.0,
                    isFavorite: stub.isFavorite,
                    isEdited: resources[id]?.isEdited ?? false,
                    capturedAt: stub.createdAt
                )
            }
            let kernel = KeepBestKernel.evaluate(kernelMembers)
            let estBytes = cluster.memberIds
                .filter { $0 != kernel.keeperId }
                .reduce(Int64(0)) { total, id in
                    total + (resources[id]?.fileSize
                        ?? stubsById[id].map { Int64($0.pixelWidth * $0.pixelHeight / 2) }
                        ?? 0)
                }
            if let draft = emitter.similarKeepBest(
                cluster: cluster,
                kernel: kernel,
                estBytes: estBytes,
                baseConfidence: 0.75,
                protection: protection,
                suppressed: suppressed
            ) {
                drafts.append(draft)
            }
        }

        // S5→S6→S7 committed as one unit; the store implementation wraps this
        // upsert + dirty-clear in a single transaction (SCAN_PIPELINE.md §5).
        try await store.upsertProposals(drafts, clusterSessionId: sessionId)
        try await store.markSessionClean(sessionId: sessionId)
    }
}
