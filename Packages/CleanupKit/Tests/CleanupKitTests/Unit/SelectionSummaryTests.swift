import Foundation
import Testing

@testable import CleanupKit

/// The number the hero, the Review button and the Confirm sheet all read (spec 012 section 9).
@Suite struct SelectionSummaryTests {
    /// Many categories and groups, some sizes estimated, a few photos with no item at all.
    func results(groups: Int = 40) -> CleanupResults {
        var items: [String: LibraryItem] = [:]
        var duplicates: [ResultGroup] = []
        var similar: [ResultGroup] = []
        var singles: [ResultGroup] = []
        var n = 0
        func add(_ id: String, estimated: Bool = false) {
            var item = Make.item(Make.meta(id), size: Int64(1_000 + n * 7))
            if estimated { item.byteSize = nil }
            items[id] = item
            n += 1
        }
        for g in 0..<groups {
            let ids = (0..<3).map { "d\(g)-\($0)" }
            ids.forEach { add($0, estimated: g % 9 == 0 && $0.hasSuffix("-2")) }
            duplicates.append(
                ResultGroup(type: .duplicatePhotos, members: ids, keepers: [ids[0]]))
            let shots = (0..<4).map { "s\(g)-\($0)" }
            shots.forEach { add($0) }
            similar.append(ResultGroup(type: .similarShots, members: shots, keepers: [shots[1]]))
            let blur = "b\(g)"
            add(blur)
            singles.append(ResultGroup(type: .single, members: [blur]))
        }
        return CleanupResults(
            categories: [
                CategoryResult(category: .duplicates, groups: duplicates),
                CategoryResult(category: .similar, groups: similar),
                CategoryResult(category: .blurry, groups: singles),
            ], defaultSelection: [], notScannedCount: 0, items: items)
    }

    func randomSelection(from results: CleanupResults, seed: UInt64, extra: [String] = [])
        -> Set<String>
    {
        var state = seed
        func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state >> 33
        }
        var selection = Set(extra)
        for id in results.items.keys where next() % 3 == 0 { selection.insert(id) }
        return selection
    }

    // MARK: Equal to the old way of counting

    @Test func theSummaryEqualsTheRemoversOnRandomSelections() {
        let results = results()
        let remover = DefaultRemover(library: FakePhotoLibrary())
        let index = ResultsIndex(results)
        for seed in 1...25 as ClosedRange<UInt64> {
            // Photos that are not in the results are ignored by both.
            let selection = randomSelection(from: results, seed: seed, extra: ["gone-1", "gone-2"])
            let old = remover.summary(for: selection, in: results)
            let summary = SelectionSummary.make(selection: selection, index: index)
            #expect(summary.count == old.count)
            #expect(summary.bytes == old.bytes)
            #expect(summary.isEstimate == old.isEstimate)
            for (category, total) in old.byCategory {
                #expect(summary.perCategory[category]?.selected == total.count)
                #expect(summary.perCategory[category]?.selectedBytes == total.bytes)
            }
        }
    }

    @Test func aSelectedKeeperCountsAsSelectedButNotAsRemovable() {
        let results = results(groups: 2)
        let summary = SelectionSummary.make(
            selection: ["d0-0", "d0-1"], index: ResultsIndex(results))
        let tally = summary.perCategory[.duplicates]
        #expect(tally?.selected == 2)
        // d0-0 is the keeper of its group.
        #expect(tally?.selectedRemovable == 1)
    }

    @Test func nothingSelectedStillReportsEachCategorysTotals() {
        let results = results(groups: 3)
        let summary = SelectionSummary.make(selection: [], index: ResultsIndex(results))
        #expect(summary.count == 0 && summary.bytes == 0)
        #expect(summary.perCategory[.duplicates]?.members == 9)
        #expect(summary.perCategory[.duplicates]?.removable == 6)
        #expect(summary.perCategory[.duplicates]?.selected == 0)
        #expect(summary.perCategory[.blurry]?.removable == 3)
    }

    @Test func aCategoryTotalIsTheSizeOfWhatCouldBeRemoved() {
        let results = results(groups: 5)
        let index = ResultsIndex(results)
        let old = results.totals(for: .duplicates)
        #expect(index.categories[.duplicates]?.removable == old.count)
        #expect(index.categories[.duplicates]?.removableBytes == old.bytes)
    }

    // MARK: Scale

    @Test func totalsAtThirtyThousandPhotosAreFast() {
        let results = results(groups: 3_800)  // 8 photos a group: about 30,000
        #expect(results.items.count > 29_000)
        let selection = Set(results.items.keys.prefix(15_000))
        let start = ContinuousClock.now
        let index = ResultsIndex(results)
        let summary = SelectionSummary.make(selection: selection, index: index)
        let preview = DefaultRemover(library: FakePhotoLibrary()).summary(
            for: selection, in: results)
        let elapsed = ContinuousClock.now - start
        #expect(summary.count == preview.count && summary.bytes == preview.bytes)
        // The old way took tens of seconds here; a generous bound that still catches a return of it.
        #expect(elapsed < .seconds(5))
    }

    @Test func removingFifteenThousandPhotosFromThirtyThousandIsFast() {
        let results = results(groups: 3_800)
        let gone = Set(results.items.keys.prefix(15_000))
        let start = ContinuousClock.now
        let after = results.removing(gone)
        let elapsed = ContinuousClock.now - start
        // Each removed photo is gone, and a group that lost nothing is exactly as it was.
        #expect(after.items.count == results.items.count - gone.count)
        let before = Dictionary(
            uniqueKeysWithValues: results.categories.flatMap(\.groups).map { ($0.id, $0) })
        for group in after.categories.flatMap(\.groups) {
            #expect(group.members.allSatisfy { !gone.contains($0) })
            if let old = before[group.id], !old.members.contains(where: gone.contains) {
                #expect(group == old)
            }
        }
        // `Set.subtract` per group took ten seconds here.
        #expect(elapsed < .seconds(2))
    }
}
