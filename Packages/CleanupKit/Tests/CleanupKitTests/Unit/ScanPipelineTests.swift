import CoreGraphics
import Foundation
import Testing

@testable import CleanupKit

@Suite struct ScanPipelineTests {
    let image = TestImages.scene(seed: 3, width: 64, height: 48)

    func library(count: Int) -> FakePhotoLibrary {
        let lib = FakePhotoLibrary()
        for i in 0..<count {
            lib.add(Make.meta("p\(i)"), preview: .local(image))
        }
        return lib
    }

    func drain(_ stream: AsyncStream<ScanProgress>) async -> ScanProgress? {
        var last: ScanProgress?
        for await p in stream { last = p }
        return last
    }

    @Test func fullScanAnalyzesEverything() async throws {
        let lib = library(count: 10)
        let store = try InMemoryStore.make()
        let scanner = ScanPipeline(
            library: lib, store: store, analyzer: StubAnalyzer(), chunkSize: 3)
        let last = await drain(await scanner.startFullScan())
        #expect(last?.state == .completed)
        #expect(last?.processed == 10)
        #expect(try await store.items().count == 10)
        #expect(try await store.currentSession()?.state == .completed)
    }

    @Test func incrementalScanOnlyAnalyzesChangedItems() async throws {
        let lib = library(count: 5)
        let store = try InMemoryStore.make()
        let scanner = ScanPipeline(library: lib, store: store, analyzer: StubAnalyzer())
        _ = await drain(await scanner.startFullScan())
        lib.update("p2") { $0.modificationDate = Date(timeIntervalSince1970: 99) }
        lib.add(Make.meta("new"), preview: .local(image))
        let progress = await scanner.quickCheck()
        #expect(progress.total == 2)
        #expect(progress.processed == 2)
    }

    @Test func metadataChangesAreRefreshedWithoutReanalysis() async throws {
        let lib = library(count: 2)
        let store = try InMemoryStore.make()
        let scanner = ScanPipeline(library: lib, store: store, analyzer: StubAnalyzer())
        _ = await drain(await scanner.startFullScan())
        lib.update("p0") { $0.albumNames = ["Family"] }
        let progress = await scanner.quickCheck()
        #expect(progress.total == 0)
        #expect(
            try await store.items().first { $0.assetID == "p0" }?.metadata.albumNames == ["Family"])
    }

    @Test func aRefreshOfEveryItemIsSavedWithoutReanalysisAndInSlices() async throws {
        // After an update that reads a new property, every stored item differs from the library at
        // once. They are refreshed (not analyzed again), in slices of 500, and all of them arrive.
        let lib = library(count: 1_200)
        let store = try InMemoryStore.make()
        let scanner = ScanPipeline(
            library: lib, store: store, analyzer: StubAnalyzer(), chunkSize: 64)
        _ = await drain(await scanner.startFullScan())
        let previews = lib.previewRequests.count
        let added = Date(timeIntervalSince1970: 1_700_000_000)
        for id in lib.allIDs {
            lib.update(id) {
                $0.addedDate = added
                $0.hasLocation = true
            }
        }
        let progress = await scanner.quickCheck()
        #expect(progress.total == 0)
        #expect(lib.previewRequests.count == previews)
        let items = try await store.items()
        #expect(items.count == 1_200)
        #expect(
            items.allSatisfy { $0.metadata.addedDate == added && $0.metadata.hasLocation == true })
    }

    @Test func unavailablePreviewsCountAsNotScanned() async throws {
        let lib = library(count: 3)
        lib.add(Make.meta("cloud"), preview: .unavailable)
        let store = try InMemoryStore.make()
        let scanner = ScanPipeline(library: lib, store: store, analyzer: StubAnalyzer())
        let last = await drain(await scanner.startFullScan())
        #expect(last?.notScanned == 1)
        let cloud = try await store.items().first { $0.assetID == "cloud" }
        #expect(cloud?.analysisSource == .notScanned)
        #expect(cloud?.analysis == nil)
    }

    @Test func cloudPreviewsAreMarked() async throws {
        let lib = FakePhotoLibrary()
        lib.add(Make.meta("c"), preview: .cloudPreview(image))
        let store = try InMemoryStore.make()
        let scanner = ScanPipeline(library: lib, store: store, analyzer: StubAnalyzer())
        _ = await drain(await scanner.startFullScan())
        #expect(try await store.items()[0].analysisSource == .cloudPreview)
    }

    @Test func removedAssetsAreForgotten() async throws {
        let lib = library(count: 3)
        let store = try InMemoryStore.make()
        let scanner = ScanPipeline(library: lib, store: store, analyzer: StubAnalyzer())
        _ = await drain(await scanner.startFullScan())
        lib.delete("p1")
        _ = await scanner.quickCheck()
        #expect(Set(try await store.items().map(\.assetID)) == ["p0", "p2"])
    }

    @Test func stopThenResumeContinuesWhereItLeftOff() async throws {
        let lib = library(count: 40)
        lib.previewDelay = .milliseconds(5)
        let store = try InMemoryStore.make()
        let scanner = ScanPipeline(
            library: lib, store: store, analyzer: StubAnalyzer(), concurrency: 1, chunkSize: 5)
        let stream = await scanner.startFullScan()
        var stoppedAt = 0
        for await p in stream where p.processed >= 10 {
            await scanner.stop()
            stoppedAt = p.processed
            break
        }
        #expect(stoppedAt >= 10)
        let afterStop = try await store.items().count
        #expect(afterStop < 40)
        // A new scan analyzes only what is left.
        let before = lib.previewRequests.count
        let last = await drain(await scanner.startFullScan())
        #expect(last?.state == .completed)
        #expect(try await store.items().count == 40)
        #expect(lib.previewRequests.count - before == 40 - afterStop)
    }

    @Test func interruptedSessionIsResumed() async throws {
        let lib = library(count: 4)
        let store = try InMemoryStore.make()
        // Simulate an app killed mid-scan: a running session with 2 items saved.
        try await store.upsert(
            lib.allIDs.prefix(2).map { Make.item(Make.meta($0)) })
        let interrupted = ScanSession(
            kind: .full, state: .running, totalItems: 4, processedItems: 2)
        try await store.saveSession(interrupted)
        let scanner = ScanPipeline(library: lib, store: store, analyzer: StubAnalyzer())
        let last = await drain(await scanner.startFullScan())
        #expect(last?.processed == 4)
        #expect(last?.total == 4)
        #expect(try await store.currentSession()?.id == interrupted.id)
    }

    @Test func pauseAndResume() async throws {
        let lib = library(count: 20)
        lib.previewDelay = .milliseconds(5)
        let store = try InMemoryStore.make()
        let scanner = ScanPipeline(
            library: lib, store: store, analyzer: StubAnalyzer(), concurrency: 1, chunkSize: 2)
        let stream = await scanner.startFullScan()
        var sawPaused = false
        for await p in stream {
            if p.processed >= 4, !sawPaused, p.state == .running {
                await scanner.pause(reason: .user)
            }
            if p.state == .paused {
                sawPaused = true
                #expect(p.pauseReason == .user)
                await scanner.resume()
            }
        }
        #expect(sawPaused)
        #expect(try await store.items().count == 20)
    }

    /// 002 G1 + G2: a pause is fully saved by the time `pause(reason:)` returns, the
    /// reason is reported while paused, and it is cleared after resume.
    @Test func pauseIsLosslessAndReportsReason() async throws {
        let lib = library(count: 30)
        lib.previewDelay = .milliseconds(5)
        let store = try InMemoryStore.make()
        let scanner = ScanPipeline(
            library: lib, store: store, analyzer: StubAnalyzer(), concurrency: 2, chunkSize: 100,
            progressEvery: 1)
        let stream = await scanner.startFullScan()
        var requestedPause = false
        var storedWhenPaused = -1
        var sessionWhenPaused: ScanState?
        var pausedEvent: ScanProgress?
        var firstRunningAfterResume: ScanProgress?
        for await p in stream {
            if !requestedPause, p.state == .running, p.processed >= 8 {
                requestedPause = true
                await scanner.pause(reason: .stoppedOutsideApp)
                storedWhenPaused = try await store.items().count
                sessionWhenPaused = try await store.currentSession()?.state
            } else if p.state == .paused, pausedEvent == nil {
                pausedEvent = p
                await scanner.resume()
            } else if pausedEvent != nil, p.state == .running, firstRunningAfterResume == nil {
                firstRunningAfterResume = p
            }
        }
        let paused = try #require(pausedEvent)
        #expect(paused.pauseReason == .stoppedOutsideApp)
        #expect(paused.resumesOnForeground == false)
        #expect(storedWhenPaused == paused.processed)
        #expect(sessionWhenPaused == .paused)
        #expect(firstRunningAfterResume?.pauseReason == nil)
        #expect(try await store.items().count == 30)
        #expect(try await store.currentSession()?.state == .completed)
    }

    /// 002 G3: only a pause caused by lost background time resumes by itself.
    @Test func resumesOnForegroundOnlyForBackgroundLimit() {
        func progress(_ state: ScanState, _ reason: ScanPauseReason?) -> ScanProgress {
            ScanProgress(processed: 1, total: 2, notScanned: 0, state: state, pauseReason: reason)
        }
        #expect(progress(.paused, .backgroundLimit).resumesOnForeground)
        #expect(!progress(.paused, .user).resumesOnForeground)
        #expect(!progress(.paused, .stoppedOutsideApp).resumesOnForeground)
        #expect(!progress(.paused, nil).resumesOnForeground)
        #expect(!progress(.running, .backgroundLimit).resumesOnForeground)
    }

    /// 002 G4: progress is reported at least every `progressEvery` items.
    @Test func progressIsReportedAtLeastEveryProgressEvery() async throws {
        let lib = library(count: 23)
        let store = try InMemoryStore.make()
        let scanner = ScanPipeline(
            library: lib, store: store, analyzer: StubAnalyzer(), concurrency: 1, chunkSize: 100,
            progressEvery: 5)
        var events: [ScanProgress] = []
        for await p in await scanner.startFullScan() { events.append(p) }
        for (a, b) in zip(events, events.dropFirst()) {
            #expect(b.processed - a.processed <= 5)
        }
        #expect(events.last?.processed == 23)
        #expect(events.last?.state == .completed)
        #expect(events.count >= 23 / 5)
    }

    @Test func thermalPauseWaitsUntilCool() async throws {
        let lib = library(count: 3)
        let hot = HotFlag()
        let store = try InMemoryStore.make()
        let scanner = ScanPipeline(
            library: lib, store: store, analyzer: StubAnalyzer(), concurrency: 1, chunkSize: 1,
            thermalState: { hot.value ? .serious : .nominal })
        hot.value = true
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            hot.value = false
        }
        var sawThermal = false
        for await p in await scanner.startFullScan() where p.isThermalPaused {
            sawThermal = true
        }
        #expect(sawThermal)
        #expect(try await store.items().count == 3)
    }
}

final class HotFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
