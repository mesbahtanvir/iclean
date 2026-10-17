import XCTest

/// Story 4: clear out screenshots.
@MainActor
final class ScreenshotsFlowTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testAllScreenshotsAreListedAndSelected() {
        let app = launchApp()
        scan(app, expect: "results.category.screenshots")
        openCategory(app, "screenshots")
        for i in 0..<3 {
            XCTAssertTrue(item(app, "shot\(i)").waitForExistence(timeout: 5))
            XCTAssertTrue(item(app, "shot\(i)").isSelected)
        }
        XCTAssertFalse(item(app, "sharp").exists)
        confirmRemoval(app)
        XCTAssertTrue(app.staticTexts["done.removed"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["done.removed"].label, "3 items removed")
    }
}
