import Testing

@testable import CleanupKit

@Suite struct LargeVideosCategoryTests {
    func video(_ id: String, size: Int64?, source: AnalysisSource = .localPreview) -> LibraryItem {
        Make.item(Make.meta(id, kind: .video, duration: 60), source: source, size: size)
    }

    @Test func atMostFiftyLargestFirstNoneSelected() {
        let items = (0..<60).map { video("v\($0)", size: Int64($0) * 1_000_000) }
        let results = DefaultResultsBuilder(detectors: [LargeVideosCategory()]).buildResults(items: items, keepMarks: [])
        let listed = results.category(.largeVideos)!.allMembers
        #expect(listed.count == 50)
        #expect(listed.first == "v59")
        #expect(results.defaultSelection.isEmpty)
    }

    @Test func videosInDuplicateGroupsAreNotListedAgain() {
        let items = [video("a", size: 10), video("b", size: 20), video("c", size: 30)]
        let dupes = StubDetector(category: .duplicateVideos) { _ in
            [ResultGroup(type: .duplicateVideos, members: ["a", "b"], keepers: ["a"])]
        }
        let results = DefaultResultsBuilder(detectors: [dupes, LargeVideosCategory()]).buildResults(items: items, keepMarks: [])
        #expect(results.category(.largeVideos)?.allMembers == ["c"])
    }

    @Test func notScannedVideosAreListedWithEstimatedSizes() {
        let items = [video("cloud", size: nil, source: .notScanned)]
        let results = DefaultResultsBuilder(detectors: [LargeVideosCategory()]).buildResults(items: items, keepMarks: [])
        #expect(results.category(.largeVideos)?.allMembers == ["cloud"])
        #expect(results.totals(for: .largeVideos).isEstimate)
    }
}
