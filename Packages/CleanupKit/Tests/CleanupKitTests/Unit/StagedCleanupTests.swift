import CoreGraphics
import Foundation
import Testing

@testable import CleanupKit

/// Spec 008: results become reviewable while the scan goes on, and nothing a scan needs grows
/// with the library's fingerprints.
@Suite struct StagedCleanupTests {
    let image = TestImages.scene(seed: 3, width: 64, height: 48)

    func drain(_ stream: AsyncStream<ScanProgress>) async -> [ScanProgress] {
        var all: [ScanProgress] = []
        for await p in stream { all.append(p) }
        return all
    }

    // MARK: Blocks

    @Test func blocksStartSmallThenGrow() {
        #expect(ScanBlocks.edge(after: 0) == 500)
        #expect(ScanBlocks.edge(after: 499) == 500)
        #expect(ScanBlocks.edge(after: 500) == 1_500)
        #expect(ScanBlocks.edge(after: 1_499) == 1_500)
        #expect(ScanBlocks.edge(after: 1_500) == 4_000)
        #expect(ScanBlocks.edge(after: 4_000) == 6_500)
        #expect(ScanBlocks.edge(after: 29_999) == 31_500)
    }

    // MARK: Planning

    @Test func photosAreCheckedNewestFirstAndEqualDatesKeepTheirOrder() {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let library = [
            Make.meta("old", date: day),
            Make.meta("new", date: day.addingTimeInterval(86_400)),
            Make.meta("tie1", date: day.addingTimeInterval(3_600)),
            Make.meta("tie2", date: day.addingTimeInterval(3_600)),
        ]
        let plan = ScanPlanner.plan(
            library: library, stored: [], kind: .full, policy: .default)
        #expect(plan.toAnalyze.map(\.assetID) == ["new", "tie1", "tie2", "old"])
    }

    @Test func screenshotsAndVideosAreQuickWins() {
        let library = [
            Make.meta("p"), Make.meta("s", kind: .screenshot),
            Make.meta("v", kind: .video, duration: 30),
        ]
        let plan = ScanPlanner.plan(library: library, stored: [], kind: .full, policy: .default)
        #expect(Set(plan.quickWins.map(\.assetID)) == ["s", "v"])
        // Quick wins stay in the job, so counts and chunks are unchanged.
        #expect(plan.toAnalyze.count == 3)
    }

    @Test func aMetadataChangeIsRefreshedWithoutTouchingTheAnalysis() async throws {
        let store = try InMemoryStore.make()
        let m = Make.meta("a")
        try await store.upsert([
            Make.item(
                m, dHash: 99, thumbprint: Data(repeating: 7, count: 1024), print: Data([1, 2, 3]))
        ])
        var changed = m
        changed.albumNames = ["Trip"]
        changed.isFavorite = true
        try await store.refreshMetadata([changed])
        let back = try #require(try await store.items().first)
        #expect(back.metadata.albumNames == ["Trip"] && back.metadata.isFavorite)
        #expect(back.analysis?.dHash == 99)
        #expect(back.analysis?.featurePrint == Data([1, 2, 3]))
        #expect(back.analysis?.thumbprint.count == 1024)
    }

    // MARK: Sizes

    @Test func measureVideosFillsEverySizeInOnePassAndMovesTheRevisionOnce() async throws {
        let lib = FakePhotoLibrary()
        lib.add(Make.meta("p"), preview: .local(image))
        lib.add(
            Make.meta("v1", kind: .video, duration: 30), preview: .local(image), size: 5_000_000)
        lib.add(
            Make.meta("v2", kind: .video, duration: 10), preview: .local(image), size: 9_000_000)
        // Not on the phone: gets an estimate, marked as one.
        lib.add(
            Make.meta("v3", kind: .video, duration: 20), preview: .local(image), size: nil)
        let store = try InMemoryStore.make()
        try await store.upsert(
            await lib.fetchAllItems().map {
                LibraryItem(metadata: $0, analysisSource: .metadataOnly, analysis: nil)
            })
        let measurer = SizeMeasurer(library: lib, store: store)
        let before = try await store.revision()

        #expect(await measurer.measureVideos() == 3)
        let sizes = try await store.sizes(for: ["p", "v1", "v2", "v3"])
        #expect(sizes["v1"] == MeasuredSize(bytes: 5_000_000, isEstimated: false))
        #expect(sizes["v2"] == MeasuredSize(bytes: 9_000_000, isEstimated: false))
        #expect(sizes["v3"]?.isEstimated == true)
        #expect(sizes["p"] == nil, "a photo's size is read only when its category is opened")
        #expect(try await store.revision() == before + 1)

        // Nothing is left to measure: no write, so the results are not built again for it.
        #expect(await measurer.measureVideos() == 0)
        #expect(try await store.revision() == before + 1)
    }

    // MARK: Quick wins in the pipeline

    @Test func screenshotsAndVideosAreListedBeforeAnyPhotoIsOpened() async throws {
        let lib = FakePhotoLibrary()
        lib.previewDelay = .seconds(30)  // photos never finish within this test
        for i in 0..<6 { lib.add(Make.meta("p\(i)"), preview: .local(image)) }
        lib.add(Make.meta("shot", kind: .screenshot), preview: .local(image))
        lib.add(
            Make.meta("clip", kind: .video, duration: 30), preview: .local(image), size: 5_000_000)
        let store = try InMemoryStore.make()
        let scanner = ScanPipeline(library: lib, store: store, analyzer: StubAnalyzer())
        let stream = await scanner.startFullScan()
        var first: ScanProgress?
        for await p in stream {
            first = p
            break
        }
        #expect((first?.publishedRevision ?? 0) > 0)
        let stored = try await store.itemSummaries()
        #expect(Set(stored.map(\.assetID)) == ["shot", "clip"])
        #expect(stored.allSatisfy { $0.analysisSource == .metadataOnly })
        // They can be turned into results at once.
        let loader = ResultsLoader(
            store: store, builder: DefaultResultsBuilder(detectors: StandardPipeline.detectors()))
        let results = try await loader.load()
        #expect(results.category(.screenshots)?.allMembers == ["shot"])
        #expect(results.category(.largeVideos)?.allMembers == ["clip"])
        await scanner.stop()
    }

    @Test func screenshotsAreNeverOpenedForAnalysis() async throws {
        let lib = FakePhotoLibrary()
        lib.add(Make.meta("p"), preview: .local(image))
        lib.add(Make.meta("shot", kind: .screenshot), preview: .local(image))
        let store = try InMemoryStore.make()
        let scanner = ScanPipeline(library: lib, store: store, analyzer: StubAnalyzer())
        let last = await drain(await scanner.startFullScan()).last
        #expect(last?.state == .completed && last?.processed == 2 && last?.total == 2)
        #expect(lib.previewRequests == ["p"])
        let shot = try #require(try await store.items().first { $0.assetID == "shot" })
        #expect(shot.analysisSource == .metadataOnly && shot.analysis == nil)
    }

    @Test func aFinishedBlockMovesThePublishedRevision() async throws {
        let lib = FakePhotoLibrary()
        for i in 0..<620 {
            lib.add(
                Make.meta("p\(i)", date: Date(timeIntervalSince1970: Double(i))),
                preview: .local(image))
        }
        let store = try InMemoryStore.make()
        let scanner = ScanPipeline(
            library: lib, store: store, analyzer: StubAnalyzer(), chunkSize: 64)
        let events = await drain(await scanner.startFullScan())
        // No quick wins in this library: the revision moves once, when 500 photos are done.
        let revisions = events.map(\.publishedRevision)
        #expect(revisions.first == 0)
        #expect(revisions.last == 1)
        let firstWithRevision = try #require(events.first { $0.publishedRevision == 1 })
        #expect(firstWithRevision.processed >= 500)
        #expect(revisions == revisions.sorted())
    }

    @Test func progressEventsAreHeldBackButTheEndIsAlwaysReported() async throws {
        let lib = FakePhotoLibrary()
        for i in 0..<200 { lib.add(Make.meta("p\(i)"), preview: .local(image)) }
        let chatty = ScanPipeline(
            library: lib, store: try InMemoryStore.make(), analyzer: StubAnalyzer(),
            chunkSize: 64, progressEvery: 1)
        let calm = ScanPipeline(
            library: lib, store: try InMemoryStore.make(), analyzer: StubAnalyzer(),
            chunkSize: 64, progressEvery: 1, minProgressInterval: .seconds(60))
        let many = await drain(await chatty.startFullScan())
        let few = await drain(await calm.startFullScan())
        #expect(many.count > 150)
        // The first event, one per chunk (4) and the last.
        #expect(few.count <= 7)
        #expect(few.last?.state == .completed && few.last?.processed == 200)
    }

    // MARK: Lean store readers

    @Test func leanReadersMatchTheFullReaderAcrossPageBoundaries() async throws {
        let store = try InMemoryStore.make()
        var items: [LibraryItem] = []
        for i in 0..<2_300 {
            let meta = Make.meta("a\(i)", date: Date(timeIntervalSince1970: Double(i)))
            let thumb = Data(repeating: UInt8(i % 250), count: 1024)
            let print = Data(repeating: UInt8(i % 200), count: 64)
            items.append(
                Make.item(
                    meta, dHash: UInt64(i), thumbprint: thumb, print: print,
                    sharpness: Double(i) / 3_000))
        }
        try await store.upsert(Array(items[0..<1_000]))
        try await store.upsert(Array(items[1_000...]))
        let full = Dictionary(
            uniqueKeysWithValues: try await store.items().map { ($0.assetID, $0) })
        let summaries = try await store.itemSummaries()
        #expect(summaries.count == 2_300 && Set(summaries.map(\.assetID)).count == 2_300)
        for s in summaries { #expect(s.metadata == full[s.assetID]?.metadata) }
        let slim = try await store.itemsWithoutFeaturePrints()
        #expect(slim.count == 2_300 && Set(slim.map(\.assetID)).count == 2_300)
        for item in slim {
            let whole = try #require(full[item.assetID])
            #expect(item.analysis?.featurePrint == Data())
            var expected = whole
            expected.analysis?.featurePrint = Data()
            #expect(item == expected)
        }
        let prints = try await store.featurePrints(for: ["a5", "a1999", "missing"])
        #expect(prints.keys.sorted() == ["a1999", "a5"])
        #expect(prints["a5"] == full["a5"]?.analysis?.featurePrint)
    }

    // MARK: Results are the same

    /// Photos taken seconds apart, near-copies and far-apart singles, analyzed by the real analyzer
    /// so the feature prints are real. The lean path must produce exactly what `items()` would.
    @Test func resultsFromTheLeanPathEqualResultsFromTheFullReader() async throws {
        let store = try InMemoryStore.make()
        var items: [LibraryItem] = []
        let analyzer = DefaultAnalyzer()
        func add(_ id: String, _ image: CGImage, at seconds: Double, burst: String? = nil)
            async throws
        {
            let m = Make.meta(
                id, date: Date(timeIntervalSince1970: 1_700_000_000 + seconds), burst: burst)
            let analysis = try await analyzer.analyze(image, metadata: m)
            items.append(
                LibraryItem(metadata: m, analysisSource: .localPreview, analysis: analysis))
        }
        let scene = TestImages.scene(seed: 21)
        for step in 0..<4 {
            try await add(
                "burst\(step)", TestImages.withSubject(scene, seed: 21, step: step),
                at: Double(step) * 2)
        }
        try await add("copyA", TestImages.scene(seed: 5), at: 5_000)
        try await add("copyB", TestImages.resized(TestImages.scene(seed: 5), scale: 0.5), at: 5_030)
        try await add("alone1", TestImages.scene(seed: 6), at: 20_000)
        try await add("alone2", TestImages.stripes(seed: 7), at: 40_000)
        try await add("blurry", TestImages.blurred(TestImages.scene(seed: 8)), at: 60_000)
        try await store.upsert(items)

        let builder = DefaultResultsBuilder(detectors: StandardPipeline.detectors())
        let expected = builder.buildResults(items: try await store.items(), keepMarks: [])
        let lean = try await ResultsLoader(store: store, builder: builder).load()
        #expect(lean == expected)
        #expect(!lean.categories.isEmpty)
        // The lone photos need no feature print at all.
        let wanted = SimilarShotsDetector.photosThatMayNeedFeaturePrints(items)
        #expect(
            !wanted.contains("alone1") && !wanted.contains("alone2") && !wanted.contains("blurry"))
        #expect(wanted.contains("burst0") && wanted.contains("copyA") && wanted.contains("copyB"))
    }

    @Test func everyPairInTheWindowHasBothFeaturePrintsLoaded() {
        var rng = SeededRandom(seed: 99)
        let items = (0..<400).map { i in
            Make.item(
                Make.meta(
                    "r\(i)", date: Date(timeIntervalSince1970: floor(rng.unit() * 20_000))),
                print: Data([1]))
        }
        let wanted = Set(SimilarShotsDetector.photosThatMayNeedFeaturePrints(items))
        let sorted = items.sorted { $0.metadata.captureDate! < $1.metadata.captureDate! }
        var pairs = 0
        for i in sorted.indices {
            var j = i + 1
            while j < sorted.count,
                sorted[j].metadata.captureDate!.timeIntervalSince(sorted[i].metadata.captureDate!)
                    <= SimilarThresholds.window
            {
                #expect(wanted.contains(sorted[i].assetID) && wanted.contains(sorted[j].assetID))
                pairs += 1
                j += 1
            }
        }
        #expect(pairs > 50)
        #expect(wanted.count < items.count)
    }

    // MARK: Analysis

    @Test func aSharpPhotoIsNotGivenAnAestheticsScore() async throws {
        let sharp = TestImages.scene(seed: 31)
        let meta = Make.meta("a")
        let analysis = try await DefaultAnalyzer().analyze(sharp, metadata: meta)
        #expect(analysis.sharpness >= BlurThresholds.sharpness + DefaultAnalyzer.aestheticsMargin)
        #expect(analysis.aestheticsScore == nil)
    }

    @Test func aPortraitIsNeverGivenAnAestheticsScore() async throws {
        let blurred = TestImages.blurred(TestImages.scene(seed: 32))
        let analysis = try await DefaultAnalyzer().analyze(
            blurred, metadata: Make.meta("p", portrait: true))
        #expect(analysis.aestheticsScore == nil)
    }
}
