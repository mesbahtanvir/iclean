import Foundation
import Testing

@testable import CleanupKit

@Suite struct RouteValidatorTests {
    func results() -> CleanupResults {
        var items: [String: LibraryItem] = [:]
        for id in ["a", "b", "c", "d", "e", "f"] { items[id] = Make.item(Make.meta(id)) }
        let dup = ResultGroup(type: .duplicatePhotos, members: ["a", "b", "c"], keepers: ["a"])
        let dup2 = ResultGroup(type: .duplicatePhotos, members: ["d", "e"], keepers: ["d"])
        let blurry = ResultGroup(type: .single, members: ["f"])
        return CleanupResults(
            categories: [
                CategoryResult(category: .duplicates, groups: [dup, dup2]),
                CategoryResult(category: .blurry, groups: [blurry]),
            ], defaultSelection: [], notScannedCount: 0, items: items)
    }

    @Test func aValidPathIsKept() {
        let path: [Route] = [
            .category(.duplicates), .group(.duplicates, anchors: ["a", "b", "c"]),
        ]
        #expect(RouteValidator.validate(path, in: results()) == path)
    }

    @Test func aCategoryWithNoResultsFallsBackToHome() {
        #expect(RouteValidator.validate([.category(.screenshots)], in: results()).isEmpty)
        #expect(
            RouteValidator.validate(
                [.category(.similar), .group(.similar, anchors: ["a"])], in: results()
            ).isEmpty)
    }

    @Test func aGroupThatDissolvedFallsBackToItsCategory() {
        let path: [Route] = [
            .category(.duplicates), .group(.duplicates, anchors: ["gone1", "gone2"]),
        ]
        #expect(RouteValidator.validate(path, in: results()) == [.category(.duplicates)])
    }

    @Test func aGroupIsFoundAgainByAnyOfItsPhotosAndItsAnchorsAreRefreshed() {
        // The group lost "a" and "b" since the path was saved; "c" is still in it.
        var r = results()
        r.categories[0].groups[0] = ResultGroup(
            type: .duplicatePhotos, members: ["c", "x"], keepers: ["c"])
        let path: [Route] = [
            .category(.duplicates), .group(.duplicates, anchors: ["a", "b", "c"]),
        ]
        #expect(
            RouteValidator.validate(path, in: r) == [
                .category(.duplicates), .group(.duplicates, anchors: ["c", "x"]),
            ])
    }

    @Test func anAnchorThatMovedToAnotherGroupInTheCategoryFollowsIt() {
        let path: [Route] = [.category(.duplicates), .group(.duplicates, anchors: ["e"])]
        #expect(
            RouteValidator.validate(path, in: results()) == [
                .category(.duplicates), .group(.duplicates, anchors: ["d", "e"]),
            ])
    }

    @Test func aGroupRouteInTheWrongCategoryOrWithoutItsCategoryIsDropped() {
        #expect(
            RouteValidator.validate([.group(.duplicates, anchors: ["a"])], in: results()).isEmpty)
        #expect(
            RouteValidator.validate(
                [.category(.duplicates), .group(.blurry, anchors: ["f"])], in: results()) == [
                    .category(.duplicates)
                ])
        // Two categories in a row is not a path the app can produce.
        #expect(
            RouteValidator.validate([.category(.duplicates), .category(.blurry)], in: results())
                == [.category(.duplicates)])
    }

    @Test func theGroupARouteMeansIsResolved() {
        let route = Route.group(.duplicates, anchors: ["b"])
        #expect(RouteValidator.group(for: route, in: results())?.members == ["a", "b", "c"])
        #expect(
            RouteValidator.group(for: .group(.duplicates, anchors: ["zz"]), in: results()) == nil)
        #expect(RouteValidator.group(for: .category(.duplicates), in: results()) == nil)
    }

    @Test func routesRoundTripAndAnUnknownOneFailsToDecode() throws {
        let path: [Route] = [.category(.duplicates), .group(.duplicates, anchors: ["a", "b"])]
        let position = ReviewPosition(
            path: path, focusAssetID: "b", savedAt: Date(timeIntervalSince1970: 5),
            restoreAttempts: 1)
        let back = try StateCodec.open(try StateCodec.seal(position), as: ReviewPosition.self)
        #expect(back == position)
        #expect(throws: Error.self) {
            try JSONDecoder().decode([Route].self, from: Data(#"[{"settings":{}}]"#.utf8))
        }
    }

    @Test func autoRestoreNeedsAFreshPositionAndFewAttempts() {
        let saved = Date(timeIntervalSince1970: 1_700_000_000)
        let p = ReviewPosition(path: [.category(.duplicates)], savedAt: saved)
        #expect(p.shouldAutoRestore(now: saved.addingTimeInterval(23 * 3600)))
        #expect(!p.shouldAutoRestore(now: saved.addingTimeInterval(25 * 3600)))
        var tried = p
        tried.restoreAttempts = 1
        #expect(tried.shouldAutoRestore(now: saved))
        tried.restoreAttempts = 2
        #expect(!tried.shouldAutoRestore(now: saved))
        #expect(!ReviewPosition(path: [], savedAt: saved).shouldAutoRestore(now: saved))
    }
}
