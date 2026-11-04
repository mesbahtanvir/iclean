import Foundation
import Testing

@testable import CleanupKit

/// A store that keeps only the first `limit` writes. A process killed after its `limit`-th write leaves
/// exactly that behind: every write before it, none after, and each write all or nothing (the real
/// store's transactions). The scan it belonged to is not stopped, so it runs on in memory with nothing
/// it does kept, which costs time and proves nothing wrong. Reads are the real store's, as a restarted
/// process would find it.
final class DyingStore: Store, @unchecked Sendable {
    private let base: SwiftDataStore
    private let limit: Int
    private let lock = NSLock()
    private var writes = 0

    init(_ base: SwiftDataStore, limit: Int) {
        self.base = base
        self.limit = limit
    }

    /// Writes asked of the store so far, kept or not.
    var writeCount: Int { lock.withLock { writes } }

    private func admit() -> Bool {
        lock.withLock {
            writes += 1
            return writes <= limit
        }
    }

    // MARK: Reads

    func items() async throws -> [LibraryItem] { try await base.items() }
    func itemSummaries() async throws -> [StoredItemSummary] { try await base.itemSummaries() }
    func itemsWithoutFeaturePrints() async throws -> [LibraryItem] {
        try await base.itemsWithoutFeaturePrints()
    }
    func featurePrints(for assetIDs: [String]) async throws -> [String: Data] {
        try await base.featurePrints(for: assetIDs)
    }
    func keepMarks() async throws -> Set<String> { try await base.keepMarks() }
    func currentSession() async throws -> ScanSession? { try await base.currentSession() }
    func sessions() async throws -> [ScanSession] { try await base.sessions() }
    func scanAttempts(for assetIDs: [String]) async throws -> [String: Int] {
        try await base.scanAttempts(for: assetIDs)
    }
    func chunks(job: UUID) async throws -> [ScanChunk] { try await base.chunks(job: job) }
    func resultInputs() async throws -> ResultInputs { try await base.resultInputs() }
    func revision() async throws -> Int64 { try await base.revision() }
    func itemCount() async throws -> Int { try await base.itemCount() }
    func loadLaunchState() async throws -> LaunchState { try await base.loadLaunchState() }
    func stateInfo() async throws -> [StateKey: StateInfo] { try await base.stateInfo() }
    func sizes(for assetIDs: [String]) async throws -> [String: MeasuredSize] {
        try await base.sizes(for: assetIDs)
    }
    func openStatus() async -> StoreOpenStatus { await base.openStatus() }

    // MARK: Writes

    func refreshMetadata(_ metadata: [AssetMetadata]) async throws {
        if admit() { try await base.refreshMetadata(metadata) }
    }
    func upsert(_ items: [LibraryItem]) async throws {
        if admit() { try await base.upsert(items) }
    }
    func deleteItems(_ assetIDs: Set<String>) async throws {
        if admit() { try await base.deleteItems(assetIDs) }
    }
    func setKeep(_ assetID: String, _ keep: Bool) async throws {
        if admit() { try await base.setKeep(assetID, keep) }
    }
    func clearKeepMarks() async throws {
        if admit() { try await base.clearKeepMarks() }
    }
    func saveSession(_ session: ScanSession) async throws {
        if admit() { try await base.saveSession(session) }
    }
    func createJob(_ session: ScanSession, chunks: [ScanChunk]) async throws {
        if admit() { try await base.createJob(session, chunks: chunks) }
    }
    func saveChunks(_ chunks: [ScanChunk], session: ScanSession?) async throws {
        if admit() { try await base.saveChunks(chunks, session: session) }
    }
    func checkpoint(items: [LibraryItem], chunks: [ScanChunk], session: ScanSession) async throws {
        if admit() { try await base.checkpoint(items: items, chunks: chunks, session: session) }
    }
    func deleteChunks(job: UUID) async throws {
        if admit() { try await base.deleteChunks(job: job) }
    }
    func saveState(_ key: StateKey, version: Int, payload: Data) async throws {
        if admit() { try await base.saveState(key, version: version, payload: payload) }
    }
    func saveSnapshot(_ payload: Data, version: Int, ifRevision: Int64) async throws -> Bool {
        if admit() {
            return try await base.saveSnapshot(payload, version: version, ifRevision: ifRevision)
        }
        return false
    }
    func deleteState(_ keys: Set<StateKey>) async throws {
        if admit() { try await base.deleteState(keys) }
    }
    func setSizes(_ sizes: [String: MeasuredSize]) async throws {
        if admit() { try await base.setSizes(sizes) }
    }
    func deleteAllData() async throws {
        if admit() { try await base.deleteAllData() }
    }
    func eraseStoreFiles() async throws {
        if admit() { try await base.eraseStoreFiles() }
    }
}

/// Spec 017 SC-005 and 003 SC-001, by sweeping the point of death instead of sampling it: a scan that
/// dies at any write, including the one between the photo check and the deep check, is finished by
/// what Home offers, ends in the store an uninterrupted scan ends in, and never redoes work the store
/// already held.
@Suite struct CrashPointTests {
    let fast = ScanRetryPolicy(
        chunkSize: 4, maxAttempts: 3, backoff: [.milliseconds(5), .milliseconds(10)],
        itemTimeout: .seconds(20), crashBudget: 5, crossScanAttempts: 6)
    let t0 = 1_600_000_000.0
    let image = TestImages.scene(seed: 3, width: 64, height: 48)
    static let softOnes = ["soloSoft": 0.5, "soloSoft2": 0.4]

    func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: t0 + seconds) }

    func drain(_ stream: AsyncStream<ScanProgress>) async -> [ScanProgress] {
        var all: [ScanProgress] = []
        for await p in stream { all.append(p) }
        return all
    }

    /// Twelve items in three chunks of four: two neighbours, a sharp photo alone, two soft ones alone, a
    /// burst of three, two frames of a second burst taken hours apart, a screenshot and a video.
    func library() -> FakePhotoLibrary {
        let lib = FakePhotoLibrary()
        func put(_ id: String, _ t: Double, burst: String? = nil) {
            lib.add(Make.meta(id, date: at(t), burst: burst), preview: .local(image))
        }
        put("pairA", 0)
        put("pairB", 20)
        put("soloSharp", 10_000)
        put("soloSoft", 20_000)
        put("soloSoft2", 25_000)
        for k in 0..<3 { put("burst\(k)", 30_000 + Double(k), burst: "B") }
        put("far0", 40_000, burst: "F")
        put("far1", 47_000, burst: "F")
        lib.add(Make.meta("shot", kind: .screenshot, date: at(50_000)), preview: .local(image))
        lib.add(
            Make.meta("clip", kind: .video, date: at(51_000), duration: 12), preview: .local(image))
        return lib
    }

    func scanner(
        _ lib: FakePhotoLibrary, _ store: any Store, log: TieredScanTests.RequestLog, tiered: Bool
    ) -> ScanPipeline {
        ScanPipeline(
            library: lib, store: store, analyzer: log, concurrency: 2, chunkSize: 4,
            progressEvery: 1, policy: fast, tiered: tiered, deepWait: { nil })
    }

    func newLog() -> TieredScanTests.RequestLog {
        TieredScanTests.RequestLog(sharpness: Self.softOnes)
    }

    /// A full scan, run to the end of its stream. The pipeline is held until then: the scan's task
    /// holds the pipeline weakly, so one that nothing else holds is gone before its scan starts and
    /// the stream ends empty.
    func fullScan(
        _ lib: FakePhotoLibrary, _ store: any Store, log: TieredScanTests.RequestLog, tiered: Bool
    ) async -> [ScanProgress] {
        let pipeline = scanner(lib, store, log: log, tiered: tiered)
        let events = await drain(await pipeline.startFullScan())
        withExtendedLifetime(pipeline) {}
        return events
    }

    /// What the person does after the app was killed, the way Home leads them: Resume while a job is
    /// unfinished; Scan Library before any scan has finished; otherwise a quick check says whether work
    /// is owed, and Look Deeper does it.
    func carryOn(
        _ lib: FakePhotoLibrary, _ store: SwiftDataStore, log: TieredScanTests.RequestLog,
        tiered: Bool
    ) async throws {
        for _ in 0..<8 {
            let scan = scanner(lib, store, log: log, tiered: tiered)
            let active = try await store.currentSession()?.isActive == true
            let finishedOnce = try await store.sessions().contains {
                $0.kind == .full && $0.state == .completed
            }
            if active || !finishedOnce {
                _ = await drain(await scan.startFullScan())
                withExtendedLifetime(scan) {}
                continue
            }
            let check = await scan.quickCheck()
            guard check.deepRemaining > 0 else { return }
            _ = await drain(await scan.startDeepScan())
            withExtendedLifetime(scan) {}
        }
    }

    /// Everything a detector or a later plan reads of a stored photo, as one line each.
    func snapshot(_ store: SwiftDataStore) async throws -> [String: String] {
        var out: [String: String] = [:]
        for item in try await store.items() {
            let a = item.analysis
            out[item.assetID] =
                "\(item.analysisSource.rawValue)|\(a?.dHash ?? 0)|\(a?.sharpness ?? -1)|"
                + "\(a?.skippedVision.rawValue ?? -1)"
        }
        return out
    }

    func results(_ store: SwiftDataStore) async throws -> CleanupResults {
        try await ResultsLoader(
            store: store, builder: DefaultResultsBuilder(detectors: StandardPipeline.detectors())
        ).load()
    }

    @Test(arguments: [true, false])
    func aKillAtAnyWriteLeavesAScanThatFinishesAsAnUninterruptedOneDoes(tiered: Bool) async throws {
        let lib = library()

        // The reference: nothing dies. It also says how many writes a scan makes.
        let reference = try InMemoryStore.make()
        let counting = DyingStore(reference, limit: .max)
        let events = await fullScan(lib, counting, log: newLog(), tiered: tiered)
        #expect(events.last?.state == .completed)
        let total = counting.writeCount
        // Three chunks make a lease and a checkpoint each, and a job a start and an end: a one-pass scan
        // makes about ten writes, a tiered one about twenty. Fewer would mean the sweep proves little.
        #expect(total >= 8, "a scan of this library makes more writes than \(total)")
        let expected = try await snapshot(reference)
        let expectedResults = try await results(reference)
        #expect(expected.count == 12)

        // Die after every write in turn, and one past the last (nothing lost).
        for limit in 0...(total + 1) {
            let base = try InMemoryStore.make()
            let dying = DyingStore(base, limit: limit)
            _ = await fullScan(lib, dying, log: newLog(), tiered: tiered)

            // What the store held when the process died.
            let summaries = try await base.itemSummaries()
            let analyzedAtDeath = Set(summaries.filter { $0.analysisSource.hasAnalysis }.map(\.assetID))
            let completeAtDeath = Set(
                summaries.filter { $0.analysisSource.hasAnalysis && $0.skippedVision.isEmpty }
                    .map(\.assetID))

            // A new process, a new person's tap, until nothing is left to do.
            let after = newLog()
            try await carryOn(lib, base, log: after, tiered: tiered)

            let label = "tiered \(tiered), died after write \(limit) of \(total)"
            #expect(try await snapshot(base) == expected, "\(label): the stores differ")
            #expect(
                try await results(base).slimmed() == expectedResults.slimmed(),
                "\(label): the results differ")
            let session = try await base.currentSession()
            #expect(session?.isActive != true, "\(label): a job is left unfinished")

            // Work the store held is not done again: a photo whose photo check was saved is not given
            // another (an exact request is a photo check's), and a photo with every pass done is not
            // asked anything.
            for id in analyzedAtDeath {
                #expect(
                    !after.requests(id).contains { $0.contains(.exact) },
                    "\(label): \(id) had its photo check done again")
            }
            for id in completeAtDeath {
                #expect(after.requests(id).isEmpty, "\(label): \(id) was analyzed again")
            }
        }
    }

    @Test func bothModesEndInTheSameStore() async throws {
        let lib = library()
        var snapshots: [Bool: [String: String]] = [:]
        for tiered in [true, false] {
            let store = try InMemoryStore.make()
            _ = await fullScan(lib, store, log: newLog(), tiered: tiered)
            snapshots[tiered] = try await snapshot(store)
        }
        #expect(snapshots[true] == snapshots[false])
        #expect(snapshots[true]?.count == 12)
    }
}
