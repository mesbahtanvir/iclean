import XCTest

/// Story 5: remove duplicate videos.
@MainActor
final class DuplicateVideosFlowTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testHigherQualityCopyIsKept() {
        let app = launchApp()
        scan(app, expect: "results.category.duplicateVideos")
        openCategory(app, "duplicateVideos")
        XCTAssertTrue(item(app, "vid-hd").waitForExistence(timeout: 5))
        XCTAssertFalse(item(app, "vid-hd").isSelected)
        XCTAssertTrue(item(app, "vid-sd").isSelected)
        confirmRemoval(app)
        XCTAssertTrue(app.staticTexts["done.removed"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["done.removed"].label, "1 item removed")
    }
}
