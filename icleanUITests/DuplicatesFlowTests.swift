import XCTest

/// Story 1: remove duplicate photos.
@MainActor
final class DuplicatesFlowTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testDuplicatesAreGroupedWithOneKeeperAndRemoved() {
        let app = launchApp()
        scan(app)
        openCategory(app, "duplicates")

        // Group 1: the full-size original is kept; the copies are selected.
        XCTAssertTrue(item(app, "dup1-a").waitForExistence(timeout: 5))
        XCTAssertFalse(item(app, "dup1-a").isSelected)
        XCTAssertTrue(item(app, "dup1-b").isSelected)
        XCTAssertTrue(item(app, "dup1-c").isSelected)
        // Group 2: the favorite is kept and never selected.
        XCTAssertFalse(item(app, "dup2-fav").isSelected)
        XCTAssertTrue(item(app, "dup2-a").isSelected)
        // Edited versions are not duplicates of their originals.
        XCTAssertFalse(item(app, "edit-crop").exists)

        confirmRemoval(app)
        XCTAssertTrue(app.staticTexts["done.removed"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["done.removed"].label, "3 items removed")
    }

    func testChangingTheKeeper() {
        let app = launchApp()
        scan(app)
        openCategory(app, "duplicates")
        let groupLink = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'category.group.'")).firstMatch
        XCTAssertTrue(groupLink.waitForExistence(timeout: 5))
        groupLink.tap()
        XCTAssertTrue(app.descendants(matching: .any)["group.compare"].waitForExistence(timeout: 5))
        // The columns load lazily in a horizontal scroller: wait for the button to be
        // there and tappable before using it.
        let keepThisOne = app.buttons["group.makeKeeper"].firstMatch
        XCTAssertTrue(keepThisOne.waitForExistence(timeout: 5))
        keepThisOne.tap()
        // On this screen the previous keeper's "Remove" switch turns on. Waiting for it
        // proves the change happened before leaving; without that the test failed about
        // half the runs, also before the 002/003 work.
        let previousKeeper = app.switches["group.toggle.dup1-a"]
        expectation(for: NSPredicate(format: "value == '1'"), evaluatedWith: previousKeeper)
        waitForExpectations(timeout: 8)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        // The previous keeper is now selected for removal in the list as well.
        XCTAssertTrue(item(app, "dup1-a").waitForExistence(timeout: 5))
        expectation(
            for: NSPredicate(format: "isSelected == true"), evaluatedWith: item(app, "dup1-a"))
        waitForExpectations(timeout: 5)
    }

    func testCancellingRemovesNothing() {
        let app = launchApp()
        scan(app)
        openCategory(app, "duplicates")
        app.buttons["category.removeSelected"].tap()
        let cancel = app.buttons["confirm.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
        XCTAssertTrue(item(app, "dup1-b").exists)
    }

    func testCancelledSystemPromptRemovesNothing() {
        let app = launchApp(scenario: "cancelRemoval")
        scan(app)
        openCategory(app, "duplicates")
        confirmRemoval(app)
        XCTAssertTrue(item(app, "dup1-b").waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["done.removed"].exists)
    }
}
