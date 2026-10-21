import CoreGraphics
import Foundation
import Testing

@testable import CleanupKit

/// A scan whose results cannot be saved stops and says so, instead of going on and losing them
/// (specs/007-persistent-session).
@Suite struct StorageFailureScanTests {
    let image = TestImages.scene(seed: 3, width: 64, height: 48)
    let fast = ScanRetryPolicy(
        chunkSize: 32, maxAttempts: 3, backoff: [.milliseconds(5), .milliseconds(10)],
        itemTimeout: .milliseconds(80), crashBudget: 5, crossScanAttempts: 6)

    func library(count: Int) -> FakePhotoLibrary {
        let lib = FakePhotoLibrary()
        for i in 0..<count { lib.add(Make.meta("s\(i)"), preview: .local(image)) }
        return lib
    }

    @Test func threeFailedSavesInARowPauseTheScanAndResumeSavesEverything() async throws {
        let lib = library(count: 15)
        let store = try InMemoryStore.make()
        let scanner = ScanPipeline(
            library: lib, store: store, analyzer: StubAnalyzer(), chunkSize: 3, policy: fast)
        // Every write fails from here on, as on a full disk.
        await store.failNextWritesForTesting(10_000)
        var pausedEvent: ScanProgress?
        var last: ScanProgress?
        for await p in await scanner.startFullScan() {
            last = p
            if p.state == .paused, pausedEvent == nil {
                pausedEvent = p
                // The disk has room again; the person taps Resume.
                await store.failNextWritesForTesting(0)
                await scanner.resume()
            }
        }
        #expect(pausedEvent?.pauseReason == .storageUnavailable)
        #expect((pausedEvent?.processed ?? 99) < 15, "It stopped, it did not run to the end")
        #expect(last?.state == .completed)
        // The chunks that could not be saved while the disk was full are saved after Resume.
        #expect(try await store.items().count == 15)
    }

    @Test func aSingleFailedCheckpointDoesNotPauseAndItsPhotosAreSavedWithTheNextOne() async throws
    {
        let lib = library(count: 15)
        let store = try InMemoryStore.make()
        let scanner = ScanPipeline(
            library: lib, store: store, analyzer: StubAnalyzer(), chunkSize: 3, policy: fast)
        // Only the first chunk's checkpoint fails.
        await store.failNextCheckpointsForTesting(1)
        var sawPause = false
        var last: ScanProgress?
        for await p in await scanner.startFullScan() {
            if p.state == .paused { sawPause = true }
            last = p
        }
        #expect(!sawPause)
        #expect(last?.state == .completed)
        #expect(
            try await store.items().count == 15, "the chunk that failed is saved with the next one")
        // Counted once: the photos carried to the next checkpoint are not analyzed or counted again.
        #expect(last?.processed == 15)
        #expect(last?.total == 15)
    }

    @Test func aCheckpointWritesEveryChunkItCarriesInOneTransaction() async throws {
        let store = try InMemoryStore.make()
        let session = ScanSession(kind: .full, state: .running, totalItems: 6)
        var chunks = ScanPlanner.chunks(
            jobID: session.id, assetIDs: (0..<6).map { "c\($0)" }, size: 3)
        try await store.createJob(session, chunks: chunks)
        chunks[0].state = .done
        chunks[1].state = .done
        try await store.checkpoint(
            items: (0..<6).map { Make.item(Make.meta("c\($0)")) }, chunks: chunks, session: session)
        let stored = try await store.chunks(job: session.id)
        #expect(stored.map(\.state) == [.done, .done])
        #expect(try await store.items().count == 6)
    }

    @Test func aScanIsNeverCompleteWhileResultsAreUnsaved() async throws {
        // Two chunks, both fail to save: fewer than three in a row, yet the scan must not finish
        // as completed. It asks for help at the end and saves after Resume.
        let lib = library(count: 6)
        let store = try InMemoryStore.make()
        let scanner = ScanPipeline(
            library: lib, store: store, analyzer: StubAnalyzer(), chunkSize: 3, policy: fast)
        await store.failNextWritesForTesting(10_000)
        var reasons: [ScanPauseReason?] = []
        var last: ScanProgress?
        for await p in await scanner.startFullScan() {
            last = p
            if p.state == .paused {
                reasons.append(p.pauseReason)
                await store.failNextWritesForTesting(0)
                await scanner.resume()
            }
        }
        #expect(reasons.first == .storageUnavailable)
        #expect(last?.state == .completed)
        #expect(try await store.items().count == 6)
    }

    @Test func anAutomaticPauseNeverReplacesAStorageProblem() async throws {
        let lib = library(count: 15)
        let store = try InMemoryStore.make()
        let scanner = ScanPipeline(
            library: lib, store: store, analyzer: StubAnalyzer(), chunkSize: 3, policy: fast)
        await store.failNextWritesForTesting(10_000)
        var checked = false
        for await p in await scanner.startFullScan() {
            if p.state == .paused, !checked {
                checked = true
                #expect(await scanner.pauseReason == .storageUnavailable)
                // The app leaves the foreground while the scan waits for storage.
                await scanner.pause(reason: .backgroundLimit)
                #expect(await scanner.pauseReason == .storageUnavailable)
                await store.failNextWritesForTesting(0)
                await scanner.resume()
            }
        }
        #expect(checked)
    }

    @Test func aQuickCheckThatCannotSaveEndsInsteadOfWaitingForNobody() async throws {
        let lib = library(count: 15)
        let store = try InMemoryStore.make()
        let scanner = ScanPipeline(
            library: lib, store: store, analyzer: StubAnalyzer(), chunkSize: 3, policy: fast)
        await store.failNextWritesForTesting(10_000)
        // A hang here would hang the suite, so the quick check races a timeout.
        let finished = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                _ = await scanner.quickCheck(); return true
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(30)); return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(finished, "a quick check has nobody to resume it, so it must end by itself")
        // The scanner is free again, and the photos it could not save are scanned next time.
        await store.failNextWritesForTesting(0)
        let events = await drain(await scanner.startFullScan())
        #expect(events.last?.state == .completed)
        #expect(try await store.items().count == 15)
    }

    func drain(_ stream: AsyncStream<ScanProgress>) async -> [ScanProgress] {
        var all: [ScanProgress] = []
        for await p in stream { all.append(p) }
        return all
    }
}
