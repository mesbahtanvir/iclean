import CoreGraphics
import Foundation
import Testing

@testable import CleanupKit

/// Video analysis is a Pro feature (`ProFeatures`). Without it a scan stores each video with its
/// metadata only, so Large Videos can rank it by size, and there is no Duplicate Videos category.
/// With it, videos are analyzed and copies are grouped, and videos the free app stored without
/// analysis are picked up by the next full scan.
@Suite struct VideosAreNotAnalyzedTests {
    let image = TestImages.scene(seed: 5, width: 64, height: 48)

    func library() -> FakePhotoLibrary {
        let lib = FakePhotoLibrary()
        for i in 0..<3 { lib.add(Make.meta("p\(i)"), preview: .local(image)) }
        // Two copies of the same clip: Pro groups them as duplicate videos.
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
        _ lib: FakePhotoLibrary, _ store: Store, _ features: ProFeatures = .free,
        chunkSize: Int = 2,
        analyzer: Analyzer = StubAnalyzer()
    ) -> ScanPipeline {
        ScanPipeline(
            library: lib, store: store, analyzer: analyzer, chunkSize: chunkSize,
            features: features)
    }

    // MARK: Free

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
        let results = DefaultResultsBuilder(detectors: StandardPipeline.detectors(.free))
            .buildResults(items: try await store.items(), keepMarks: [])
        #expect(results.category(.largeVideos)?.allMembers.first == "v2")
        #expect(Set(results.category(.largeVideos)?.allMembers ?? []) == ["v1", "v2"])
        let others = results.categories.filter { $0.category != .largeVideos }.flatMap(\.allMembers)
        #expect(!others.contains("v1") && !others.contains("v2"))
        #expect(results.notScannedCount == 0)
    }

    @Test func theFreeDetectorListHasNoDuplicateVideos() {
        #expect(
            StandardPipeline.detectors().map(\.category)
                == [.duplicates, .similar, .blurry, .screenshots, .largeVideos])
        #expect(
            StandardPipeline.detectors(.free).map(\.category).contains(.duplicateVideos) == false)
        #expect(ProFeatures.free.videoAnalysis == false)
    }

    @Test func oldStoredVideoAnalysisIsNotUsedToGroupVideosInTheFreeApp() {
        // A store from before video analysis became Pro holds analyzed videos that look identical.
        let a = Make.item(
            Make.meta("a", kind: .video, duration: 12), dHash: 7,
            thumbprint: Data(repeating: 9, count: 1024))
        let b = Make.item(
            Make.meta("b", kind: .video, duration: 12.1), dHash: 7,
            thumbprint: Data(repeating: 9, count: 1024))
        let results = DefaultResultsBuilder(detectors: StandardPipeline.detectors(.free))
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

    // MARK: Pro

    @Test func proAnalyzesVideosAndGroupsCopies() async throws {
        let lib = library()
        let store = try InMemoryStore.make()
        // The real analyzer, so the copies get real fingerprints to be grouped by.
        let s = scanner(lib, store, .pro, analyzer: DefaultAnalyzer())
        _ = await drain(await s.startFullScan())
        #expect(Set(lib.previewRequests) == ["p0", "p1", "p2", "v1", "v2"])
        let items = try await store.items()
        #expect(items.first { $0.assetID == "v1" }?.analysisSource == .localPreview)
        let detectors = StandardPipeline.detectors(.pro)
        #expect(detectors.map(\.category).contains(.duplicateVideos))
        #expect(detectors.map(\.category).last == .largeVideos)
        let results = DefaultResultsBuilder(detectors: detectors).buildResults(
            items: items, keepMarks: [])
        #expect(Set(results.category(.duplicateVideos)?.allMembers ?? []) == ["v1", "v2"])
        // A video in a duplicate group is not listed again as a large video.
        #expect(results.category(.largeVideos) == nil)
    }

    @Test func videosTheFreeAppStoredAreAnalyzedByTheFirstProFullScan() async throws {
        let lib = library()
        let store = try InMemoryStore.make()
        let free = scanner(lib, store, .free)
        _ = await drain(await free.startFullScan())
        let before = lib.previewRequests.count
        let pro = scanner(lib, store, .pro)
        // A quick check never starts the work (001 FR-005a)...
        #expect(await pro.quickCheck().total == 0)
        #expect(lib.previewRequests.count == before)
        // ...a full scan does, for the videos only.
        let last = await drain(await pro.startFullScan())
        #expect(last?.total == 2)
        #expect(Set(lib.previewRequests.dropFirst(before)) == ["v1", "v2"])
        #expect(
            try await store.items().first { $0.assetID == "v1" }?.analysisSource == .localPreview)
    }
}
