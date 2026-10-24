import XCTest

/// Spec 015, Story 1: keep one frame of each burst.
@MainActor
final class BurstsFlowTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testThePickedFrameIsKeptAndTheRestRemoved() {
        let app = launchApp()
        scan(app, expect: "results.category.bursts")
        openCategory(app, "bursts")
        // The five-frame burst: the frame picked in Photos is the keeper, the other four selected.
        XCTAssertTrue(item(app, "burst0").waitForExistence(timeout: 10))
        XCTAssertFalse(item(app, "burst2").isSelected)
        XCTAssertEqual((0..<5).filter { item(app, "burst\($0)").isSelected }.count, 4)
        // The three-frame burst: the favourite is the keeper.
        XCTAssertFalse(item(app, "burstb1").isSelected)
        XCTAssertEqual((0..<3).filter { item(app, "burstb\($0)").isSelected }.count, 2)
        // Keep one more frame: unselect it.
        item(app, "burst4").tap()
        confirmRemoval(app)
        XCTAssertTrue(app.staticTexts["done.removed"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["done.removed"].label, "5 items removed")
    }
}
