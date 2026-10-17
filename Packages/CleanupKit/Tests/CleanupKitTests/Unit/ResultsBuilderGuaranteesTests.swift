import Testing

@testable import CleanupKit

/// A detector that returns fixed groups, for testing the builder's guarantees.
struct StubDetector: CategoryDetector {
    var category: CleanupCategory
    var needsAnalysis = true
    var make: @Sendable ([LibraryItem]) -> [ResultGroup]
    func detect(items: [LibraryItem]) -> [ResultGroup] { make(items) }
}

@Suite struct ResultsBuilderGuaranteesTests {
    let items = [
        Make.item(Make.meta("a")), Make.item(Make.meta("b")), Make.item(Make.meta("c")),
        Make.item(Make.meta("fav", favorite: true)), Make.item(Make.meta("kept")),
        Make.item(Make.meta("cloud"), source: .notScanned),
        Make.item(Make.meta("vid", kind: .video, duration: 30)),
    ]

    /// Groups everything it is given into one duplicate group (keeper = first).
    var everythingDuplicate: StubDetector {
        StubDetector(category: .duplicates) { items in
            let ids = items.filter { $0.metadata.kind != .video }.map(\.assetID)
            return ids.count >= 2
                ? [ResultGroup(type: .duplicatePhotos, members: ids, keepers: [ids[0]])] : []
        }
    }

    /// Flags every item it is given as a single.
    func singles(_ c: CleanupCategory, needsAnalysis: Bool = true) -> StubDetector {
        StubDetector(category: c, needsAnalysis: needsAnalysis) { items in
            items.map { ResultGroup(type: .single, members: [$0.assetID]) }
        }
    }

    @Test func eachItemAppearsInOneCategory() {
        let builder = DefaultResultsBuilder(detectors: [singles(.blurry), everythingDuplicate])
        let results = builder.buildResults(items: items, keepMarks: [])
        let all = results.categories.flatMap(\.allMembers)
        #expect(all.count == Set(all).count)
        #expect(results.categories.map(\.category) == [.duplicates, .blurry])
    }

    @Test func protectedItemsAreNeverSelected() {
        let builder = DefaultResultsBuilder(detectors: [everythingDuplicate, singles(.blurry)])
        let results = builder.buildResults(items: items, keepMarks: ["kept"])
        #expect(!results.defaultSelection.contains("fav"))
        #expect(!results.defaultSelection.contains("kept"))
        let dup = results.category(.duplicates)!.groups[0]
        #expect(dup.keepers.isSuperset(of: ["fav", "kept"]))
    }

    @Test func protectedSinglesAreNotFlagged() {
        let builder = DefaultResultsBuilder(detectors: [singles(.blurry)])
        let results = builder.buildResults(items: items, keepMarks: ["kept"])
        let flagged = Set(results.category(.blurry)!.allMembers)
        #expect(!flagged.contains("fav"))
        #expect(!flagged.contains("kept"))
    }

    @Test func notScannedItemsAreSkippedUnlessMetadataOnly() {
        let analyzed = DefaultResultsBuilder(detectors: [singles(.blurry)])
            .buildResults(items: items, keepMarks: [])
        #expect(!analyzed.category(.blurry)!.allMembers.contains("cloud"))
        let metadataOnly = DefaultResultsBuilder(detectors: [singles(.screenshots, needsAnalysis: false)])
            .buildResults(items: items, keepMarks: [])
        #expect(metadataOnly.category(.screenshots)!.allMembers.contains("cloud"))
        #expect(analyzed.notScannedCount == 1)
    }

    @Test func keepersAreNeverSelected() {
        let results = DefaultResultsBuilder(detectors: [everythingDuplicate])
            .buildResults(items: items, keepMarks: [])
        let group = results.category(.duplicates)!.groups[0]
        #expect(group.keepers.isDisjoint(with: results.defaultSelection))
        #expect(!group.keepers.isEmpty)
    }

    @Test func largeVideosAreNeverPreselected() {
        let results = DefaultResultsBuilder(detectors: [singles(.largeVideos, needsAnalysis: false)])
            .buildResults(items: items, keepMarks: [])
        #expect(!results.category(.largeVideos)!.allMembers.isEmpty)
        #expect(results.defaultSelection.isEmpty)
    }

    @Test func everythingElseIsPreselected() {
        let results = DefaultResultsBuilder(detectors: [singles(.screenshots, needsAnalysis: false)])
            .buildResults(items: items, keepMarks: [])
        #expect(results.defaultSelection == Set(results.category(.screenshots)!.allMembers))
    }

    @Test func everyGroupHasAKeeper() {
        let noKeeper = StubDetector(category: .similar) { items in
            [ResultGroup(type: .similarShots, members: ["a", "b"])]
        }
        let results = DefaultResultsBuilder(detectors: [noKeeper]).buildResults(items: items, keepMarks: [])
        #expect(results.category(.similar)!.groups[0].keepers.count == 1)
    }

    @Test func removingDropsEmptiedGroups() {
        let results = DefaultResultsBuilder(detectors: [everythingDuplicate])
            .buildResults(items: items, keepMarks: [])
        let ids = Set(results.category(.duplicates)!.removable)
        #expect(results.removing(ids).categories.isEmpty)
    }
}
