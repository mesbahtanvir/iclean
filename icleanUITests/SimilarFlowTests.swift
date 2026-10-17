import XCTest

/// Story 3: thin out similar shots.
@MainActor
final class SimilarFlowTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testKeepingSeveralShotsRemovesOnlyTheRest() {
        let app = launchApp()
        scan(app, expect: "results.category.similar")
        openCategory(app, "similar")
        // The burst is one group with one suggested best shot.
        let selected = (0..<5).filter { item(app, "burst\($0)").isSelected }
        XCTAssertEqual(selected.count, 4)
        // Keep one more shot: unselect it.
        let extra = selected[0]
        item(app, "burst\(extra)").tap()
        confirmRemoval(app)
        XCTAssertTrue(app.staticTexts["done.removed"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["done.removed"].label, "3 items removed")
    }
}
