import XCTest

/// Story 2: remove blurry photos.
@MainActor
final class BlurryFlowTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testBlurryPhotosArePreselectedAndPortraitsExcluded() {
        let app = launchApp()
        scan(app, expect: "results.category.blurry")
        openCategory(app, "blurry")
        XCTAssertTrue(item(app, "blur1").waitForExistence(timeout: 5))
        XCTAssertTrue(item(app, "blur1").isSelected)
        XCTAssertTrue(item(app, "blur2").isSelected)
        XCTAssertFalse(item(app, "portrait").exists)
        XCTAssertFalse(item(app, "sharp").exists)
    }

    func testUnselectedPhotosAreKept() {
        let app = launchApp()
        scan(app, expect: "results.category.blurry")
        openCategory(app, "blurry")
        XCTAssertTrue(item(app, "blur1").waitForExistence(timeout: 5))
        item(app, "blur1").tap()
        XCTAssertFalse(item(app, "blur1").isSelected)
        confirmRemoval(app)
        XCTAssertTrue(app.staticTexts["done.removed"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["done.removed"].label, "1 item removed")
        app.buttons["done.close"].tap()
        XCTAssertTrue(item(app, "blur1").waitForExistence(timeout: 5))
    }

    func testAlwaysKeepFromTheViewer() {
        let app = launchApp()
        scan(app, expect: "results.category.blurry")
        openCategory(app, "blurry")
        let cell = item(app, "blur2")
        XCTAssertTrue(cell.waitForExistence(timeout: 5))
        // Long-press opens the full-screen viewer.
        cell.press(forDuration: 0.8)
        let keep = app.buttons["viewer.alwaysKeep"]
        XCTAssertTrue(keep.waitForExistence(timeout: 5))
        keep.tap()
        XCTAssertFalse(item(app, "blur2").waitForExistence(timeout: 2))
        // A new scan does not flag it again.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["home.scan"].tap()
        openCategory(app, "blurry")
        XCTAssertTrue(item(app, "blur1").waitForExistence(timeout: 30))
        XCTAssertFalse(item(app, "blur2").exists)
    }
}
