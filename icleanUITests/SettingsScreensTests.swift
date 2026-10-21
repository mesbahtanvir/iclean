import XCTest

/// Spec 009 sections 6.11 to 6.14: Settings, What iclean Remembers, Recent Scans and the restore
/// help. The delete and reset flows are also covered by EdgeCaseTests and PersistentSessionTests.
@MainActor
final class SettingsScreensTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    // MARK: Looking at the screens
    // With SCREENSHOT_DIR set (TEST_RUNNER_SCREENSHOT_DIR with xcodebuild) these tests also save a PNG
    // of what they check; SCREENSHOT_VARIANT=dark or largetext renders them that way. Otherwise inert.

    private var variant: String {
        ProcessInfo.processInfo.environment["SCREENSHOT_VARIANT"] ?? "light"
    }

    override func tearDown() async throws {
        if variant == "dark" { XCUIDevice.shared.appearance = .light }
    }

    /// The simulator needs a moment to switch before an app launched next picks it up.
    private func setAppearance(_ wanted: XCUIDevice.Appearance) {
        guard XCUIDevice.shared.appearance != wanted else { return }
        XCUIDevice.shared.appearance = wanted
        Thread.sleep(forTimeInterval: 2)
    }

    private func start(_ scenario: String = "standard", extra: [String] = []) -> XCUIApplication {
        setAppearance(variant == "dark" ? .dark : .light)
        var arguments = extra
        if variant == "largetext" {
            arguments += [
                "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL",
            ]
        }
        return launchApp(scenario: scenario, extraArguments: arguments)
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        guard let path = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"], !path.isEmpty else {
            return
        }
        Thread.sleep(forTimeInterval: 0.8)
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? app.screenshot().pngRepresentation.write(
            to: folder.appending(path: "\(variant)-\(name).png"))
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func openSettings(_ app: XCUIApplication) {
        let gear = app.buttons["home.settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 10))
        gear.tap()
        XCTAssertTrue(app.buttons["settings.deleteAllData"].waitForExistence(timeout: 5))
    }

    /// Closes a confirmation dialog without choosing: with its Cancel button where the system draws
    /// one, otherwise (a popover) by tapping outside it.
    private func dismissDialog(_ app: XCUIApplication) {
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.exists {
            cancel.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.96)).tap()
        }
    }

    /// Scrolls until the element is on screen (a long Form is lazy, and big text pushes rows down).
    private func reveal(_ app: XCUIApplication, _ element: XCUIElement) {
        var swipes = 0
        while !(element.exists && element.isHittable), swipes < 6 {
            app.swipeUp()
            swipes += 1
        }
    }

    private func open(_ app: XCUIApplication, _ id: String) {
        let row = element(app, id)
        XCTAssertTrue(row.waitForExistence(timeout: 5), id)
        row.tap()
    }

    func testSettingsIsThreePlacesAndOneDelete() {
        let app = start()
        openSettings(app)
        for id in ["settings.recentScans", "settings.savedData", "settings.restoreHelp"] {
            XCTAssertTrue(element(app, id).exists, id)
        }
        XCTAssertTrue(app.staticTexts["What iclean Remembers"].exists)
        // The Always Keep tool moved to the screen that explains it.
        XCTAssertFalse(element(app, "settings.clearKeepMarks").exists)
        XCTAssertFalse(app.buttons["Clear \"Always Keep\" Marks"].exists)
        shot(app, "settings")
    }

    func testDeleteAllDataAsksFirstAndCancelChangesNothing() {
        let app = start()
        openSettings(app)
        app.buttons["settings.deleteAllData"].tap()
        XCTAssertTrue(app.buttons["settings.confirmDelete"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts[
                "This removes scan results, your selections and Always Keep photos. Your photos are not touched."
            ].exists)
        shot(app, "settings-delete-dialog")
        dismissDialog(app)
        XCTAssertTrue(app.buttons["settings.deleteAllData"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["settings.confirmDelete"].exists)
    }

    func testRestoreHelpExplainsRecentlyDeleted() {
        let app = start()
        openSettings(app)
        open(app, "settings.restoreHelp")
        let steps = element(app, "restoreHelp.steps")
        XCTAssertTrue(steps.waitForExistence(timeout: 5))
        XCTAssertTrue(steps.label.contains("Recently Deleted"), steps.label)
        XCTAssertTrue(steps.label.contains("at least 30 days"), steps.label)
        XCTAssertTrue(steps.label.contains("Recover"), steps.label)
        shot(app, "restore-help")
    }

    func testWhatIcleanRemembersShowsNumbersThenOffersOnlyWhatApplies() {
        let app = start()
        scan(app)
        app.buttons["home.settings"].tap()
        open(app, "settings.savedData")

        // The rows carry their ids once the numbers are real.
        let results = element(app, "saved.results")
        XCTAssertTrue(results.waitForExistence(timeout: 5))
        XCTAssertFalse(results.label.contains("None"), results.label)
        XCTAssertTrue(element(app, "saved.choices").exists)
        let always = element(app, "saved.alwaysKeep")
        XCTAssertTrue(always.exists)
        XCTAssertTrue(always.label.contains("None"), always.label)
        shot(app, "remembers")

        // Nothing marked: no tool for it. No store problem: no delete.
        XCTAssertFalse(app.buttons["saved.clearAlwaysKeep"].exists)
        XCTAssertFalse(app.buttons["saved.erase"].exists)
        reveal(app, app.buttons["saved.resetChoices"])
        XCTAssertTrue(app.buttons["saved.clearResults"].exists)
        XCTAssertTrue(app.buttons["saved.resetChoices"].exists)
        shot(app, "remembers-tools")
    }

    func testResetNamesWhatItDoesAndCancelKeepsEverything() {
        let app = start()
        scan(app)
        app.buttons["home.settings"].tap()
        open(app, "settings.savedData")
        let reset = app.buttons["saved.resetChoices"]
        reveal(app, reset)
        XCTAssertTrue(reset.waitForExistence(timeout: 5))
        reset.tap()
        XCTAssertTrue(app.buttons["saved.confirmReset"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Reset Your Selections?"].exists)
        dismissDialog(app)
        XCTAssertTrue(app.buttons["saved.confirmReset"].waitForNonExistence(timeout: 5))
    }

    func testAlwaysKeepCanBeRemovedFromAllPhotosAfterAConfirmation() {
        let app = start()
        scan(app)
        openCategory(app, "duplicates")
        let photo = item(app, "dup1-a")
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        photo.press(forDuration: 0.8)
        let alwaysKeep = app.buttons["viewer.alwaysKeep"]
        XCTAssertTrue(alwaysKeep.waitForExistence(timeout: 5))
        alwaysKeep.tap()
        // Back to Home, then Settings.
        XCTAssertTrue(item(app, "dup1-b").waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["home.settings"].tap()
        open(app, "settings.savedData")

        let always = element(app, "saved.alwaysKeep")
        XCTAssertTrue(always.waitForExistence(timeout: 5))
        XCTAssertTrue(always.label.contains("1 photo"), always.label)
        let clear = app.buttons["saved.clearAlwaysKeep"]
        reveal(app, clear)
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        shot(app, "remembers-always-keep")
        clear.tap()
        // The dialog names how many photos it touches, and is not a delete.
        XCTAssertTrue(
            app.staticTexts["Remove Always Keep from 1 photo?"].waitForExistence(timeout: 5))
        let confirm = app.buttons["saved.confirmClearAlwaysKeep"].firstMatch
        XCTAssertTrue(confirm.exists)
        shot(app, "remembers-dialog")
        confirm.tap()
        expectation(
            for: NSPredicate(format: "label CONTAINS 'None'"),
            evaluatedWith: element(app, "saved.alwaysKeep"))
        waitForExpectations(timeout: 8)
        XCTAssertTrue(app.buttons["saved.clearAlwaysKeep"].waitForNonExistence(timeout: 5))
    }

    func testRecentScansListsAFullScanLedByOutcome() {
        let app = start()
        scan(app)
        app.buttons["home.settings"].tap()
        open(app, "settings.recentScans")
        let row = element(app, "settings.session")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.hasPrefix("Completed."), row.label)
        XCTAssertTrue(row.label.contains("Full scan"), row.label)
        XCTAssertTrue(row.label.contains("items checked"), row.label)
        shot(app, "recent-scans")
    }

    /// Every return to the app runs a quick check for new photos; they are one quiet line, not rows
    /// that push the real scans out of the list.
    func testQuickChecksAreOneQuietLineNotRows() {
        let app = start()
        scan(app)
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        app.activate()
        XCTAssertTrue(app.buttons["home.settings"].waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 3)
        app.buttons["home.settings"].tap()
        open(app, "settings.recentScans")
        XCTAssertTrue(element(app, "settings.session").waitForExistence(timeout: 5))

        let line = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'Checked for new photos'")
        ).firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 10))
        XCTAssertTrue(line.label.contains("· last"), line.label)
        let rows = app.descendants(matching: .any).matching(identifier: "settings.session")
        XCTAssertEqual(rows.count, 1, "Only the full scan is listed as a row")
        XCTAssertTrue(rows.firstMatch.label.contains("Full scan"))
        shot(app, "recent-scans-quick-checks")
    }

    func testRecentScansSaysSoWhenThereAreNone() {
        let app = start()
        openSettings(app)
        open(app, "settings.recentScans")
        XCTAssertTrue(element(app, "recentScans.empty").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No Scans Yet"].exists)
        XCTAssertFalse(element(app, "settings.session").exists)
        shot(app, "recent-scans-empty")
    }
}
