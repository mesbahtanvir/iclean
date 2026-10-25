import Foundation
import Testing

@testable import CleanupKit

/// Spec 015, Story 3: all screen recordings, newest first, none selected, no frame opened.
@Suite struct ScreenRecordingsCategoryTests {
    func recording(
        _ id: String, minutes: Double, size: Int64 = 50_000_000, favorite: Bool = false,
        source: AnalysisSource = .metadataOnly
    ) -> LibraryItem {
        var item = Make.item(
            Make.meta(
                id, kind: .screenRecording, date: Date(timeIntervalSince1970: minutes * 60),
                favorite: favorite, duration: 30),
            source: source, size: size)
        item.analysis = nil
        return item
    }

    @Test func allRecordingsNewestFirstNoneSelected() {
        let items = [
            recording("old", minutes: 1), recording("new", minutes: 9),
            Make.item(Make.meta("video", kind: .video, duration: 10), source: .metadataOnly),
            Make.item(Make.meta("photo")),
        ]
        let results = DefaultResultsBuilder(detectors: [ScreenRecordingsCategory()])
            .buildResults(items: items, keepMarks: [])
        #expect(results.category(.screenRecordings)?.allMembers == ["new", "old"])
        #expect(results.defaultSelection.isEmpty)
        #expect(results.notScannedCount == 0)
    }

    @Test func favoritesAndKeepMarksAreNotListed() {
        let items = [
            recording("fav", minutes: 1, favorite: true), recording("kept", minutes: 2),
            recording("x", minutes: 3),
        ]
        let results = DefaultResultsBuilder(detectors: [ScreenRecordingsCategory()])
            .buildResults(items: items, keepMarks: ["kept"])
        #expect(results.category(.screenRecordings)?.allMembers == ["x"])
    }

    @Test func aRecordingAmongTheLargestVideosIsListedOnceInScreenRecordings() {
        let items = [
            recording("rec", minutes: 1, size: 900_000_000),
            Make.item(Make.meta("v", kind: .video, duration: 10), source: .metadataOnly, size: 10),
        ]
        let results = DefaultResultsBuilder(detectors: StandardPipeline.detectors())
            .buildResults(items: items, keepMarks: [])
        #expect(results.category(.screenRecordings)?.allMembers == ["rec"])
        #expect(results.category(.largeVideos)?.allMembers == ["v"])
        #expect(results.category(of: "rec") == .screenRecordings)
    }

    @Test func theKindIsAVideoForEveryRuleThatOpensFrames() {
        #expect(ItemKind.screenRecording.isVideo)
        #expect(!ItemKind.screenRecording.isStillImage)
        #expect(CleanupCategory.screenRecordings.listsVideos)
        #expect(!CleanupCategory.screenRecordings.preselects)
    }

    @Test func theFreeScanStoresARecordingByMetadataAndOpensNoFrame() async throws {
        let image = TestImages.scene(seed: 9, width: 64, height: 48)
        let lib = FakePhotoLibrary()
        lib.add(Make.meta("p"), preview: .local(image))
        lib.add(
            Make.meta("rec", kind: .screenRecording, duration: 20), preview: .local(image),
            size: 30_000_000)
        let store = try InMemoryStore.make()
        let scanner = ScanPipeline(
            library: lib, store: store, analyzer: StubAnalyzer(), chunkSize: 2)
        for await _ in await scanner.startFullScan() {}
        #expect(Set(lib.previewRequests) == ["p"])
        let rec = try await store.items().first { $0.assetID == "rec" }
        #expect(rec?.analysisSource == .metadataOnly)
        #expect(rec?.analysis == nil)
    }
}
