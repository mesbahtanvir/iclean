import CoreGraphics
import Foundation
import Testing

@testable import CleanupKit

/// 003: a scan is a durable job of chunks that survives crashes, retries failures,
/// isolates poison items, and resumes without a full re-diff.
@Suite struct DurableScanTests {
    let image = TestImages.scene(seed: 3, width: 64, height: 48)
    /// Fast retries so tests finish quickly.
    let fast = ScanRetryPolicy(
        chunkSize: 32, maxAttempts: 3, backoff: [.milliseconds(5), .milliseconds(10)],
        itemTimeout: .milliseconds(80), crashBudget: 5, crossScanAttempts: 6)

    func library(count: Int, prefix: String = "p") -> FakePhotoLibrary {
        let lib = FakePhotoLibrary()
        for i in 0..<count { lib.add(Make.meta("\(prefix)\(i)"), preview: .local(image)) }
        return lib
    }

    func drain(_ stream: AsyncStream<ScanProgress>) async -> [ScanProgress] {
        var all: [ScanProgress] = []
        for await p in stream { all.append(p) }
        return all
    }

    // MARK: Planning

    @Test func chunksFollowLibraryOrderAndSize() {
        let ids = (0..<70).map { "a\($0)" }
        let chunks = ScanPlanner.chunks(jobID: UUID(), assetIDs: ids, size: 32)
        #expect(chunks.map(\.assetIDs.count) == [32, 32, 6])
        #expect(chunks.map(\.sequence) == [0, 1, 2])
        #expect(chunks[1].assetIDs.first == "a32")
        #expect(Set(chunks.map(\.id)).count == 3)
    }

    // MARK: Crash and resume

    /// Simulates an app that died with chunk 1 in flight: chunk 0 done, chunk 1 running
    /// under another process with 5 items finished, chunk 2 pending.
    func seedCrashedJob(
        store: SwiftDataStore, lib: FakePhotoLibrary, isolate: Bool = false, suspect: Int? = nil,
        inFlight: Int? = nil, crashCount: Int = 0
    )
        async throws -> ScanSession
    {
        let ids = lib.allIDs
        let session = ScanSession(
            kind: .full, state: .running, totalItems: ids.count, processedItems: 37,
            crashCount: crashCount)
        var chunks = ScanPlanner.chunks(jobID: session.id, assetIDs: ids, size: 32)
        chunks[0].state = .done
        chunks[0].doneMask = .max
        chunks[1].state = .running
        chunks[1].owner = UUID()
        chunks[1].isolate = isolate
        chunks[1].suspectIndex = suspect
        chunks[1].inFlightIndex = inFlight
        for i in 0..<5 { chunks[1].markDone(i) }
        try await store.createJob(session, chunks: chunks)
        try await store.upsert((ids[0..<32] + ids[32..<37]).map { Make.item(Make.meta($0)) })
        return session
    }

    @Test func crashLosesOnlyTheChunkInFlight() async throws {
        let lib = library(count: 70)
        let store = try InMemoryStore.make()
        let seeded = try await seedCrashedJob(store: store, lib: lib)
        let scanner = ScanPipeline(
            library: lib, store: store, analyzer: StubAnalyzer(), policy: fast)
        let events = await drain(await scanner.startFullScan())
        #expect(events.first?.processed == 37)
        #expect(events.last?.state == .completed)
        #expect(events.last?.processed == 70)
        #expect(lib.previewRequests.count == 70 - 37)
        #expect(try await store.items().count == 70)
        let final = try await store.currentSession()
        #expect(final?.id == seeded.id)
        #expect(final?.crashCount == 1)
        #expect(try await store.chunks(job: seeded.id).isEmpty)
    }

    @Test func resumeAfterPauseDoesNotRediffTheLibrary() async throws {
        let lib = library(count: 70)
        let store = try InMemoryStore.make()
        // A paused job: chunk 1 released (pending, owner nil) with 5 items finished.
        let ids = lib.allIDs
        let session = ScanSession(kind: .full, state: .paused, totalItems: 70, processedItems: 37)
        var chunks = ScanPlanner.chunks(jobID: session.id, assetIDs: ids, size: 32)
        chunks[0].state = .done
        chunks[0].doneMask = .max
        for i in 0..<5 { chunks[1].markDone(i) }
        try await store.createJob(session, chunks: chunks)
        try await store.upsert((ids[0..<37]).map { Make.item(Make.meta($0)) })
        let scanner = ScanPipeline(
            library: lib, store: store, analyzer: StubAnalyzer(), policy: fast)
        let events = await drain(await scanner.startFullScan())
        // Analysis restarts without enumerating the library; the one diff that picks up
        // photos added meanwhile runs after the last chunk.
        #expect(lib.fetchAllItemsCallsAtFirstPreview == 0)
        #expect(lib.fetchAllItemsCalls == 1)
        #expect(events.last?.state == .completed)
        #expect(try await store.currentSession()?.crashCount == 0)
        #expect(try await store.currentSession()?.interruptedCount == 0)
    }

    @Test func progressNeverDecreasesAcrossResume() async throws {
        let lib = library(count: 30)
        lib.previewDelay = .milliseconds(3)
        let store = try InMemoryStore.make()
        let first = ScanPipeline(
            library: lib, store: store, analyzer: StubAnalyzer(), concurrency: 2, chunkSize: 8,
            progressEvery: 1, policy: fast)
        var pausedAt = 0
        for await p in await first.startFullScan() {
            if p.state == .running, p.processed >= 10, pausedAt == 0 {
                await first.pause(reason: .user)
                pausedAt = p.processed
                break
            }
        }
        #expect(pausedAt >= 10)
        // A new process resumes the same job.
        let second = ScanPipeline(
            library: lib, store: store, analyzer: StubAnalyzer(), policy: fast)
        let events = await drain(await second.startFullScan())
        #expect((events.first?.processed ?? 0) >= pausedAt)
        for (a, b) in zip(events, events.dropFirst()) { #expect(b.processed >= a.processed) }
        #expect(events.last?.processed == 30)
    }

    @Test func itemsAddedDuringAnInterruptionAreCaughtUp() async throws {
        let lib = library(count: 70)
        let store = try InMemoryStore.make()
        _ = try await seedCrashedJob(store: store, lib: lib)
        lib.add(Make.meta("late"), preview: .local(image))
        let scanner = ScanPipeline(
            library: lib, store: store, analyzer: StubAnalyzer(), policy: fast)
        let events = await drain(await scanner.startFullScan())
        #expect(events.last?.state == .completed)
        #expect(events.last?.total == 71)
        #expect(try await store.items().contains { $0.assetID == "late" })
    }

    // MARK: Reclaim rules (pure)

    func chunk(
        isolate: Bool = false, suspect: Int? = nil, inFlight: Int? = nil, done: Int = 2
    ) -> ScanChunk {
        var c = ScanChunk(
            jobID: UUID(), sequence: 0, assetIDs: (0..<8).map { "x\($0)" }, state: .running,
            isolate: isolate, suspectIndex: suspect, inFlightIndex: inFlight, owner: UUID())
        for i in 0..<done { c.markDone(i) }
        return c
    }

    @Test func reclaimIsolatesThenSuspectsThenPoisons() {
        let policy = ScanRetryPolicy()
        let session = ScanSession(kind: .full, state: .running, totalItems: 8)
        let r1 = ScanReclaim.reclaim([chunk()], session: session, owner: UUID(), policy: policy)
        #expect(r1.chunks[0].isolate && r1.chunks[0].suspectIndex == nil)
        #expect(r1.chunks[0].state == .pending && r1.chunks[0].owner == nil)
        #expect(r1.session.crashCount == 1 && r1.sawCrash)
        let r2 = ScanReclaim.reclaim(
            [chunk(isolate: true, inFlight: 2)], session: session, owner: UUID(), policy: policy)
        #expect(r2.chunks[0].suspectIndex == 2)
        #expect(r2.poisoned.isEmpty)
        let r3 = ScanReclaim.reclaim(
            [chunk(isolate: true, suspect: 2, inFlight: 2)], session: session, owner: UUID(),
            policy: policy)
        #expect(r3.poisoned == ["x2"])
        #expect(r3.chunks[0].isDone(2) && r3.chunks[0].suspectIndex == nil)
        #expect(r3.session.failedItems == 1)
        let r4 = ScanReclaim.reclaim(
            [chunk(isolate: true, suspect: 1, inFlight: 2)], session: session, owner: UUID(),
            policy: policy)
        #expect(r4.chunks[0].suspectIndex == 2 && r4.poisoned.isEmpty)
    }

    /// Review fix: the first item left over is not necessarily the one that was running.
    /// Item 0 only failed earlier; the app died on item 3.
    @Test func reclaimBlamesTheItemInFlightNotAnEarlierFailure() {
        let session = ScanSession(kind: .full, state: .running, totalItems: 8)
        let first = ScanReclaim.reclaim(
            [chunk(isolate: true, inFlight: 3, done: 0)], session: session, owner: UUID(),
            policy: ScanRetryPolicy())
        #expect(first.chunks[0].suspectIndex == 3)
        #expect(first.poisoned.isEmpty)
        let second = ScanReclaim.reclaim(
            [chunk(isolate: true, suspect: 3, inFlight: 3, done: 0)], session: session,
            owner: UUID(), policy: ScanRetryPolicy())
        #expect(second.poisoned == ["x3"])
        #expect(!second.chunks[0].isDone(0))
    }

    @Test func reclaimBlamesNobodyWhenNothingWasInFlight() {
        let session = ScanSession(kind: .full, state: .running, totalItems: 8)
        let r = ScanReclaim.reclaim(
            [chunk(isolate: true, suspect: 2, done: 2)], session: session, owner: UUID(),
            policy: ScanRetryPolicy())
        #expect(r.poisoned.isEmpty)
        #expect(r.chunks[0].suspectIndex == 2)
        #expect(r.session.crashCount == 1)
    }

    @Test func reclaimLeavesReleasedChunksAlone() {
        var released = chunk()
        released.state = .pending
        released.owner = nil
        let r = ScanReclaim.reclaim(
            [released], session: ScanSession(kind: .full, state: .paused), owner: UUID(),
            policy: ScanRetryPolicy())
        #expect(!r.sawCrash && r.session.crashCount == 0 && !r.chunks[0].isolate)
    }

    @Test func crashBudgetStopsTheJob() {
        let session = ScanSession(kind: .full, state: .running, crashCount: 4)
        let r = ScanReclaim.reclaim(
            [chunk()], session: session, owner: UUID(), policy: ScanRetryPolicy(crashBudget: 5))
        #expect(r.session.state == .stopped)
    }

    @Test func poisonedItemIsSkippedAndCounted() async throws {
        let lib = library(count: 70)
        let store = try InMemoryStore.make()
        // Isolate mode, suspect is the first undone item: the app died on it twice.
        _ = try await seedCrashedJob(
            store: store, lib: lib, isolate: true, suspect: 5, inFlight: 5)
        let scanner = ScanPipeline(
            library: lib, store: store, analyzer: StubAnalyzer(), policy: fast)
        let events = await drain(await scanner.startFullScan())
        #expect(events.last?.state == .completed)
        #expect(events.last?.failed == 1)
        let poisoned = try await store.items().first { $0.assetID == "p37" }
        #expect(poisoned?.scanFailure == .crashed)
        #expect(poisoned?.analysisSource == .notScanned)
        #expect(!lib.previewRequests.contains("p37"))
        #expect(try await store.items().count == 70)
    }

    // MARK: Retries, timeouts, give-up

    @Test func transientFailuresAreRetriedWithoutLoss() async throws {
        let lib = library(count: 10)
        let store = try InMemoryStore.make()
        let flaky = FlakyAnalyzer(failuresPerItem: 2)
        let scanner = ScanPipeline(
            library: lib, store: store, analyzer: flaky, chunkSize: 4, policy: fast)
        let events = await drain(await scanner.startFullScan())
        #expect(events.last?.state == .completed)
        #expect(events.last?.failed == 0)
        #expect(try await store.items().allSatisfy { $0.analysis != nil })
        #expect(flaky.callCount("p0") == 3)
    }

    @Test func itemThatAlwaysFailsIsGivenUpOnAndTheRestFinishes() async throws {
        let lib = library(count: 10)
        let store = try InMemoryStore.make()
        let flaky = FlakyAnalyzer(alwaysFail: ["p3"])
        let scanner = ScanPipeline(
            library: lib, store: store, analyzer: flaky, chunkSize: 4, policy: fast)
        let events = await drain(await scanner.startFullScan())
        #expect(events.last?.state == .completed)
        #expect(events.last?.failed == 1)
        #expect(events.last?.notScanned == 1)
        #expect(events.last?.processed == 10)
        let bad = try await store.items().first { $0.assetID == "p3" }
        #expect(bad?.scanFailure == .transient)
        #expect(bad?.scanAttempts == 1)
        #expect(flaky.callCount("p3") == 3)
        #expect(try await store.items().filter { $0.analysis != nil }.count == 9)
    }

    @Test func hungPreviewTimesOutInsteadOfStallingTheScan() async throws {
        let lib = library(count: 6)
        lib.hangIDs = ["p2"]
        let store = try InMemoryStore.make()
        let scanner = ScanPipeline(
            library: lib, store: store, analyzer: StubAnalyzer(), chunkSize: 3, policy: fast)
        let clock = ContinuousClock()
        let start = clock.now
        let events = await drain(await scanner.startFullScan())
        // Without the per-item limit this never finishes; the bound leaves room for load.
        #expect(clock.now - start < .seconds(10))
        #expect(events.last?.state == .completed)
        let hung = try await store.items().first { $0.assetID == "p2" }
        #expect(hung?.scanFailure == .timeout)
        #expect(try await store.items().count == 6)
    }

    @Test func givenUpItemsAreRetriedOnLaterFullScansUpToALimit() async throws {
        let lib = library(count: 3)
        let store = try InMemoryStore.make()
        let flaky = FlakyAnalyzer(alwaysFail: ["p1"])
        let policy = ScanRetryPolicy(
            maxAttempts: 1, backoff: [.milliseconds(1)], itemTimeout: .seconds(5),
            crossScanAttempts: 2)
        let scanner = ScanPipeline(library: lib, store: store, analyzer: flaky, policy: policy)
        _ = await drain(await scanner.startFullScan())
        #expect(try await store.items().first { $0.assetID == "p1" }?.scanAttempts == 1)
        _ = await drain(await scanner.startFullScan())
        #expect(try await store.items().first { $0.assetID == "p1" }?.scanAttempts == 2)
        let calls = flaky.callCount("p1")
        _ = await drain(await scanner.startFullScan())
        // The limit was reached: no further attempt.
        #expect(flaky.callCount("p1") == calls)
    }

    @Test func pauseReleasesTheChunkBeforeWaiting() async throws {
        let lib = library(count: 20)
        lib.previewDelay = .milliseconds(3)
        let store = try InMemoryStore.make()
        let scanner = ScanPipeline(
            library: lib, store: store, analyzer: StubAnalyzer(), concurrency: 2, chunkSize: 8,
            progressEvery: 1, policy: fast)
        var checked = false
        for await p in await scanner.startFullScan() {
            if p.state == .running, p.processed >= 3, !checked {
                checked = true
                await scanner.pause(reason: .user)
                let session = try await store.currentSession()
                #expect(session?.state == .paused)
                let chunks = try await store.chunks(job: session!.id)
                #expect(chunks.allSatisfy { $0.state != .running && $0.owner == nil })
                #expect(try await store.items().count == session?.processedItems)
                await scanner.resume()
            }
        }
        #expect(checked)
        #expect(try await store.items().count == 20)
    }

    /// Review fix: a pause asked for during a heat wait used to emit nothing, so the
    /// screen kept the cool-down text with no Resume button.
    @Test func pausingDuringAHeatPauseIsReportedAndAcknowledged() async throws {
        let lib = library(count: 6)
        let hot = HotFlag()
        hot.value = true
        let store = try InMemoryStore.make()
        // The wait limit is far above anything a loaded machine can cause, so the test
        // never races it: it counts how pause() returned instead of timing it.
        let scanner = ScanPipeline(
            library: lib, store: store, analyzer: StubAnalyzer(), chunkSize: 3, policy: fast,
            pauseWaitLimit: .seconds(20),
            thermalState: { hot.value ? .serious : .nominal })
        var sawThermal = false
        var pausedEvent: ScanProgress?
        for await p in await scanner.startFullScan() {
            if p.isThermalPaused, !sawThermal {
                sawThermal = true
                await scanner.pause(reason: .user)
                hot.value = false
                // Safety net: a regression must fail this test, not hang the suite.
                Task {
                    try? await Task.sleep(for: .seconds(30))
                    await scanner.resume()
                }
            } else if p.state == .paused, pausedEvent == nil {
                pausedEvent = p
                await scanner.resume()
            }
        }
        #expect(sawThermal)
        // Unacknowledged, pause() runs out its wait limit (or is cut short by a resume)
        // and does not count; acknowledged, the run loop reported the pause as saved.
        #expect(await scanner.pauseAcknowledgements == 1)
        #expect(pausedEvent?.pauseReason == .user)
        #expect(pausedEvent?.isThermalPaused == false)
        #expect(try await store.items().count == 6)
        #expect(try await store.currentSession()?.state == .completed)
    }

    /// Review fix: `pause()` used to save in-memory counters that were ahead of the saved
    /// results, and left the chunk leased. After a kill during the drain the count
    /// exceeded the results and the chunk was mistaken for a crash.
    @Test func pauseWhileItemsAreInFlightSavesOnlyWhatIsStoredAndReleasesTheChunk() async throws {
        let lib = library(count: 8)
        for i in 4..<8 { lib.slowIDs["p\(i)"] = .milliseconds(2600) }
        let store = try InMemoryStore.make()
        let policy = ScanRetryPolicy(
            chunkSize: 8, maxAttempts: 3, backoff: [.milliseconds(5)], itemTimeout: .seconds(10),
            crashBudget: 5, crossScanAttempts: 6)
        let scanner = ScanPipeline(
            library: lib, store: store, analyzer: StubAnalyzer(), concurrency: 4, chunkSize: 8,
            progressEvery: 1, policy: policy)
        var checked = false
        for await p in await scanner.startFullScan() {
            if !checked, p.state == .running, p.processed >= 4 {
                checked = true
                // Returns after its 2 s limit, with the four slow items still in flight.
                await scanner.pause(reason: .backgroundLimit)
                let session = try #require(try await store.currentSession())
                let stored = try await store.items().count
                #expect(session.state == .paused)
                #expect(session.processedItems <= stored)
                let chunks = try await store.chunks(job: session.id)
                #expect(chunks.allSatisfy { $0.state != .running && $0.owner == nil })
                await scanner.resume()
            }
        }
        #expect(checked)
        #expect(try await store.items().count == 8)
        #expect(try await store.currentSession()?.state == .completed)
    }

    @Test func aPauseTheUserAskedForIsNotTurnedIntoAnAutomaticOne() async throws {
        let lib = library(count: 20)
        lib.previewDelay = .milliseconds(3)
        let store = try InMemoryStore.make()
        let scanner = ScanPipeline(
            library: lib, store: store, analyzer: StubAnalyzer(), concurrency: 2, chunkSize: 8,
            progressEvery: 1, policy: fast)
        var checked = false
        var pausedReasons: [ScanPauseReason?] = []
        for await p in await scanner.startFullScan() {
            if p.state == .paused { pausedReasons.append(p.pauseReason) }
            if !checked, p.state == .running, p.processed >= 3 {
                checked = true
                await scanner.pause(reason: .user)
                // The grace period running out afterwards must not change why it paused.
                await scanner.pause(reason: .backgroundLimit)
                // Long enough for the wait loop to report any change of reason.
                try? await Task.sleep(for: .milliseconds(700))
                await scanner.resume()
            }
        }
        #expect(checked)
        #expect(!pausedReasons.isEmpty)
        #expect(pausedReasons.allSatisfy { $0 == .user })
        #expect(try await store.items().count == 20)
    }

    @Test func deletedItemsInAPendingChunkAreSkippedSilently() async throws {
        let lib = library(count: 5)
        let store = try InMemoryStore.make()
        let session = ScanSession(kind: .full, state: .paused, totalItems: 6)
        let chunks = ScanPlanner.chunks(
            jobID: session.id, assetIDs: lib.allIDs + ["gone"], size: 32)
        try await store.createJob(session, chunks: chunks)
        let scanner = ScanPipeline(
            library: lib, store: store, analyzer: StubAnalyzer(), policy: fast)
        let events = await drain(await scanner.startFullScan())
        #expect(events.last?.state == .completed)
        #expect(events.last?.notScanned == 0)
        #expect(events.last?.failed == 0)
        #expect(try await store.items().count == 5)
        // The deleted item leaves the job: a completed scan reads 5 of 5, not 5 of 6.
        #expect(events.last?.processed == 5)
        #expect(events.last?.total == 5)
    }

    @Test func quickCheckDoesNotTouchAnUnfinishedJob() async throws {
        let lib = library(count: 5)
        let store = try InMemoryStore.make()
        let session = ScanSession(kind: .full, state: .paused, totalItems: 5, processedItems: 2)
        try await store.createJob(
            session, chunks: ScanPlanner.chunks(jobID: session.id, assetIDs: lib.allIDs, size: 32))
        let scanner = ScanPipeline(
            library: lib, store: store, analyzer: StubAnalyzer(), policy: fast)
        let progress = await scanner.quickCheck()
        #expect(progress.state == .paused)
        #expect(progress.processed == 2)
        #expect(lib.previewRequests.isEmpty)
    }

    // MARK: Store

    @Test func chunksRoundTripAndDeleteWithTheJob() async throws {
        let store = try InMemoryStore.make()
        let session = ScanSession(kind: .full, state: .running, totalItems: 3)
        var chunk = ScanChunk(jobID: session.id, sequence: 0, assetIDs: ["a", "b", "c"])
        chunk.markDone(1)
        chunk.attempts = 2
        chunk.isolate = true
        chunk.suspectIndex = 0
        chunk.notBefore = Date(timeIntervalSince1970: 5)
        chunk.lastError = "timeout"
        try await store.createJob(session, chunks: [chunk])
        let back = try await store.chunks(job: session.id)
        #expect(back == [chunk])
        try await store.deleteChunks(job: session.id)
        #expect(try await store.chunks(job: session.id).isEmpty)
        try await store.createJob(session, chunks: [chunk])
        try await store.deleteAllData()
        #expect(try await store.chunks(job: session.id).isEmpty)
    }

    @Test func sessionsAreListedNewestFirst() async throws {
        let store = try InMemoryStore.make()
        try await store.saveSession(
            ScanSession(kind: .full, state: .completed, startedAt: Date(timeIntervalSince1970: 1)))
        try await store.saveSession(
            ScanSession(kind: .full, state: .completed, startedAt: Date(timeIntervalSince1970: 2)))
        let sessions = try await store.sessions()
        #expect(sessions.map(\.startedAt.timeIntervalSince1970) == [2, 1])
    }

    // MARK: Review fixes (second round)

    /// Review fix: heat that clears while a chunk is draining used to mark the chunk done
    /// with items that were never started. The flicker is replayed at every call so the
    /// result does not depend on how many times the pipeline reads the thermal state.
    @Test func aHeatFlickerAtAnyPointNeverSkipsItems() async throws {
        for n in 1...10 {
            let lib = library(count: 5)
            let store = try InMemoryStore.make()
            let flicker = FlickerThermal(hotOnCall: n)
            let scanner = ScanPipeline(
                library: lib, store: store, analyzer: StubAnalyzer(), chunkSize: 5, policy: fast,
                thermalState: { flicker.state() })
            let events = await drain(await scanner.startFullScan())
            #expect(try await store.items().count == 5, "heat on call \(n)")
            #expect(events.last?.state == .completed, "heat on call \(n)")
            #expect(events.last?.processed == events.last?.total, "heat on call \(n)")
        }
    }

    /// Review fix: the crash budget used to end the job without recording the item that
    /// had just been set aside.
    @Test func theCrashBudgetStillRecordsTheItemItSetAside() async throws {
        let lib = library(count: 70)
        let store = try InMemoryStore.make()
        let seeded = try await seedCrashedJob(
            store: store, lib: lib, isolate: true, suspect: 5, inFlight: 5, crashCount: 4)
        let scanner = ScanPipeline(
            library: lib, store: store, analyzer: StubAnalyzer(), policy: fast)
        let events = await drain(await scanner.startFullScan())
        #expect(events.last?.state == .stopped)
        let poisoned = try await store.items().first { $0.assetID == "p37" }
        #expect(poisoned?.scanFailure == .crashed)
        #expect(try await store.chunks(job: seeded.id).isEmpty)
        #expect(lib.previewRequests.isEmpty)
    }

    /// Review fix: catch-up used to run only after a crash, so a job that was paused and
    /// then resumed in a new process skipped photos added meanwhile.
    @Test func itemsAddedWhileAJobWasPausedAreCaughtUp() async throws {
        let lib = library(count: 70)
        let store = try InMemoryStore.make()
        let ids = lib.allIDs
        let session = ScanSession(kind: .full, state: .paused, totalItems: 70, processedItems: 32)
        var chunks = ScanPlanner.chunks(jobID: session.id, assetIDs: ids, size: 32)
        chunks[0].state = .done
        chunks[0].doneMask = .max
        try await store.createJob(session, chunks: chunks)
        try await store.upsert(ids[0..<32].map { Make.item(Make.meta($0)) })
        lib.add(Make.meta("late"), preview: .local(image))
        let scanner = ScanPipeline(
            library: lib, store: store, analyzer: StubAnalyzer(), policy: fast)
        let events = await drain(await scanner.startFullScan())
        #expect(events.last?.state == .completed)
        #expect(events.last?.total == 71)
        #expect(try await store.items().contains { $0.assetID == "late" })
        #expect(try await store.items().count == 71)
    }

    /// Review fix: catch-up used to skip every item that belonged to a chunk, so an item
    /// edited after its chunk finished kept its stale analysis.
    @Test func itemsChangedAfterTheirChunkFinishedAreAnalyzedAgain() async throws {
        let lib = library(count: 70)
        let store = try InMemoryStore.make()
        _ = try await seedCrashedJob(store: store, lib: lib)
        let changed = Date(timeIntervalSince1970: 99)
        lib.update("p3") { $0.modificationDate = changed }
        let scanner = ScanPipeline(
            library: lib, store: store, analyzer: StubAnalyzer(), policy: fast)
        _ = await drain(await scanner.startFullScan())
        #expect(
            try await store.items().first { $0.assetID == "p3" }?.metadata.modificationDate
                == changed)
    }

    /// Review fix: a full scan started while a quick check was reading the store used to
    /// run alongside it on the same job.
    @Test func aQuickCheckAndAFullScanNeverRunTogether() async throws {
        for _ in 0..<15 {
            let lib = library(count: 6)
            let store = try InMemoryStore.make()
            let scanner = ScanPipeline(
                library: lib, store: store, analyzer: StubAnalyzer(), chunkSize: 3, policy: fast)
            async let quick = scanner.quickCheck()
            _ = await drain(await scanner.startFullScan())
            _ = await quick
            let session = try await store.currentSession()
            #expect(try await store.items().count == 6)
            #expect(session?.crashCount == 0)
            #expect(session?.state == .completed)
            #expect(try await store.chunks(job: session!.id).isEmpty)
        }
    }

    /// Review fix: the stream used to end before the run slot was freed, so a scan started
    /// right after the last event was refused.
    @Test func aScanCanStartRightAfterTheLastOneEnds() async throws {
        let lib = library(count: 3)
        let store = try InMemoryStore.make()
        let scanner = ScanPipeline(
            library: lib, store: store, analyzer: StubAnalyzer(), policy: fast)
        _ = await drain(await scanner.startFullScan())
        let again = await drain(await scanner.startFullScan())
        #expect(again.last?.state == .completed)
    }

    /// Review fix: a failed checkpoint used to leave its half-written changes in the
    /// context, to be committed by the next successful save.
    @Test func aFailedCheckpointLeavesNothingBehind() async throws {
        let store = try InMemoryStore.make()
        try await store.saveSession(ScanSession(kind: .full, state: .running))
        let other = ScanSession(kind: .full, state: .running)
        let chunk = ScanChunk(jobID: other.id, sequence: 0, assetIDs: ["a"])
        await #expect(throws: StoreError.anotherSessionActive) {
            try await store.checkpoint(
                items: [Make.item(Make.meta("a"))], chunk: chunk, session: other)
        }
        #expect(try await store.items().isEmpty)
        #expect(try await store.chunks(job: other.id).isEmpty)
        try await store.upsert([Make.item(Make.meta("b"))])
        #expect(try await store.items().map(\.assetID) == ["b"])
        #expect(try await store.chunks(job: other.id).isEmpty)
    }

    /// Review fix: ending a job used to be two saves, and a kill between them left an
    /// active session with no chunks, which the next launch mistook for an old-style scan.
    @Test func endingASessionRemovesItsChunksInTheSameSave() async throws {
        let store = try InMemoryStore.make()
        var session = ScanSession(kind: .full, state: .running, totalItems: 3)
        try await store.createJob(
            session, chunks: [ScanChunk(jobID: session.id, sequence: 0, assetIDs: ["a", "b", "c"])])
        #expect(try await store.chunks(job: session.id).count == 1)
        session.state = .completed
        try await store.saveSession(session)
        #expect(try await store.chunks(job: session.id).isEmpty)
    }
}

/// Reports a high temperature on exactly one call to the thermal state.
final class FlickerThermal: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    let hotOnCall: Int

    init(hotOnCall: Int) { self.hotOnCall = hotOnCall }

    func state() -> ProcessInfo.ThermalState {
        lock.withLock {
            calls += 1
            return calls == hotOnCall ? .serious : .nominal
        }
    }
}
