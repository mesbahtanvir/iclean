import Foundation
import Testing

@testable import CleanupKit

@Suite struct ReviewIntentTests {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    func later(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    /// dup group {a (keeper), b, c}; similar group {d (keeper), e}; blurry singles f, g; fav h in dup group of {h(keeper? favorite), i}
    func results() -> CleanupResults {
        func item(_ id: String, favorite: Bool = false, modified: Date? = nil, w: Int = 4032)
            -> LibraryItem
        {
            var m = Make.meta(id, date: t0, width: w, height: 3024, favorite: favorite)
            m.modificationDate = modified ?? t0.addingTimeInterval(-1_000)
            return Make.item(m, sharpness: 0.5)
        }
        var items: [String: LibraryItem] = [:]
        for id in ["a", "b", "c", "d", "e", "f", "g", "i"] { items[id] = item(id) }
        items["h"] = item("h", favorite: true)
        let dup = ResultGroup(type: .duplicatePhotos, members: ["a", "b", "c"], keepers: ["a"])
        let fav = ResultGroup(type: .duplicatePhotos, members: ["h", "i"], keepers: ["h"])
        let sim = ResultGroup(type: .similarShots, members: ["d", "e"], keepers: ["d"])
        let blurry = [
            ResultGroup(type: .single, members: ["f"]), ResultGroup(type: .single, members: ["g"]),
        ]
        let big = ResultGroup(type: .single, members: ["f2"])
        _ = big
        let cats = [
            CategoryResult(category: .duplicates, groups: [dup, fav]),
            CategoryResult(category: .similar, groups: [sim]),
            CategoryResult(category: .blurry, groups: blurry),
        ]
        var r = CleanupResults(
            categories: cats, defaultSelection: [], notScannedCount: 0, items: items)
        r.defaultSelection = ReviewIntent.defaults(for: r, keepMarks: [])
        return r
    }

    func apply(
        _ intent: ReviewIntent, _ r: CleanupResults? = nil, marks: Set<String> = [],
        now: Date? = nil
    ) -> ReviewIntent.Applied {
        intent.apply(to: r ?? results(), keepMarks: marks, now: now ?? later(60))
    }

    // MARK: Defaults

    @Test func defaultsAreTheRemovablePhotosOfPreselectingCategoriesMinusProtected() {
        let d = ReviewIntent.defaults(for: results(), keepMarks: [])
        #expect(d == ["b", "c", "i", "e", "f", "g"])
        // A keep mark protects a photo even where it is not a favorite.
        #expect(
            ReviewIntent.defaults(for: results(), keepMarks: ["b"]) == ["c", "i", "e", "f", "g"])
    }

    @Test func noDecisionsGiveTheDefaults() {
        let a = apply(ReviewIntent())
        #expect(a.selection == a.results.defaultSelection)
        #expect(a.results.categories == results().categories)
    }

    // MARK: Selection

    @Test func aPhotoTheyUntickedStaysUnticked() {
        var i = ReviewIntent()
        i.setSelected(["b"], false, at: t0)
        #expect(apply(i).selection == ["c", "i", "e", "f", "g"])
    }

    @Test func aPhotoTheyTickedStaysTicked() {
        var i = ReviewIntent()
        i.setSelected(["a"], true, at: t0)
        #expect(apply(i).selection.contains("a"))
    }

    @Test func aTickOnACopyIsNotReplayedOnceThatCopyBecomesTheKeeper() {
        // The person ticked "b" (an ordinary copy). A rebuild then picks "b" as the kept copy.
        var i = ReviewIntent()
        i.setSelected(["b"], true, keepers: ["a", "d", "h"], at: t0)
        var r = results()
        r.categories[0].groups[0].keepers = ["b"]
        let a = apply(i, r)
        #expect(!a.selection.contains("b"), "the whole group must not end up selected")
        #expect(a.selection.contains("a"), "the former keeper is a removable copy now")
        // Ticking a keeper on purpose, knowing it is one, stays ticked.
        var on = ReviewIntent()
        on.setSelected(["a"], true, keepers: ["a", "d", "h"], at: t0)
        #expect(apply(on).selection.contains("a"))
    }

    @Test func aRemovableTickIsForgottenWithItsDecision() {
        var i = ReviewIntent()
        i.setSelected(["b"], true, keepers: ["a"], at: t0)
        #expect(i.removableTicks == ["b"])
        i.setSelected(["b"], false, keepers: ["a"], at: later(1))
        #expect(i.removableTicks.isEmpty)
        i.setSelected(["b"], true, keepers: ["a"], at: later(2))
        i.forget(["b"])
        #expect(i.removableTicks.isEmpty)
    }

    @Test func theLatestChoiceForAPhotoWins() {
        var i = ReviewIntent()
        i.setSelected(["b"], false, at: t0)
        i.setSelected(["b"], true, at: later(5))
        #expect(i.forcedOff["b"] == nil)
        #expect(apply(i).selection.contains("b"))
    }

    @Test func aRemoveDecisionIsDroppedWhenThePhotoIsGoneProtectedOrEditedSince() {
        var i = ReviewIntent()
        i.setSelected(["a", "zz", "h", "d"], true, at: t0)
        var r = results()
        // d was edited after the person ticked it.
        r.items["d"]?.metadata.modificationDate = later(10)
        let a = apply(i, r, marks: [])
        #expect(a.selection.contains("a"))
        #expect(!a.selection.contains("zz"))  // not in the results
        #expect(!a.selection.contains("h"))  // a favorite
        #expect(!a.selection.contains("d"))  // edited since
        // "always keep" protects too.
        #expect(!apply(i, results(), marks: ["a"]).selection.contains("a"))
    }

    @Test func aRemoveDecisionExpiresAfterAWeekButAKeepDecisionDoesNot() {
        var i = ReviewIntent()
        i.setSelected(["a"], true, at: t0)
        i.setSelected(["b"], false, at: t0)
        let week: TimeInterval = 7 * 86_400
        #expect(apply(i, now: t0.addingTimeInterval(week - 60)).selection.contains("a"))
        let old = apply(i, now: t0.addingTimeInterval(week + 60))
        #expect(!old.selection.contains("a"))
        #expect(!old.selection.contains("b"))
        // A keep decision is honoured for months.
        #expect(!apply(i, now: t0.addingTimeInterval(100 * 86_400)).selection.contains("b"))
        #expect(apply(i, now: t0.addingTimeInterval(200 * 86_400)).selection.contains("b"))
    }

    @Test func expireDropsOldDecisions() {
        var i = ReviewIntent()
        i.setSelected(["a"], true, at: t0)
        i.setSelected(["b"], false, at: t0)
        i.chooseKeeper("c", at: t0)
        i.expire(now: t0.addingTimeInterval(8 * 86_400))
        #expect(i.forcedOn.isEmpty && i.forcedOff["b"] != nil && i.keeperChoices["c"] != nil)
        i.expire(now: t0.addingTimeInterval(200 * 86_400))
        #expect(i.isEmpty)
    }

    // MARK: Keeper choices

    @Test func aChosenKeeperReplacesTheSuggestedOneAndTheOldOneBecomesRemovable() {
        var i = ReviewIntent()
        i.chooseKeeper("b", at: t0)
        let a = apply(i)
        let group = a.results.category(.duplicates)!.groups[0]
        #expect(group.keepers == ["b"])
        #expect(a.selection.contains("a"))
        #expect(!a.selection.contains("b"))
    }

    @Test func theLatestKeeperChoiceInAGroupWins() {
        var i = ReviewIntent()
        i.chooseKeeper("b", at: t0)
        i.chooseKeeper("c", at: later(10))
        #expect(apply(i).results.category(.duplicates)!.groups[0].keepers == ["c"])
        var reversed = ReviewIntent()
        reversed.chooseKeeper("c", at: t0)
        reversed.chooseKeeper("b", at: later(10))
        #expect(apply(reversed).results.category(.duplicates)!.groups[0].keepers == ["b"])
    }

    @Test func aFavoriteStaysAKeeperBesideTheChosenOne() {
        var i = ReviewIntent()
        i.chooseKeeper("i", at: t0)
        let g = apply(i).results.category(.duplicates)!.groups[1]
        #expect(g.keepers == ["h", "i"])
    }

    @Test func aKeeperChoiceForAGonePhotoChangesNothing() {
        var i = ReviewIntent()
        i.chooseKeeper("gone", at: t0)
        #expect(apply(i).results.categories == results().categories)
        // ...and a single (blurry) photo has no group to keep it in.
        var single = ReviewIntent()
        single.chooseKeeper("f", at: t0)
        #expect(apply(single).results.categories == results().categories)
    }

    @Test func aKeeperChoiceWorksInSimilarGroupsToo() {
        var i = ReviewIntent()
        i.chooseKeeper("e", at: t0)
        let g = apply(i).results.category(.similar)!.groups[0]
        #expect(g.keepers == ["e"])
        #expect(apply(i).selection.contains("d"))
    }

    @Test func choosingAKeeperDoesNotLeaveItMarkedForRemoval() {
        // The screen sequence from the review: tick K, Keep This One on R, then on K again.
        var i = ReviewIntent()
        i.setSelected(["b"], true, at: t0)
        i.chooseKeeper("c", at: later(1))
        i.chooseKeeper("b", at: later(2))
        #expect(i.forcedOn["b"] == nil)
        let a = apply(i)
        #expect(a.results.category(.duplicates)!.groups[0].keepers == ["b"])
        #expect(!a.selection.contains("b"))
    }

    // MARK: Forgetting and normalising

    @Test func forgetDropsEveryDecisionAboutThosePhotos() {
        var i = ReviewIntent()
        i.setSelected(["a"], true, at: t0)
        i.setSelected(["b"], false, at: t0)
        i.chooseKeeper("c", at: t0)
        i.forget(["a", "b", "c"])
        #expect(i.isEmpty)
    }

    @Test func normalizingDropsDecisionsThatOnlyRepeatTheDefaults() {
        var i = ReviewIntent()
        let defaults: Set<String> = ["b", "c"]
        i.setSelected(["b"], true, at: t0)  // already selected by default: redundant
        i.setSelected(["a"], true, at: t0)  // differs: kept
        i.setSelected(["x"], false, at: t0)  // already off by default: redundant
        i.setSelected(["c"], false, at: t0)  // differs: kept
        let n = i.normalized(against: defaults)
        #expect(Set(n.forcedOn.keys) == ["a"] && Set(n.forcedOff.keys) == ["c"])
    }

    @Test func replayIsTheSameWhateverTheOrderThePhotosAreListedIn() {
        var i = ReviewIntent()
        i.chooseKeeper("c", at: t0)
        i.setSelected(["a", "f"], false, at: later(1))
        i.setSelected(["g"], true, at: later(2))
        let base = apply(i)
        var shuffled = results()
        shuffled.categories = shuffled.categories.map { c in
            var c = c
            c.groups = c.groups.reversed()
            return c
        }
        let again = apply(i, shuffled)
        #expect(again.selection == base.selection)
    }

    // MARK: The saved shape

    @Test func decisionsRoundTripThroughTheCodec() throws {
        var i = ReviewIntent()
        i.setSelected(["a", "b"], true, at: t0)
        i.setSelected(["c"], false, at: later(3))
        i.chooseKeeper("d", at: later(9))
        let back = try StateCodec.open(try StateCodec.seal(i), as: ReviewIntent.self)
        #expect(back == i)
    }

    @Test func aBigSelectionStaysSmallWhenSaved() throws {
        var i = ReviewIntent()
        let ids = (0..<20_000).map { "ABCDEF12-3456-7890-ABCD-EF1234567890/L0/\($0)" }
        i.setSelected(ids, true, at: t0)
        let bytes = try StateCodec.seal(i).count
        #expect(bytes < 1_500_000)
    }
}
