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
        let scanner = ScanPipeline(library: lib, store: store, analyzer: StubAnalyzer(), saveEvery: 3)
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
        #expect(try await store.items().first { $0.assetID == "p0" }?.metadata.albumNames == ["Family"])
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
            library: lib, store: store, analyzer: StubAnalyzer(), concurrency: 1, saveEvery: 5)
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
        let interrupted = ScanSession(kind: .full, state: .running, totalItems: 4, processedItems: 2)
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
            library: lib, store: store, analyzer: StubAnalyzer(), concurrency: 1, saveEvery: 2)
        let stream = await scanner.startFullScan()
        var sawPaused = false
        for await p in stream {
            if p.processed >= 4, !sawPaused, p.state == .running {
                await scanner.pause()
            }
            if p.state == .paused {
                sawPaused = true
                await scanner.resume()
            }
        }
        #expect(sawPaused)
        #expect(try await store.items().count == 20)
    }

    @Test func thermalPauseWaitsUntilCool() async throws {
        let lib = library(count: 3)
        let hot = HotFlag()
        let store = try InMemoryStore.make()
        let scanner = ScanPipeline(
            library: lib, store: store, analyzer: StubAnalyzer(), concurrency: 1, saveEvery: 1,
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
