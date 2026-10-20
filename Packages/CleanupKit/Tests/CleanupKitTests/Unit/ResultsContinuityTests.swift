import Foundation
import Testing

@testable import CleanupKit

/// 004 FR-011: what the person decided survives every rebuild made while a scan goes on.
@Suite struct ResultsContinuityTests {
    func photo(_ id: String, minutes: Double = 0, favorite: Bool = false) -> LibraryItem {
        Make.item(
            Make.meta(
                id, date: Date(timeIntervalSince1970: 1_700_000_000 + minutes * 60),
                favorite: favorite))
    }

    /// One duplicate group `a b c` with keeper `a`, plus two blurry singles.
    func results(members: [String] = ["a", "b", "c"], keepers: Set<String> = ["a"])
        -> CleanupResults
    {
        let group = ResultGroup(type: .duplicatePhotos, members: members, keepers: keepers)
        let blurry = ["x", "y"].map { ResultGroup(type: .single, members: [$0]) }
        let all = (members + ["x", "y"]).map { photo($0) }
        return CleanupResults(
            categories: [
                CategoryResult(category: .duplicates, groups: [group]),
                CategoryResult(category: .blurry, groups: blurry),
            ],
            defaultSelection: Set(group.removable + ["x", "y"]), notScannedCount: 0,
            items: Dictionary(uniqueKeysWithValues: all.map { ($0.assetID, $0) }))
    }

    @Test func withoutChoicesTheNewResultsAreUnchanged() {
        let new = results()
        let merged = ResultsContinuity.merge(new, choices: ReviewChoices())
        #expect(merged.results == new)
        #expect(merged.selection == new.defaultSelection)
    }

    @Test func anUnmarkedPhotoStaysUnmarkedAndAMarkedOneStaysMarked() {
        let choices = ReviewChoices(marks: ["x": false, "a": true, "gone": true])
        let merged = ResultsContinuity.merge(results(), choices: choices)
        #expect(!merged.selection.contains("x"))
        #expect(merged.selection.contains("y"))
        // A keeper is never marked for removal, whatever was recorded.
        #expect(!merged.selection.contains("a"))
        #expect(!merged.selection.contains("gone"))
    }

    @Test func aKeeperTheCleanerChoseSurvivesTheNextBuildEvenWhenAGroupGrows() {
        // The builder now thinks the new copy `d` is best, but the person chose `b`.
        let grown = results(members: ["a", "b", "c", "d"], keepers: ["d"])
        let merged = ResultsContinuity.merge(grown, choices: ReviewChoices(keepers: ["b"]))
        let group = merged.results.category(.duplicates)!.groups[0]
        #expect(group.keepers == ["b"])
        #expect(merged.selection.isSuperset(of: ["a", "c", "d"]))
        #expect(!merged.selection.contains("b"))
    }

    @Test func aKeeperThatWasOnlyShownIsNotPinned() {
        // Nothing was chosen, so the fresh build decides: the final result equals a one-shot scan.
        let grown = results(members: ["a", "b", "c", "d"], keepers: ["d"])
        let merged = ResultsContinuity.merge(grown, choices: ReviewChoices())
        #expect(merged.results.category(.duplicates)!.groups[0].keepers == ["d"])
    }

    @Test func aFavoriteStaysAKeeperBesideTheChosenOne() {
        var new = results(keepers: ["a", "c"])
        new.items["c"] = photo("c", favorite: true)
        let merged = ResultsContinuity.merge(new, choices: ReviewChoices(keepers: ["b"]))
        #expect(merged.results.category(.duplicates)!.groups[0].keepers == ["b", "c"])
    }

    @Test func removedPhotosNeverComeBack() {
        let merged = ResultsContinuity.merge(
            results(), choices: ReviewChoices(removed: ["b", "x"]))
        #expect(!merged.results.items.keys.contains("b"))
        #expect(!merged.results.items.keys.contains("x"))
        #expect(!merged.selection.contains("b") && !merged.selection.contains("x"))
        #expect(merged.results.category(.blurry)!.allMembers == ["y"])
    }
}
