import XCTest

/// 002 quickstart Scenario 2: Scanning screen states and leave-and-return on the
/// simulator, which has no background task scheduler and so exercises the fallback.
@MainActor
final class BackgroundScanTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testScanningScreenSaysWhatHappensWhenYouLeave() {
        let app = launchApp(scenario: "slow")
        app.buttons["home.scan"].tap()
        XCTAssertTrue(app.buttons["scan.pause"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["scan.whenYouLeave"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["scan.status"].exists)
    }

    func testLeavingAndReturningKeepsTheScanGoingAndRemovesNothing() {
        let app = launchApp(scenario: "slow")
        app.buttons["home.scan"].tap()
        XCTAssertTrue(app.buttons["scan.pause"].waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        sleep(3)
        app.activate()
        // Still running (or resumed by itself); never stuck paused (FR-009, FR-010).
        let results = app.descendants(matching: .any)["results.category.duplicates"]
        XCTAssertTrue(app.buttons["scan.pause"].waitForExistence(timeout: 5) || results.exists)
        XCTAssertFalse(app.buttons["scan.resume"].exists)
        XCTAssertTrue(results.waitForExistence(timeout: 90))
        // A scan only suggests: every demo item is still there (FR-015).
        openCategory(app, "duplicates")
        XCTAssertTrue(item(app, "dup1-a").waitForExistence(timeout: 5))
        XCTAssertTrue(item(app, "dup1-b").exists)
    }
}
