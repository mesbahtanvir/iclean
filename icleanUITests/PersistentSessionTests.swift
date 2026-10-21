import XCTest

/// Spec 007: the results and the person's review survive a kill, and nothing outlives
/// Delete All Data. The app is killed, not backgrounded, so only what was already saved counts.
@MainActor
final class PersistentSessionTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func firstLaunch() -> XCUIApplication {
        launchApp(extraArguments: ["-PersistStore", "-ResetStore"])
    }

    /// Kills the app and starts it again on the same store.
    private func relaunch(_ app: XCUIApplication) -> XCUIApplication {
        app.terminate()
        return launchApp(extraArguments: ["-PersistStore"])
    }

    /// The writer saves a moment after a change (at most two seconds); a kill before that
    /// would lose it by design, so the tests wait for it.
    private func letItSave() { sleep(3) }

    private func waitUntil(_ element: XCUIElement, _ format: String, timeout: TimeInterval = 8) {
        expectation(for: NSPredicate(format: format), evaluatedWith: element)
        waitForExpectations(timeout: timeout)
    }

    func testSelectionAndPlaceSurviveAKill() {
        var app = firstLaunch()
        scan(app)
        openCategory(app, "duplicates")
        XCTAssertTrue(item(app, "dup1-b").waitForExistence(timeout: 5))
        XCTAssertTrue(item(app, "dup1-b").isSelected)
        item(app, "dup1-b").tap()
        waitUntil(item(app, "dup1-b"), "isSelected == false")
        letItSave()

        app = relaunch(app)
        // Back on the same screen with the same choices, and no new scan.
        XCTAssertTrue(item(app, "dup1-b").waitForExistence(timeout: 20))
        XCTAssertFalse(item(app, "dup1-b").isSelected, "The photo the person kept stays kept")
        XCTAssertTrue(item(app, "dup1-c").isSelected)
        // Nothing was scanned again: Home offers a scan and shows no scan in progress.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["home.scan"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["scan.pause"].exists)
    }

    func testAKeeperChoiceSurvivesAKill() {
        var app = firstLaunch()
        scan(app)
        openCategory(app, "duplicates")
        let groupLink = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'category.group.'")).firstMatch
        XCTAssertTrue(groupLink.waitForExistence(timeout: 5))
        groupLink.tap()
        let keepThisOne = app.buttons["group.makeKeeper"].firstMatch
        XCTAssertTrue(keepThisOne.waitForExistence(timeout: 5))
        keepThisOne.tap()
        // The previous keeper's Remove switch turns on once the choice is made.
        waitUntil(app.switches["group.toggle.dup1-a"], "value == '1'")
        letItSave()

        app = relaunch(app)
        XCTAssertTrue(
            app.descendants(matching: .any)["group.compare"].waitForExistence(timeout: 20))
        let previousKeeper = app.switches["group.toggle.dup1-a"]
        XCTAssertTrue(previousKeeper.waitForExistence(timeout: 10))
        waitUntil(previousKeeper, "value == '1'")
    }

    func testTheConfirmSheetIsNeverReopenedByARelaunch() {
        var app = firstLaunch()
        scan(app)
        openCategory(app, "duplicates")
        XCTAssertTrue(item(app, "dup1-b").waitForExistence(timeout: 5))
        app.buttons["category.removeSelected"].tap()
        XCTAssertTrue(app.buttons["confirm.remove"].waitForExistence(timeout: 10))
        letItSave()

        app = relaunch(app)
        XCTAssertTrue(item(app, "dup1-b").waitForExistence(timeout: 20))
        XCTAssertFalse(
            app.buttons["confirm.remove"].exists,
            "Nothing is removed without a new, fresh confirmation")
    }

    func testDeleteAllDataLeavesNothingToRestore() {
        var app = firstLaunch()
        scan(app)
        openCategory(app, "duplicates")
        XCTAssertTrue(item(app, "dup1-b").waitForExistence(timeout: 5))
        item(app, "dup1-b").tap()
        waitUntil(item(app, "dup1-b"), "isSelected == false")
        // Back to Home, then Settings, then Delete All Data.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 5))
        app.buttons["home.settings"].tap()
        app.buttons["settings.deleteAllData"].tap()
        let confirm = app.buttons["settings.confirmDelete"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        letItSave()

        app = relaunch(app)
        XCTAssertTrue(app.buttons["home.scan"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.descendants(matching: .any)["results.category.duplicates"].exists)
        XCTAssertFalse(item(app, "dup1-b").exists)

        // What is saved on this iPhone says the same: no results, no choices.
        app.buttons["home.settings"].tap()
        let saved = app.descendants(matching: .any)["settings.savedData"].firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        saved.tap()
        let results = app.descendants(matching: .any)["saved.results"].firstMatch
        XCTAssertTrue(results.waitForExistence(timeout: 5))
        XCTAssertTrue(results.label.contains("None"), "saved results: \(results.label)")
        let choices = app.descendants(matching: .any)["saved.choices"].firstMatch
        XCTAssertTrue(choices.label.hasSuffix("0"), "review choices: \(choices.label)")
    }

    func testResettingReviewChoicesGivesBackTheSuggestedKeeper() {
        let app = firstLaunch()
        scan(app)
        openCategory(app, "duplicates")
        let groupLink = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'category.group.'")).firstMatch
        XCTAssertTrue(groupLink.waitForExistence(timeout: 5))
        groupLink.tap()
        let keepThisOne = app.buttons["group.makeKeeper"].firstMatch
        XCTAssertTrue(keepThisOne.waitForExistence(timeout: 5))
        keepThisOne.tap()
        // The suggested keeper dup1-a is a removable copy now.
        waitUntil(app.switches["group.toggle.dup1-a"], "value == '1'")

        // Back to Home, then Settings, Saved on this iPhone, Reset Review Choices.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 5))
        app.buttons["home.settings"].tap()
        let saved = app.descendants(matching: .any)["settings.savedData"].firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        saved.tap()
        let reset = app.buttons["saved.resetChoices"]
        XCTAssertTrue(reset.waitForExistence(timeout: 5))
        reset.tap()
        let confirm = app.buttons["saved.confirmReset"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        // Back to the group: the builder's own keeper is the keeper again.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        openCategory(app, "duplicates")
        let again = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'category.group.'")).firstMatch
        XCTAssertTrue(again.waitForExistence(timeout: 10))
        again.tap()
        let previousKeeper = app.switches["group.toggle.dup1-a"]
        XCTAssertTrue(previousKeeper.waitForExistence(timeout: 10))
        waitUntil(previousKeeper, "value == '0'")
    }
}
