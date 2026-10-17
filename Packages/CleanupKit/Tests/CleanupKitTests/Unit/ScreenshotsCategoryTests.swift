import Foundation
import Testing

@testable import CleanupKit

@Suite struct ScreenshotsCategoryTests {
    func shot(_ id: String, minutes: Double, favorite: Bool = false, source: AnalysisSource = .localPreview) -> LibraryItem {
        Make.item(
            Make.meta(id, kind: .screenshot, date: Date(timeIntervalSince1970: minutes * 60), favorite: favorite),
            source: source)
    }

    @Test func onlyScreenshotsNewestFirstAllSelected() {
        let items = [
            shot("old", minutes: 1), shot("new", minutes: 9), Make.item(Make.meta("photo")),
            shot("cloud", minutes: 5, source: .notScanned),
        ]
        let results = DefaultResultsBuilder(detectors: [ScreenshotsCategory()]).buildResults(items: items, keepMarks: [])
        #expect(results.category(.screenshots)?.allMembers == ["new", "cloud", "old"])
        #expect(results.defaultSelection == ["new", "cloud", "old"])
    }

    @Test func favoritesAndKeepMarksAreExcluded() {
        let items = [shot("fav", minutes: 1, favorite: true), shot("kept", minutes: 2), shot("x", minutes: 3)]
        let results = DefaultResultsBuilder(detectors: [ScreenshotsCategory()]).buildResults(items: items, keepMarks: ["kept"])
        #expect(results.category(.screenshots)?.allMembers == ["x"])
    }

    @Test func screenshotsInAnEarlierCategoryAreNotListedAgain() {
        let items = [shot("a", minutes: 1), shot("b", minutes: 2)]
        let earlier = StubDetector(category: .blurry) { _ in [ResultGroup(type: .single, members: ["a"])] }
        let results = DefaultResultsBuilder(detectors: [ScreenshotsCategory(), earlier]).buildResults(items: items, keepMarks: [])
        #expect(results.category(.screenshots)?.allMembers == ["b"])
    }
}
