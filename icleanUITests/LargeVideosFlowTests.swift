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
        // Free: videos are not analyzed, so two copies of one clip are not grouped: both are listed.
        XCTAssertTrue(item(app, "vid-hd").exists)
        XCTAssertTrue(item(app, "vid-sd").exists)
        XCTAssertFalse(app.buttons["category.removeSelected"].isEnabled)
        big.tap()
        confirmRemoval(app)
        XCTAssertTrue(app.staticTexts["done.removed"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["done.removed"].label, "1 item removed")
    }
}
