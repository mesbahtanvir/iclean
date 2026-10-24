import XCTest

/// Spec 015, Story 3: clear out screen recordings.
@MainActor
final class ScreenRecordingsFlowTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testAllAreListedNoneSelectedAndOnlyTheChosenOneIsRemoved() {
        let app = launchApp()
        scan(app, expect: "results.category.screenRecordings")
        openCategory(app, "screenRecordings")
        let newest = item(app, "rec2")
        XCTAssertTrue(newest.waitForExistence(timeout: 5))
        for i in 0..<3 { XCTAssertFalse(item(app, "rec\(i)").isSelected) }
        // Newest first.
        XCTAssertLessThan(item(app, "rec2").frame.minY, item(app, "rec0").frame.minY)
        XCTAssertFalse(app.buttons["category.removeSelected"].isEnabled)
        newest.tap()
        confirmRemoval(app)
        XCTAssertTrue(app.staticTexts["done.removed"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["done.removed"].label, "1 item removed")
    }
}
