import CoreGraphics
import Foundation
import Testing

@testable import CleanupKit

@Suite struct RemovalGateTests {
    let image = TestImages.scene(seed: 4, width: 32, height: 24)

    /// Library and results for a duplicate group {a (keeper), b, c} and a blurry single d.
    func setup() -> (FakePhotoLibrary, CleanupResults) {
        let lib = FakePhotoLibrary()
        var items: [String: LibraryItem] = [:]
        for id in ["a", "b", "c", "d", "x"] {
            let m = Make.meta(id, date: Date(timeIntervalSince1970: 1_700_000_000))
            lib.add(m, preview: .local(image))
            items[id] = Make.item(m)
        }
        let dup = ResultGroup(type: .duplicatePhotos, members: ["a", "b", "c"], keepers: ["a"])
        let blurry = ResultGroup(type: .single, members: ["d"])
        let results = CleanupResults(
            categories: [
                CategoryResult(category: .duplicates, groups: [dup]),
                CategoryResult(category: .blurry, groups: [blurry]),
            ], defaultSelection: ["b", "c", "d"], notScannedCount: 0, items: items)
        return (lib, results)
    }

    @Test func anUnchangedSelectionPassesWholeAndNothingIsDropped() async {
        let (lib, results) = setup()
        let plan = await RemovalGate.plan(
            selection: ["b", "c", "d"], results: results, library: lib)
        #expect(plan.ids == ["b", "c", "d"])
        #expect(plan.droppedCount == 0)
    }

    @Test func aPhotoDeletedMeanwhileIsLeftOut() async {
        let (lib, results) = setup()
        lib.delete("b")
        let plan = await RemovalGate.plan(
            selection: ["b", "c", "d"], results: results, library: lib)
        #expect(plan.ids == ["c", "d"])
        #expect(plan.dropped[.gone] == ["b"])
    }

    @Test func aPhotoEditedMeanwhileIsLeftOut() async {
        let (lib, results) = setup()
        lib.update("c") { $0.modificationDate = Date(timeIntervalSince1970: 1_800_000_000) }
        let plan = await RemovalGate.plan(
            selection: ["b", "c", "d"], results: results, library: lib)
        #expect(plan.ids == ["b", "d"])
        #expect(plan.dropped[.changed] == ["c"])
        lib.update("b") { $0.hasAdjustments = true }
        let again = await RemovalGate.plan(selection: ["b", "d"], results: results, library: lib)
        #expect(again.dropped[.changed] == ["b"])
    }

    @Test func aPhotoThatBecameAFavoriteIsLeftOut() async {
        let (lib, results) = setup()
        lib.update("d") { $0.isFavorite = true }
        let plan = await RemovalGate.plan(selection: ["b", "d"], results: results, library: lib)
        #expect(plan.ids == ["b"])
        #expect(plan.dropped[.nowFavorite] == ["d"])
    }

    @Test func whenEveryKeeperIsGoneTheRestOfTheGroupIsLeftAlone() async {
        let (lib, results) = setup()
        lib.delete("a")
        let plan = await RemovalGate.plan(
            selection: ["b", "c", "d"], results: results, library: lib)
        // Removing b and c as well would lose the whole photo.
        #expect(plan.ids == ["d"])
        #expect(plan.dropped[.keeperGone] == ["b", "c"])
    }

    @Test func aGroupKeepsGoingIfAtLeastOneKeeperRemains() async {
        let (lib, _) = setup()
        var (_, results) = setup()
        results.categories[0].groups[0].keepers = ["a", "x"]
        lib.delete("a")
        let plan = await RemovalGate.plan(selection: ["b", "c"], results: results, library: lib)
        #expect(plan.ids == ["b", "c"])
    }

    @Test func aCopyWhoseGroupFellApartIsNotRemoved() async {
        // The keeper "a" was deleted and the group {b, c} lost a member too: "c" is a lone photo
        // in the results' items but in no group. It stays ticked in a stale selection.
        let (lib, results) = setup()
        let patched = results.removing(["a", "b"])
        #expect(patched.items["c"] != nil)
        #expect(patched.categories.flatMap(\.allMembers).contains("c") == false)
        let plan = await RemovalGate.plan(selection: ["c", "d"], results: patched, library: lib)
        #expect(plan.ids == ["d"])
        #expect(plan.dropped[.notSuggested] == ["c"])
    }

    @Test func aPhotoNotInTheResultsIsNeverRemoved() async {
        let (lib, results) = setup()
        let plan = await RemovalGate.plan(
            selection: ["b", "not-in-results"], results: results, library: lib)
        #expect(plan.ids == ["b"])
    }

    @Test func thePlanIsAValueLaterChangesDoNotReach() async {
        let (lib, results) = setup()
        var live = results
        let plan = await RemovalGate.plan(selection: ["b", "c"], results: live, library: lib)
        live = live.removing(["b", "c"])
        #expect(plan.ids == ["b", "c"])
        #expect(plan.results.category(.duplicates)?.groups.first?.members == ["a", "b", "c"])
        #expect(live.category(.duplicates) == nil)
    }

    @Test func theSummaryOfAPlanIsWhatTheSheetShows() async {
        let (lib, results) = setup()
        let plan = await RemovalGate.plan(
            selection: ["b", "c", "d"], results: results, library: lib)
        let preview = DefaultRemover(library: lib).summary(for: plan.ids, in: plan.results)
        #expect(preview.count == 3)
        #expect(preview.wholeGroupsSelected.isEmpty)
    }
}
