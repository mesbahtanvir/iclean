import CoreGraphics
import Foundation
import Testing

@testable import CleanupKit

/// Videos are never analyzed (004 FR-004a, 016). A scan stores each video with its metadata only,
/// so Large Videos can rank it by size, and no category groups videos.
@Suite struct VideosAreNotAnalyzedTests {
    let image = TestImages.scene(seed: 5, width: 64, height: 48)

    func library() -> FakePhotoLibrary {
        let lib = FakePhotoLibrary()
        for i in 0..<3 { lib.add(Make.meta("p\(i)"), preview: .local(image)) }
        // Two copies of the same clip. Nothing groups them: both are listed by size.
        lib.add(
            Make.meta("v1", kind: .video, duration: 12), preview: .local(image), size: 9_000_000)
        lib.add(
            Make.meta("v2", kind: .video, duration: 12.2), preview: .local(image), size: 24_000_000)
        return lib
    }

    func drain(_ stream: AsyncStream<ScanProgress>) async -> ScanProgress? {
        var last: ScanProgress?
        for await p in stream { last = p }
        return last
    }

    func scanner(
        _ lib: FakePhotoLibrary, _ store: Store, chunkSize: Int = 2,
        analyzer: Analyzer = StubAnalyzer()
    ) -> ScanPipeline {
        ScanPipeline(library: lib, store: store, analyzer: analyzer, chunkSize: chunkSize)
    }

    @Test func noPreviewIsRequestedForAVideo() async throws {
        let lib = library()
        let s = scanner(lib, try InMemoryStore.make())
        let last = await drain(await s.startFullScan())
        #expect(last?.state == .completed)
        #expect(Set(lib.previewRequests) == ["p0", "p1", "p2"])
    }

    @Test func videosAreStoredAsMetadataOnlyAndAreNotCountedAsNotScanned() async throws {
        let lib = library()
        let store = try InMemoryStore.make()
        let s = scanner(lib, store)
        let last = await drain(await s.startFullScan())
        #expect(last?.processed == 5)
        #expect(last?.notScanned == 0)
        let items = try await store.items()
        for id in ["v1", "v2"] {
            let item = items.first { $0.assetID == id }
            #expect(item?.analysisSource == .metadataOnly)
            #expect(item?.analysis == nil)
            #expect(item?.scanFailure == nil)
        }
        #expect(items.filter { $0.metadata.kind == .photo }.allSatisfy { $0.analysis != nil })
    }

    @Test func aLaterFullScanDoesNotRetryThem() async throws {
        let lib = library()
        let store = try InMemoryStore.make()
        let s = scanner(lib, store)
        _ = await drain(await s.startFullScan())
        let again = await drain(await s.startFullScan())
        #expect(again?.total == 0)
        #expect(lib.previewRequests.filter { $0.hasPrefix("v") }.isEmpty)
        #expect(try await store.items().first { $0.assetID == "v1" }?.scanAttempts == 0)
    }

    @Test func aNewVideoIsStoredWithoutAPreviewRequest() async throws {
        let lib = library()
        let store = try InMemoryStore.make()
        let s = scanner(lib, store)
        _ = await drain(await s.startFullScan())
        lib.add(
            Make.meta("v3", kind: .video, duration: 30), preview: .local(image), size: 50_000_000)
        let progress = await s.quickCheck()
        #expect(progress.total == 1)
        #expect(lib.previewRequests.filter { $0.hasPrefix("v") }.isEmpty)
        #expect(
            try await store.items().first { $0.assetID == "v3" }?.analysisSource == .metadataOnly)
    }

    @Test func largeVideosStillListsThemAndNothingElseDoes() async throws {
        let lib = library()
        let store = try InMemoryStore.make()
        let s = scanner(lib, store)
        _ = await drain(await s.startFullScan())
        let results = DefaultResultsBuilder(detectors: StandardPipeline.detectors())
            .buildResults(items: try await store.items(), keepMarks: [])
        #expect(results.category(.largeVideos)?.allMembers.first == "v2")
        #expect(Set(results.category(.largeVideos)?.allMembers ?? []) == ["v1", "v2"])
        let others = results.categories.filter { $0.category != .largeVideos }.flatMap(\.allMembers)
        #expect(!others.contains("v1") && !others.contains("v2"))
        #expect(results.notScannedCount == 0)
    }

    @Test func theDetectorListHasNoVideoDetector() {
        let detectors = StandardPipeline.detectors()
        #expect(
            detectors.map(\.category)
                == [.duplicates, .similar, .blurry, .unimportant, .screenshots, .largeVideos])
        // Large Videos reads sizes, never pixels: it is the one detector that lists videos.
        #expect(detectors.filter { $0.category == .largeVideos }.allSatisfy { !$0.needsAnalysis })
    }

    @Test func oldStoredVideoAnalysisIsNotUsedToGroupVideos() {
        // A store from before 2026-10-18 holds analyzed videos that look identical.
        let a = Make.item(
            Make.meta("a", kind: .video, duration: 12), dHash: 7,
            thumbprint: Data(repeating: 9, count: 1024))
        let b = Make.item(
            Make.meta("b", kind: .video, duration: 12.1), dHash: 7,
            thumbprint: Data(repeating: 9, count: 1024))
        let results = DefaultResultsBuilder(detectors: StandardPipeline.detectors())
            .buildResults(items: [a, b], keepMarks: [])
        #expect(results.categories.map(\.category) == [.largeVideos])
        #expect(Set(results.category(.largeVideos)?.allMembers ?? []) == ["a", "b"])
    }

    @Test func metadataOnlyRoundTripsThroughTheStore() async throws {
        let store = try InMemoryStore.make()
        let item = LibraryItem(
            metadata: Make.meta("v", kind: .video, duration: 5), analysisSource: .metadataOnly,
            analysis: nil)
        try await store.upsert([item])
        let back = try await store.items().first
        #expect(back?.analysisSource == .metadataOnly)
        #expect(back?.analysis == nil)
        #expect(AnalysisSource.metadataOnly.hasAnalysis == false)
        #expect(AnalysisSource.localPreview.hasAnalysis && AnalysisSource.cloudPreview.hasAnalysis)
        #expect(AnalysisSource.notScanned.hasAnalysis == false)
    }

    @Test func aMetadataOnlyItemNeverStoresAnalysisColumns() {
        // Even if someone sets an analysis on the value afterwards, the stored record keeps none.
        var item = LibraryItem(
            metadata: Make.meta("v", kind: .video, duration: 5), analysisSource: .metadataOnly,
            analysis: nil)
        item.analysis = Analysis(
            dHash: 1, thumbprint: Data([1]), featurePrint: Data([1]), sharpness: 1)
        let record = LibraryItemRecord(item)
        #expect(record.dHashBits == nil && record.featurePrint == nil && record.sharpness == nil)
    }
}
