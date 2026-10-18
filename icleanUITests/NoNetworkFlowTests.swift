import XCTest

/// SC-006: the full flow works and makes zero network requests.
/// Run with the NoNetwork test plan (adds `-NetworkTripwire`).
@MainActor
final class NoNetworkFlowTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testFullFlowMakesNoNetworkRequests() {
        let app = launchApp(extraArguments: ["-NetworkTripwire"])
        scan(app)
        for category in ["duplicates", "similar", "blurry", "screenshots", "largeVideos"] {
            openCategory(app, category)
            XCTAssertTrue(app.buttons["category.removeSelected"].waitForExistence(timeout: 5))
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        let reviewAll = app.buttons["results.reviewAll"]
        XCTAssertTrue(reviewAll.waitForExistence(timeout: 5))
        reviewAll.tap()
        app.buttons["confirm.remove"].tap()
        XCTAssertTrue(app.staticTexts["done.removed"].waitForExistence(timeout: 10))
        app.buttons["done.close"].tap()

        let count = app.staticTexts["tripwire.count"]
        XCTAssertTrue(count.waitForExistence(timeout: 5))
        XCTAssertEqual(count.label, "0", "The app tried to use the network")
    }
}
