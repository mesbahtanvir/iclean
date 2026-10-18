import Testing

@testable import CleanupKit

@Suite struct LargeVideosCategoryTests {
    func video(_ id: String, size: Int64?, source: AnalysisSource = .localPreview) -> LibraryItem {
        Make.item(Make.meta(id, kind: .video, duration: 60), source: source, size: size)
    }

    @Test func atMostFiftyLargestFirstNoneSelected() {
        let items = (0..<60).map { video("v\($0)", size: Int64($0) * 1_000_000) }
        let results = DefaultResultsBuilder(detectors: [LargeVideosCategory()]).buildResults(
            items: items, keepMarks: [])
        let listed = results.category(.largeVideos)!.allMembers
        #expect(listed.count == 50)
        #expect(listed.first == "v59")
        #expect(results.defaultSelection.isEmpty)
    }

    @Test func videosAlreadyListedByAnEarlierCategoryAreNotListedAgain() {
        let items = [video("a", size: 10), video("b", size: 20), video("c", size: 30)]
        let earlier = StubDetector(category: .screenshots) { _ in
            [
                ResultGroup(type: .single, members: ["a"]),
                ResultGroup(type: .single, members: ["b"]),
            ]
        }
        let results = DefaultResultsBuilder(detectors: [earlier, LargeVideosCategory()])
            .buildResults(items: items, keepMarks: [])
        #expect(results.category(.largeVideos)?.allMembers == ["c"])
    }

    @Test func metadataOnlyVideosAreListedLargestFirst() {
        // Ids that sort against the size order, so only the size sort can give this order.
        let items = [
            video("a-small", size: 10, source: .metadataOnly),
            video("z-big", size: 900_000_000, source: .metadataOnly),
            video("m-medium", size: 5_000_000, source: .metadataOnly),
        ]
        let results = DefaultResultsBuilder(detectors: [LargeVideosCategory()]).buildResults(
            items: items, keepMarks: [])
        #expect(results.category(.largeVideos)?.allMembers == ["z-big", "m-medium", "a-small"])
        #expect(results.notScannedCount == 0)
    }

    @Test func anUnmeasuredMetadataOnlyVideoIsRankedByItsEstimate() {
        let items = [
            video("measured", size: 10, source: .metadataOnly),
            video("unmeasured", size: nil, source: .metadataOnly),
        ]
        let results = DefaultResultsBuilder(detectors: [LargeVideosCategory()]).buildResults(
            items: items, keepMarks: [])
        #expect(
            Set(results.category(.largeVideos)?.allMembers ?? []) == ["measured", "unmeasured"])
        #expect(results.totals(for: .largeVideos).isEstimate)
    }

    @Test func notScannedVideosAreListedWithEstimatedSizes() {
        let items = [video("cloud", size: nil, source: .notScanned)]
        let results = DefaultResultsBuilder(detectors: [LargeVideosCategory()]).buildResults(
            items: items, keepMarks: [])
        #expect(results.category(.largeVideos)?.allMembers == ["cloud"])
        #expect(results.totals(for: .largeVideos).isEstimate)
    }
}
