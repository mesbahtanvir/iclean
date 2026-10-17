import XCTest

/// Story 6: review large videos.
@MainActor
final class LargeVideosFlowTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testNothingIsPreselectedAndOnlyTheChosenVideoIsRemoved() {
        let app = launchApp()
        scan(app, expect: "results.category.largeVideos")
        openCategory(app, "largeVideos")
        let big = item(app, "vid-big")
        XCTAssertTrue(big.waitForExistence(timeout: 5))
        XCTAssertFalse(big.isSelected)
        // Videos already in a duplicate group are not listed again.
        XCTAssertFalse(item(app, "vid-sd").exists)
        XCTAssertFalse(app.buttons["category.removeSelected"].isEnabled)
        big.tap()
        confirmRemoval(app)
        XCTAssertTrue(app.staticTexts["done.removed"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["done.removed"].label, "1 item removed")
    }
}
