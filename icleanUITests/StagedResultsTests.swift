import XCTest

/// Spec 008: screenshots and large videos can be reviewed and removed while the photos are still
/// being checked. `verySlow` makes every preview take 6 s, so the scan is still going when the
/// first results appear.
@MainActor
final class StagedResultsTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testQuickWinsAppearBeforeAnyPhotoIsChecked() {
        let app = launchApp(scenario: "verySlow")
        app.buttons["home.scan"].tap()
        let screenshots = app.descendants(matching: .any)["results.category.screenshots"]
        XCTAssertTrue(screenshots.waitForExistence(timeout: 20))
        XCTAssertTrue(app.descendants(matching: .any)["results.category.largeVideos"].exists)
        // The scan is not over: still checking, nothing found among the photos yet, and the
        // header says these are the finds so far.
        XCTAssertTrue(app.buttons["scan.pause"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["results.category.duplicates"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["results.empty"].exists)
        XCTAssertTrue(
            app.descendants(matching: .any)["results.foundSoFar"].waitForExistence(timeout: 5))
    }

    func testScreenshotsCanBeRemovedWhileTheScanGoesOn() {
        let app = launchApp(scenario: "verySlow")
        app.buttons["home.scan"].tap()
        let screenshots = app.descendants(matching: .any)["results.category.screenshots"]
        XCTAssertTrue(screenshots.waitForExistence(timeout: 20))
        screenshots.tap()
        confirmRemoval(app)
        let done = app.buttons["done.close"]
        if done.waitForExistence(timeout: 10) { done.tap() }
        app.navigationBars.buttons.element(boundBy: 0).tap()
        // Back on Home the scan goes on and the removed screenshots do not come back.
        XCTAssertTrue(app.buttons["scan.pause"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["results.category.screenshots"].exists)
    }
}
