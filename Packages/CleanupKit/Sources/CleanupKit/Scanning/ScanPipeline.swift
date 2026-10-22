import CoreGraphics
import Foundation

public protocol Scanner: Sendable {
    /// Full scan: analyzes every item that is new or changed since it was last analyzed.
    /// Continues an unfinished job if one exists.
    func startFullScan() async -> AsyncStream<ScanProgress>
    /// Quick check for new or changed items, run on app open (FR-005a).
    func quickCheck() async -> ScanProgress
    /// Pauses losslessly: when this returns, everything processed so far is saved
    /// (002 G1). `reason` decides whether the scan resumes by itself later.
    func pause(reason: ScanPauseReason) async
    func resume() async
    func stop() async
}

/// Runs a scan as a durable job of small chunks (003): each chunk is leased, run, and
/// checkpointed with its results in one transaction, so a crash loses at most the
/// unfinished part of one chunk and the next launch continues from the first
/// unfinished chunk without comparing the whole library again.
public actor ScanPipeline: Scanner {
    public static let previewSize = 512

    private let library: PhotoLibrary
    private let store: Store
    private let analyzer: Analyzer
    private let profile: ScanProfile
    private let progressEvery: Int
    private let policy: ScanRetryPolicy
    private let features: ProFeatures
    /// Whether plans leave out the Vision work no detector can read (spec 010).
    private let deferVision: Bool
    private let pauseWaitLimit: Duration
    private let minProgressInterval: Duration
    private let thermalState: @Sendable () -> ProcessInfo.ThermalState
    private let lowPowerMode: @Sendable () -> Bool
    /// Identifies this process. A chunk leased by another incarnation was left behind
    /// by a process that died (003 FR-005).
    private let incarnation = UUID()

    private var task: Task<Void, Never>?
    private var isPaused = false
    private(set) var pauseReason: ScanPauseReason?
    /// Set once a paused scan has saved everything it processed.
    private var pausedAndSaved = false
    /// How many `pause()` calls returned because the run loop acknowledged the pause,
    /// not because the wait limit ran out or the scan was resumed. Lets tests prove
    /// acknowledgement without timing.
    private(set) var pauseAcknowledgements = 0
    private var stopRequested = false
    /// Checkpoints that failed one after another. A few in a row mean the store cannot be written.
    private var saveFailures = 0
    static let saveFailureLimit = 3
    /// Results whose checkpoint failed. They go out with the next checkpoint, and the scan does
    /// not claim to be complete while any are left, so a full disk never loses photos quietly.
    private var unsaved: [LibraryItem] = []
    /// The chunks those results belong to: written in the same transaction as the results, so a
    /// chunk is never stored as unfinished next to results that say it is done.
    private var unsavedChunks: [ScanChunk] = []
    /// The counters that belong to `unsaved`, added to the session by the next write.
    private var owedTally = Tally()
    private var runKind: ScanKind = .full
    private var session: ScanSession?
    private var chunks: [ScanChunk] = []
    private var sinceProgress = 0
    private var lastProgressAt: ContinuousClock.Instant?
    /// Moves up whenever the stored results changed enough to be worth showing: quick wins
    /// stored, a block of photos finished (spec 008). The app rebuilds its results when it moves.
    private var publishedRevision = 0
    private var nextBlockEdge = ScanBlocks.first
    /// What the store holds for the running job. `pause()` writes this, never the
    /// in-memory counters, which run ahead of the saved results while a chunk is in
    /// flight (review fix: a kill after a pause must not leave counters above the results).
    private var storedSession: ScanSession?
    /// The session as it was when the job was loaded or planned. The base of a write while the
    /// store holds no copy of it yet (the first write of the job failed).
    private var jobStart: ScanSession?
    /// The chunks this process leased, as last saved, by chunk id. With several lanes more than one
    /// is leased at a time.
    private var storedLeased: [String: ScanChunk] = [:]
    /// Lanes that are working on a chunk right now.
    private var activeChunks = 0
    /// Finished chunks in the order they will be written. One writer takes them one at a time, so
    /// the counters in the session a write carries are exactly those of what the store holds.
    private var writeQueue: [PendingWrite] = []
    private var writerActive = false
    /// Chunks that are queued or being written, plus the one a lane is waiting for. A chunk is not
    /// leased again until its last write has landed, or an old state could overwrite the new lease.
    private var pendingWriteChunks: Set<Int> = []
    private var outstandingWrites = 0
    private var writeWaiters: [CheckedContinuation<Void, Never>] = []
    private var progressSink: (@Sendable (ScanProgress) -> Void)?
    /// Held while a write that changes chunk rows and counters runs, so a pause's release of leased
    /// chunks can never land after, and undo, the write that finished one of them.
    private var gateHeld = false
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []
    /// Set when a job is resumed from the store: items added or changed while it was
    /// interrupted are picked up before it completes (003 FR-011).
    private var needsCatchUp = false

    /// - Parameters:
    ///   - profile: how wide the scan works (spec 009): photos at a time, chunks at a time, how many
    ///     finished chunks may wait for the store, and the chunk size (1…64, the unit of durability).
    ///   - progressEvery: analyzed items between two progress events (002 R4).
    ///   - policy: retry, timeout and crash limits (003).
    ///   - features: what Pro unlocks; free by default, so videos are not analyzed.
    ///   - deferVision: leave out the feature print and face quality of photos that no detector can
    ///     read them for, and analyze them later if that changes (spec 010). False is the scan of
    ///     spec 009, for comparison; the results are the same either way.
    ///   - pauseWaitLimit: the longest `pause()` waits for the run loop to save and
    ///     acknowledge; tests raise it so a slow machine cannot hit it.
    ///   - minProgressInterval: at most one progress event per interval while items finish.
    ///     Events that carry a change of state or a new block are never held back. A 30,000-item
    ///     scan otherwise sent about 4,000 events, each one a screen update and a system call.
    public init(
        library: PhotoLibrary, store: Store, analyzer: Analyzer = DefaultAnalyzer(),
        profile: ScanProfile, progressEvery: Int = 10, policy: ScanRetryPolicy = .default,
        features: ProFeatures = .free, deferVision: Bool = true,
        pauseWaitLimit: Duration = .seconds(2), minProgressInterval: Duration = .zero,
        thermalState: @escaping @Sendable () -> ProcessInfo.ThermalState = {
            ProcessInfo.processInfo.thermalState
        },
        lowPowerMode: @escaping @Sendable () -> Bool = {
            ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    ) {
        self.library = library
        self.store = store
        self.analyzer = analyzer
        self.profile = profile
        self.progressEvery = max(1, progressEvery)
        var policy = policy
        policy.chunkSize = min(max(1, profile.chunkSize), ScanChunk.maxSize)
        self.policy = policy
        self.features = features
        self.deferVision = deferVision
        self.pauseWaitLimit = pauseWaitLimit
        self.minProgressInterval = minProgressInterval
        self.thermalState = thermalState
        self.lowPowerMode = lowPowerMode
    }

    /// One lane, no write-behind: the narrow scan of specs 003 to 008.
    ///   - concurrency: photos analyzed at the same time.
    ///   - chunkSize: items per chunk, the unit of durability (1…64).
    public init(
        library: PhotoLibrary, store: Store, analyzer: Analyzer = DefaultAnalyzer(),
        concurrency: Int = 4, chunkSize: Int = 32, progressEvery: Int = 10,
        policy: ScanRetryPolicy = .default, features: ProFeatures = .free,
        deferVision: Bool = true, pauseWaitLimit: Duration = .seconds(2),
        minProgressInterval: Duration = .zero,
        thermalState: @escaping @Sendable () -> ProcessInfo.ThermalState = {
            ProcessInfo.processInfo.thermalState
        }
    ) {
        self.init(
            library: library, store: store, analyzer: analyzer,
            profile: ScanProfile(name: "custom", concurrency: concurrency, chunkSize: chunkSize),
            progressEvery: progressEvery, policy: policy, features: features,
            deferVision: deferVision, pauseWaitLimit: pauseWaitLimit,
            minProgressInterval: minProgressInterval,
            thermalState: thermalState)
    }

    // MARK: Scanner

    public func startFullScan() async -> AsyncStream<ScanProgress> {
        let (stream, continuation) = AsyncStream<ScanProgress>.makeStream()
        guard task == nil else {
            continuation.finish()
            return stream
        }
        isPaused = false
        pauseReason = nil
        pausedAndSaved = false
        stopRequested = false
        task = Task { [weak self] in
            _ = await self?.run(kind: .full) { continuation.yield($0) }
            // Free the run slot before the stream ends, so a scan started right after the
            // last event is not refused.
            await self?.clearTask()
            continuation.finish()
        }
        return stream
    }

    public func quickCheck() async -> ScanProgress {
        guard task == nil else { return snapshot() }
        // Take the run slot before the first await: a full scan started meanwhile is
        // refused instead of running alongside this check.
        task = Task {}
        // Cleared before the first await, so a stop() that arrives while the session is being
        // read is still seen after it.
        stopRequested = false
        if let s = try? await store.currentSession(), s.isActive {
            task = nil
            // An unfinished job waits for the user's Resume (001 FR-005a).
            return ScanProgress(
                processed: s.processedItems, total: s.totalItems, notScanned: s.notScannedCount,
                state: s.state, failed: s.failedItems)
        }
        if stopRequested {
            task = nil
            return snapshot()
        }
        isPaused = false
        pauseReason = nil
        let work = Task { await self.run(kind: .quickCheck) { _ in } }
        task = Task { _ = await work.value }
        let result = await work.value
        task = nil
        return result
    }

    public func pause(reason: ScanPauseReason) async {
        guard task != nil else { return }
        let alreadyPaused = isPaused
        isPaused = true
        // A pause the user asked for is never turned into an automatic one.
        if !alreadyPaused || (pauseReason != .user && pauseReason != .storageUnavailable) {
            pauseReason = reason
        }
        if !alreadyPaused { pausedAndSaved = false }
        if session != nil {
            session?.state = .paused
            await persistPaused()
        }
        // Give the run loop a moment to release the chunk in flight and save what it
        // processed (002 G1, 003 FR-010), so the app can be suspended right after this.
        let deadline = ContinuousClock.now + pauseWaitLimit
        while isPaused, !pausedAndSaved, session != nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        if isPaused, pausedAndSaved { pauseAcknowledgements += 1 }
    }

    public func resume() async {
        isPaused = false
        pauseReason = nil
        pausedAndSaved = false
        saveFailures = 0
        if session?.state == .paused {
            session?.state = .running
            if var s = storedSession, s.state == .paused {
                s.state = .running
                if (try? await store.saveSession(s)) != nil { storedSession = s }
            }
        }
    }

    /// Saves the paused state together with what the store already holds: the saved
    /// counters and the leased chunk released, so a death while in-flight items finish
    /// is an interruption, not a crash (003 FR-010).
    private func persistPaused() async {
        await withStoreGate {
            // Read under the gate: a chunk whose write landed meanwhile is no longer leased.
            guard var s = storedSession else { return }
            s.state = .paused
            // Every chunk this process leased, not only one: with several lanes more are running.
            let released: [ScanChunk] = storedLeased.values.filter { $0.state == .running }
                .sorted { $0.sequence < $1.sequence }
                .map {
                    var chunk = $0
                    chunk.state = .pending
                    chunk.owner = nil
                    return chunk
                }
            if !released.isEmpty {
                if (try? await store.saveChunks(released, session: s)) != nil {
                    for chunk in released { storedLeased[chunk.id] = chunk }
                    storedSession = s
                }
            } else if (try? await store.saveSession(s)) != nil {
                storedSession = s
            }
        }
    }

    /// Runs `body` with no other gated write running: they take turns, in the order they asked.
    private func withStoreGate<T>(_ body: () async -> T) async -> T {
        if gateHeld {
            await withCheckedContinuation { gateWaiters.append($0) }
        } else {
            gateHeld = true
        }
        let result = await body()
        if gateWaiters.isEmpty {
            gateHeld = false
        } else {
            gateWaiters.removeFirst().resume()
        }
        return result
    }

    public func stop() async {
        stopRequested = true
        isPaused = false
        pauseReason = nil
        await task?.value
    }

    private func clearTask() { task = nil }

    // MARK: Run

    @discardableResult
    private func run(kind: ScanKind, progress: @escaping @Sendable (ScanProgress) -> Void) async
        -> ScanProgress
    {
        sinceProgress = 0
        lastProgressAt = nil
        publishedRevision = 0
        storedSession = nil
        jobStart = nil
        storedLeased = [:]
        needsCatchUp = false
        saveFailures = 0
        unsaved = []
        unsavedChunks = []
        owedTally = Tally()
        writeQueue = []
        pendingWriteChunks = []
        outstandingWrites = 0
        activeChunks = 0
        progressSink = progress
        runKind = kind
        guard await loadJob(kind: kind) else { return await finish(progress: progress) }
        nextBlockEdge = ScanBlocks.edge(after: session?.processedItems ?? 0)
        progress(snapshot())
        var caughtUp = false
        while !stopRequested {
            // Nothing is in flight here, so the store must hold everything that was finished.
            await drainWrites()
            await waitWhilePaused(progress: progress)
            if stopRequested { break }
            guard let index = nextEligibleIndex() else {
                if let wakeAt = earliestRetryTime() {
                    await sleep(until: wakeAt)
                    continue
                }
                if kind == .full, !caughtUp, needsCatchUp {
                    // The library may have changed while this job was interrupted.
                    caughtUp = true
                    await catchUp()
                    continue
                }
                break
            }
            if profile.lanes > 1, !chunks[index].isolate {
                await runLanes(progress: progress)
            } else {
                // One chunk alone: always the case after a crash (003 FR-006), where the item
                // being analyzed must be the only one that could have killed the process.
                await runChunk(at: index, progress: progress)
            }
        }
        await drainWrites()
        await saveUnsaved(progress: progress)
        return await finish(progress: progress)
    }

    // MARK: Lanes

    /// Works on several chunks at once (spec 009): each lane leases a chunk, opens and analyzes its
    /// previews, and hands the result to the writer, so one lane's wait for the last photo of its
    /// chunk, its lease and its store write overlap the analysis of the others. Ends when no
    /// chunk is left to start, on pause, stop or heat, or when the next chunk must run alone.
    private func runLanes(progress: @escaping @Sendable (ScanProgress) -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<profile.lanes {
                group.addTask { await self.laneLoop(progress: progress) }
            }
        }
    }

    private enum Pick {
        case none
        /// The next chunk must run alone.
        case isolated
        /// A chunk is ready but its last state has not been written yet.
        case blocked
        case chunk(Int)
    }

    private func pickChunk() -> Pick {
        let now = Date.now
        var blocked = false
        for (i, chunk) in chunks.enumerated() where chunk.isEligible(at: now) {
            if pendingWriteChunks.contains(i) {
                blocked = true
                continue
            }
            return chunk.isolate ? .isolated : .chunk(i)
        }
        return blocked ? .blocked : .none
    }

    private func laneLoop(progress: @escaping @Sendable (ScanProgress) -> Void) async {
        while !stopRequested, !isPaused, !isTooHot {
            // The writer is behind: starting more chunks would only pile up results.
            if outstandingWrites > profile.writeBehind {
                await waitForWriter()
                continue
            }
            switch pickChunk() {
            case .none, .isolated: return
            case .blocked: await waitForWriter()
            case .chunk(let index): await runChunk(at: index, progress: progress)
            }
        }
    }

    /// Tries once more to write results that earlier checkpoints could not. A full scan waits for
    /// the person to fix the problem (and tap Resume); a quick check has nobody to ask, so it ends
    /// and the next check finds the photos again, because they are not in the store.
    private func saveUnsaved(progress: @Sendable (ScanProgress) -> Void) async {
        while !unsaved.isEmpty, !stopRequested {
            let written: Bool
            if session != nil {
                let s = sessionForWrite(adding: owedTally)
                written =
                    (try? await store.checkpoint(items: unsaved, chunks: unsavedChunks, session: s))
                    != nil
                if written { storedSession = s }
            } else {
                written = (try? await store.upsert(unsaved)) != nil
            }
            if written {
                unsaved = []
                unsavedChunks = []
                owedTally = Tally()
                saveFailures = 0
                return
            }
            guard runKind == .full else { return }
            saveFailures = Self.saveFailureLimit
            pauseForStorage()
            await waitWhilePaused(progress: progress)
        }
    }

    /// Loads the unfinished job, adopts one from an older app version, or plans a new
    /// one. Returns false when there is nothing to run.
    private func loadJob(kind: ScanKind) async -> Bool {
        if let previous = try? await store.currentSession(), previous.isActive {
            let stored = (try? await store.chunks(job: previous.id)) ?? []
            if stored.isEmpty {
                // Started by an app version without chunks: keep its count (003 FR-014).
                return await plan(kind: .full, adopting: previous)
            }
            let reclaimed = ScanReclaim.reclaim(
                stored, session: previous, owner: incarnation, policy: policy)
            var s = reclaimed.session
            // Items the app died on twice are recorded first, also when the crash budget
            // ends the job.
            var poisonedItems: [LibraryItem] = []
            if !reclaimed.poisoned.isEmpty {
                poisonedItems = await library.fetchItems(withIDs: reclaimed.poisoned).map {
                    LibraryItem(
                        metadata: $0, analysisSource: .notScanned, analysis: nil,
                        scanFailure: .crashed)
                }
                await stampAttempts(&poisonedItems)
            }
            if s.state == .stopped {
                // Crash budget used up: keep what was done, end the job. Saving the ended
                // session also removes its chunks, in the same transaction.
                try? await store.upsert(poisonedItems)
                try? await store.saveSession(s)
                session = s
                chunks = []
                return false
            }
            s.state = .running
            if kind == .full { s.kind = .full }
            // Write only what changed: for a large job that is one chunk, not thousands.
            let storedByID = Dictionary(
                stored.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var changed = reclaimed.chunks.filter { storedByID[$0.id] != $0 }
            var saved = false
            if !poisonedItems.isEmpty,
                let k = changed.firstIndex(where: {
                    !Set($0.assetIDs).isDisjoint(with: reclaimed.poisoned)
                })
            {
                // One transaction: the set-aside items with the chunk that records them, so
                // a death in between cannot count them twice.
                let holder = changed.remove(at: k)
                saved =
                    (try? await store.checkpoint(items: poisonedItems, chunk: holder, session: s))
                    != nil
                if saved, !changed.isEmpty { try? await store.saveChunks(changed, session: nil) }
            } else {
                saved = (try? await store.saveChunks(changed, session: s)) != nil
            }
            if saved { storedSession = s }
            session = s
            jobStart = s
            chunks = reclaimed.chunks
            needsCatchUp = true
            return true
        }
        return await plan(kind: kind, adopting: nil)
    }

    private func plan(kind: ScanKind, adopting previous: ScanSession?) async -> Bool {
        let library = await self.library.fetchAllItems()
        let stored = (try? await store.itemSummaries()) ?? []
        let plan = ScanPlanner.plan(
            library: library, stored: stored, kind: kind, policy: policy, features: features,
            deferVision: deferVision)
        await apply(plan)
        var s: ScanSession
        if var previous {
            previous.kind = kind == .full ? .full : previous.kind
            previous.state = .running
            previous.baseProcessed = previous.processedItems
            previous.totalItems = previous.processedItems + plan.toAnalyze.count
            s = previous
        } else {
            s = ScanSession(kind: kind, state: .running, totalItems: plan.toAnalyze.count)
        }
        let new = ScanPlanner.chunks(
            jobID: s.id, assetIDs: plan.toAnalyze.map(\.assetID), size: policy.chunkSize,
            skipVision: plan.skipVision)
        if (try? await store.createJob(s, chunks: new)) != nil { storedSession = s }
        session = s
        jobStart = s
        chunks = new
        return true
    }

    /// Writes what a plan decided besides the analysis itself: items that left the library are
    /// forgotten, changed metadata is refreshed, and items that need no analysis are stored right
    /// away so they can be listed before any photo is opened (spec 008 quick wins).
    private func apply(_ plan: ScanPlan) async {
        try? await store.deleteItems(plan.gone)
        // In slices, so a library whose every item changed at once (the first scan after an update
        // that reads a new property) never needs one long transaction or holds every record in
        // memory together. Each slice is complete on its own, so a stop in the middle keeps what
        // was written and the next check writes the rest.
        for start in stride(from: 0, to: plan.refreshed.count, by: 500) {
            try? await store.refreshMetadata(
                Array(plan.refreshed[start..<min(start + 500, plan.refreshed.count)]))
        }
        for start in stride(from: 0, to: plan.quickWins.count, by: 500) {
            let slice = plan.quickWins[start..<min(start + 500, plan.quickWins.count)]
            try? await store.upsert(
                slice.map { LibraryItem(metadata: $0, analysisSource: .metadataOnly, analysis: nil) })
        }
        if !plan.gone.isEmpty || !plan.refreshed.isEmpty || !plan.quickWins.isEmpty {
            publishedRevision += 1
        }
    }

    /// After a job was resumed from the store, items added or changed meanwhile become
    /// new chunks (003 FR-011).
    private func catchUp() async {
        guard let jobID = session?.id else { return }
        let library = await self.library.fetchAllItems()
        let stored = (try? await store.itemSummaries()) ?? []
        // A quick-check diff: only new or changed items, never a retry of items this job
        // already gave up on.
        let plan = ScanPlanner.plan(
            library: library, stored: stored, kind: .quickCheck, policy: policy,
            features: features, deferVision: deferVision)
        await apply(plan)
        // Items still waiting in an unfinished chunk are covered. Items in finished chunks
        // that changed since are not, and must be analyzed again.
        let covered = Set(
            chunks.filter { $0.state != .done }.flatMap { c in
                c.undoneIndices.map { c.assetIDs[$0] }
            })
        // Results that are analyzed but not yet written are not new photos.
        let waiting = Set(unsaved.map(\.assetID))
        let ids = plan.toAnalyze.map(\.assetID).filter {
            !covered.contains($0) && !waiting.contains($0)
        }
        guard !ids.isEmpty else { return }
        let new = ScanPlanner.chunks(
            jobID: jobID, assetIDs: ids, size: policy.chunkSize,
            firstSequence: (chunks.map(\.sequence).max() ?? -1) + 1, skipVision: plan.skipVision)
        session?.totalItems += ids.count
        chunks += new
        jobStart = session
        if let s = session, (try? await store.saveChunks(new, session: s)) != nil {
            storedSession = s
        } else {
            // The store still holds the old total; the next write carries the difference.
            owedTally.totalAdded += ids.count
        }
    }

    private func finish(progress: @Sendable (ScanProgress) -> Void) async -> ScanProgress {
        if var final = session {
            if final.state != .stopped {
                final.state = stopRequested || !unsaved.isEmpty ? .stopped : .completed
            }
            final.finishedAt = .now
            session = final
            // Saving an ended session also removes its chunks, in one transaction.
            try? await store.saveSession(final)
        }
        // A pause that arrives while the job ends must not turn the last event into
        // "paused".
        let final = snapshot(ignoringPause: true)
        progress(final)
        isPaused = false
        pauseReason = nil
        session = nil
        chunks = []
        unsaved = []
        unsavedChunks = []
        owedTally = Tally()
        storedSession = nil
        jobStart = nil
        storedLeased = [:]
        progressSink = nil
        return final
    }

    // MARK: Chunks

    private func nextEligibleIndex() -> Int? {
        let now = Date.now
        return chunks.firstIndex { $0.isEligible(at: now) }
    }

    /// Counters that a finished chunk adds to the session. Kept apart from the live session, which
    /// moves the moment a photo finishes: what a write carries must equal what the store holds, so
    /// a death between two writes never leaves counters above the saved results (002 G1).
    struct Tally: Sendable {
        var processed = 0
        var notScanned = 0
        var failed = 0
        /// Items that left the library while their chunk waited.
        var itemsGone = 0
        /// Items added to the job by a catch-up whose save failed.
        var totalAdded = 0
        var lastAssetID: String?

        static func + (a: Tally, b: Tally) -> Tally {
            Tally(
                processed: a.processed + b.processed, notScanned: a.notScanned + b.notScanned,
                failed: a.failed + b.failed, itemsGone: a.itemsGone + b.itemsGone,
                totalAdded: a.totalAdded + b.totalAdded,
                lastAssetID: b.lastAssetID ?? a.lastAssetID)
        }
    }

    private struct PendingWrite: Sendable {
        var index: Int
        var items: [LibraryItem]
        var chunk: ScanChunk
        var tally: Tally
    }

    private func earliestRetryTime() -> Date? {
        chunks.filter { $0.state == .pending }.compactMap(\.notBefore).min()
    }

    private enum ItemOutcome: Sendable {
        case item(LibraryItem)
        case failed(ScanFailure)
    }

    /// Photos each lane keeps in flight now.
    private func laneWidth() -> Int {
        profile.laneWidth(total: profile.width(thermal: thermalState(), lowPower: lowPowerMode()))
    }

    private func runChunk(
        at index: Int, progress: @escaping @Sendable (ScanProgress) -> Void
    ) async {
        guard index < chunks.count, session != nil else { return }
        var chunk = chunks[index]
        // Lease: written before any work, so a death during the chunk is visible. The state is
        // changed before the first suspension, so no other lane can pick the same chunk.
        chunk.state = .running
        chunk.owner = incarnation
        chunk.notBefore = nil
        chunk.inFlightIndex = nil
        chunks[index] = chunk
        activeChunks += 1
        if (try? await store.saveChunks([chunk], session: nil)) != nil {
            storedLeased[chunk.id] = chunk
        }

        let undone = chunk.undoneIndices
        let fresh = await library.fetchItems(withIDs: undone.map { chunk.assetIDs[$0] })
        let byID = Dictionary(fresh.map { ($0.assetID, $0) }, uniquingKeysWith: { a, _ in a })
        var work: [Int] = []
        var tally = Tally()
        for i in undone {
            if byID[chunk.assetIDs[i]] == nil {
                // No longer in the library: it leaves the job, finished and no longer
                // counted in the total (003 FR-011).
                chunk.markDone(i)
                // Read first: assigning through `session?` starts the write before the
                // right-hand side runs, and that side reads `session` too.
                if let total = session?.totalItems { session?.totalItems = max(0, total - 1) }
                tally.itemsGone += 1
            } else {
                work.append(i)
            }
        }

        var results: [LibraryItem] = []
        var failures: [(index: Int, failure: ScanFailure)] = []
        // Items that were not started because of a pause, a stop or heat.
        var cutShort = false
        let limit = policy.itemTimeout
        // Metadata per work index, captured by value so the task closures do not touch
        // the chunk that the code below mutates.
        let metadata: [Int: AssetMetadata] = Dictionary(
            uniqueKeysWithValues: work.map { ($0, byID[chunk.assetIDs[$0]]!) })
        // The Vision work the plan left out, by work index (spec 010), captured the same way.
        let skips: [Int: VisionWork] = Dictionary(
            uniqueKeysWithValues: work.map { ($0, chunk.skippedVision(at: $0)) })

        if chunk.isolate {
            // After a crash: one item at a time. The item is saved as in flight before it
            // starts, so a death is blamed on exactly that item, and the chunk is saved
            // after every item (003 FR-006).
            for i in work {
                if stopRequested || isPaused || isTooHot {
                    cutShort = true
                    break
                }
                chunk.inFlightIndex = i
                chunks[index] = chunk
                if (try? await store.saveChunks([chunk], session: nil)) != nil {
                    storedLeased[chunk.id] = chunk
                }
                let outcome = await Self.analyze(
                    metadata[i]!, library: library, analyzer: analyzer, limit: limit,
                    analyzeVideos: features.videoAnalysis, skipping: skips[i] ?? [])
                chunk.inFlightIndex = nil
                record(
                    i, outcome, chunk: &chunk, results: &results, failures: &failures,
                    tally: &tally, index: index, progress: progress)
                if case .item = outcome, session != nil {
                    await stampAttempts(&results)
                    let written = await withStoreGate { () -> Bool in
                        let s = sessionForWrite(adding: tally)
                        guard
                            (try? await store.checkpoint(items: results, chunk: chunk, session: s))
                                != nil
                        else { return false }
                        storedSession = s
                        return true
                    }
                    if written {
                        storedLeased[chunk.id] = chunk
                        results.removeAll()
                        tally = Tally()
                        saveFailures = 0
                    } else {
                        noteSaveFailure()
                    }
                } else if (try? await store.saveChunks([chunk], session: nil)) != nil {
                    storedLeased[chunk.id] = chunk
                }
            }
        } else {
            await withTaskGroup(of: (Int, ItemOutcome).self) { group in
                var next = 0
                var inFlight = 0
                func addNext() -> Bool {
                    guard !stopRequested, !isPaused, !isTooHot, next < work.count else {
                        return false
                    }
                    let i = work[next]
                    next += 1
                    inFlight += 1
                    let m = metadata[i]!
                    let analyzeVideos = features.videoAnalysis
                    let skipped = skips[i] ?? []
                    group.addTask(priority: .userInitiated) { [library, analyzer] in
                        (
                            i,
                            await Self.analyze(
                                m, library: library, analyzer: analyzer, limit: limit,
                                analyzeVideos: analyzeVideos, skipping: skipped)
                        )
                    }
                    return true
                }
                // On pause, stop or heat: add no more work, let in-flight items finish.
                func fill() {
                    let width = laneWidth()
                    while inFlight < width, addNext() {}
                }
                fill()
                while let (i, outcome) = await group.next() {
                    inFlight -= 1
                    record(
                        i, outcome, chunk: &chunk, results: &results, failures: &failures,
                        tally: &tally, index: index, progress: progress)
                    fill()
                }
                cutShort = next < work.count
            }
        }

        let interrupted = stopRequested || isPaused || isTooHot || cutShort
        if chunk.isComplete {
            chunk.state = .done
            chunk.owner = nil
        } else if interrupted {
            // Release before waiting, and also when the pause or heat has already passed:
            // items that were not started must run again, never be skipped. No attempt is
            // counted (003 FR-010).
            chunk.state = .pending
            chunk.owner = nil
        } else if failures.isEmpty {
            // Not expected (incomplete, nothing failed, not cut short); run again.
            chunk.state = .pending
            chunk.owner = nil
        } else {
            chunk.attempts += 1
            chunk.lastError = failures.first.map(\.failure.rawValue)
            if chunk.attempts >= policy.maxAttempts {
                // Give up on the failing items; everything else goes on (003 FR-006).
                for (i, failure) in failures {
                    let id = chunk.assetIDs[i]
                    results.append(
                        LibraryItem(
                            metadata: byID[id]!, analysisSource: .notScanned, analysis: nil,
                            scanFailure: failure))
                    chunk.markDone(i)
                    session?.processedItems += 1
                    session?.notScannedCount += 1
                    session?.failedItems += 1
                    tally.processed += 1
                    tally.notScanned += 1
                    tally.failed += 1
                }
                chunk.state = .done
                chunk.owner = nil
            } else {
                chunk.state = .pending
                chunk.owner = nil
                chunk.notBefore = Date.now.addingTimeInterval(
                    Self.seconds(policy.delay(forAttempt: chunk.attempts)))
            }
        }
        chunk.inFlightIndex = nil
        chunks[index] = chunk
        activeChunks -= 1
        enqueue(PendingWrite(index: index, items: results, chunk: chunk, tally: tally))
        // The next chunk starts once the writer is no further behind than the profile allows.
        while outstandingWrites > profile.writeBehind { await waitForWriter() }
    }

    // MARK: Writer

    /// Hands a finished chunk to the writer, which stores chunks one at a time, in order, while the
    /// lanes go on analyzing (spec 009).
    private func enqueue(_ write: PendingWrite) {
        writeQueue.append(write)
        pendingWriteChunks.insert(write.index)
        outstandingWrites += 1
        guard !writerActive else { return }
        writerActive = true
        Task { await self.runWriter() }
    }

    /// Chunks the writer stores in one transaction when it has fallen behind. A transaction costs
    /// about 8 ms however small, which on its own limited a scan to about 4,000 photos a second.
    private static let writeBatch = 8

    private func runWriter() async {
        while !writeQueue.isEmpty {
            let batch = Array(writeQueue.prefix(Self.writeBatch))
            writeQueue.removeFirst(batch.count)
            await commit(batch)
            for write in batch { pendingWriteChunks.remove(write.index) }
            outstandingWrites -= batch.count
            wakeWriteWaiters()
        }
        writerActive = false
        wakeWriteWaiters()
    }

    /// Stores finished chunks, their states and the session counters in one transaction
    /// (003 FR-002). Results an earlier write could not store go out with these.
    private func commit(_ batch: [PendingWrite]) async {
        var items = batch.flatMap(\.items)
        await stampAttempts(&items)
        guard session != nil else { return }
        let pending = unsaved + items
        let owed = unsavedChunks + batch.map(\.chunk)
        let tally = batch.reduce(owedTally) { $0 + $1.tally }
        let stored = await withStoreGate { () -> ScanSession? in
            let s = sessionForWrite(adding: tally)
            guard (try? await store.checkpoint(items: pending, chunks: owed, session: s)) != nil
            else { return nil }
            storedSession = s
            for chunk in owed { storedLeased[chunk.id] = nil }
            return s
        }
        if stored != nil {
            saveFailures = 0
            unsaved = []
            unsavedChunks = []
            owedTally = Tally()
        } else {
            unsaved = pending
            unsavedChunks = owed
            owedTally = tally
            noteSaveFailure()
        }
        if isPaused, pauseReason != .storageUnavailable, activeChunks == 0, writeQueue.isEmpty {
            pausedAndSaved = true
        }
        if unsaved.isEmpty, let done = (storedSession ?? session)?.processedItems,
            done >= nextBlockEdge
        {
            // A block of photos is finished and saved: the results can be rebuilt from the store.
            publishedRevision += 1
            nextBlockEdge = ScanBlocks.edge(after: done)
        }
        if let sink = progressSink { emit(snapshot(), sink) }
    }

    /// The session a write carries: what the store holds, plus the counters of what the write adds.
    private func sessionForWrite(adding tally: Tally) -> ScanSession {
        var s = storedSession ?? jobStart ?? session ?? ScanSession(kind: runKind, state: .running)
        s.processedItems += tally.processed
        s.notScannedCount += tally.notScanned
        s.failedItems += tally.failed
        s.totalItems = max(0, s.totalItems - tally.itemsGone + tally.totalAdded)
        if let id = tally.lastAssetID { s.lastProcessedAssetID = id }
        if let live = session { s.state = live.state }
        return s
    }

    private func waitForWriter() async {
        await withCheckedContinuation { writeWaiters.append($0) }
    }

    private func wakeWriteWaiters() {
        let waiters = writeWaiters
        writeWaiters = []
        waiters.forEach { $0.resume() }
    }

    /// Returns once every queued write has landed or failed.
    private func drainWrites() async {
        while writerActive || !writeQueue.isEmpty { await waitForWriter() }
    }

    /// Records one finished item. `session` is read and written in place: pause() may
    /// change its state while a chunk is draining, and that must not be lost.
    private func record(
        _ i: Int, _ outcome: ItemOutcome, chunk: inout ScanChunk, results: inout [LibraryItem],
        failures: inout [(index: Int, failure: ScanFailure)], tally: inout Tally, index: Int,
        progress: @Sendable (ScanProgress) -> Void
    ) {
        switch outcome {
        case .item(let item):
            results.append(item)
            chunk.markDone(i)
            session?.processedItems += 1
            tally.processed += 1
            if item.analysisSource == .notScanned {
                session?.notScannedCount += 1
                tally.notScanned += 1
            }
            session?.lastProcessedAssetID = item.assetID
            tally.lastAssetID = item.assetID
        case .failed(let failure):
            failures.append((i, failure))
        }
        chunks[index] = chunk
        sinceProgress += 1
        // While pausing or stopping, the only progress event comes after the release
        // checkpoint, so a paused event always means "saved" (002 G1).
        if sinceProgress >= progressEvery, !isPaused, !stopRequested,
            lastProgressAt.map({ ContinuousClock.now - $0 >= minProgressInterval }) ?? true
        {
            sinceProgress = 0
            emit(snapshot(), progress)
        }
    }

    /// Items that end a scan unanalyzed carry how many scans have tried them (003 FR-008).
    private func stampAttempts(_ items: inout [LibraryItem]) async {
        let ids = items.filter { $0.analysisSource == .notScanned }.map(\.assetID)
        guard !ids.isEmpty else { return }
        let stored = (try? await store.scanAttempts(for: ids)) ?? [:]
        for i in items.indices where items[i].analysisSource == .notScanned {
            items[i].scanAttempts = (stored[items[i].assetID] ?? 0) + 1
        }
    }

    /// A checkpoint failed. After a few in a row a full scan stops and says so: going on would
    /// analyze photos whose results cannot be kept.
    private func noteSaveFailure() {
        saveFailures += 1
        if saveFailures >= Self.saveFailureLimit { pauseForStorage() }
    }

    private func pauseForStorage() {
        // A quick check has nobody to resume it, so it never pauses: it ends, and the photos it
        // could not save are found again by the next one.
        guard runKind == .full, pauseReason != .storageUnavailable else { return }
        isPaused = true
        pauseReason = .storageUnavailable
        session?.state = .paused
    }

    // MARK: Waiting

    private func waitWhilePaused(progress: @Sendable (ScanProgress) -> Void) async {
        var last: ScanProgress?
        while !stopRequested, isPaused || isTooHot {
            // Nothing is in flight here, so the store is already complete. Checked on
            // every pass: a pause requested during a heat wait must still be reported
            // and acknowledged (review fix).
            if pauseReason != .storageUnavailable { pausedAndSaved = true }
            let now = snapshot()
            if now != last {
                progress(now)
                last = now
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        if last != nil { progress(snapshot()) }
    }

    /// Waits for a retry time; ends at once on pause or stop (003 FR-010).
    private func sleep(until date: Date) async {
        while !stopRequested, !isPaused, !isTooHot, Date.now < date {
            let remaining = date.timeIntervalSinceNow
            try? await Task.sleep(for: .milliseconds(Int(min(250, max(1, remaining * 1000)))))
        }
    }

    private var isTooHot: Bool {
        let state = thermalState()
        return state == .serious || state == .critical
    }

    private func snapshot(ignoringPause: Bool = false) -> ScanProgress {
        guard let s = session else {
            return ScanProgress(processed: 0, total: 0, notScanned: 0, state: .idle)
        }
        let paused = isPaused && !ignoringPause
        return ScanProgress(
            processed: s.processedItems, total: s.totalItems, notScanned: s.notScannedCount,
            state: paused ? .paused : s.state, isThermalPaused: !paused && isTooHot,
            pauseReason: paused ? pauseReason : nil, failed: s.failedItems,
            publishedRevision: publishedRevision)
    }

    private func emit(_ event: ScanProgress, _ progress: @Sendable (ScanProgress) -> Void) {
        lastProgressAt = .now
        progress(event)
    }

    static func seconds(_ d: Duration) -> TimeInterval {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    /// One item: preview plus analysis, under the per-item time limit (003 FR-007).
    /// A failed analysis is retried by the chunk; a missing preview is a result.
    /// Without Pro, videos are not analyzed (004 FR-004a): no frame is requested, and the item
    /// is stored with its metadata only so Large Videos can rank it. The same holds for screenshots
    /// in every edition: they are listed by kind, never grouped with photos (no detector reads
    /// their analysis), so opening their preview would be wasted work.
    private static func analyze(
        _ m: AssetMetadata, library: PhotoLibrary, analyzer: Analyzer, limit: Duration,
        analyzeVideos: Bool, skipping skipped: VisionWork = []
    ) async -> ItemOutcome {
        if m.kind == .screenshot || (m.kind.isVideo && !analyzeVideos) {
            return .item(LibraryItem(metadata: m, analysisSource: .metadataOnly, analysis: nil))
        }
        let outcome: Timeout.Outcome<ItemOutcome> = await Timeout.run(limit) {
            guard !Task.isCancelled else { return .failed(.transient) }
            let preview = await library.preview(for: m.assetID, maxPixels: previewSize)
            guard let image = preview.image else {
                return .item(LibraryItem(metadata: m, analysisSource: .notScanned, analysis: nil))
            }
            do {
                let analysis = try await analyzer.analyze(
                    image, metadata: m, vision: VisionWork.all.subtracting(skipped))
                return .item(
                    LibraryItem(metadata: m, analysisSource: preview.source, analysis: analysis))
            } catch {
                return .failed(.transient)
            }
        }
        switch outcome {
        case .finished(let result): return result
        case .timedOut: return .failed(.timeout)
        }
    }
}
