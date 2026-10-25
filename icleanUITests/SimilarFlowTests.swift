import XCTest

/// Story 3: thin out similar shots.
@MainActor
final class SimilarFlowTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testKeepingTheSuggestionRemovesOnlyTheRest() {
        let app = launchApp()
        scan(app, expect: "results.category.similar")
        openCategory(app, "similar")
        // Two shots of one moment are one group with one suggested best shot (the burst frames are
        // the Bursts category's since spec 015).
        XCTAssertTrue(item(app, "twin0").waitForExistence(timeout: 10))
        let selected = (0..<2).filter { item(app, "twin\($0)").isSelected }
        XCTAssertEqual(selected.count, 1)
        XCTAssertFalse(item(app, "burst0").exists)
        confirmRemoval(app)
        XCTAssertTrue(app.staticTexts["done.removed"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["done.removed"].label, "1 item removed")
    }
}
