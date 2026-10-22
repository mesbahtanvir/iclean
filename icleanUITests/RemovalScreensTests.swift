import XCTest

/// Spec 011 sections 6.9 and 6.10: the Confirm sheet and the receipt. Removal itself is covered by
/// the flow tests; these look at what the person is told before and after.
@MainActor
final class RemovalScreensTests: XCTestCase {
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

    /// Scans, opens Duplicates and asks to remove what is selected (three photos in the demo).
    private func openConfirm(_ app: XCUIApplication) {
        scan(app)
        openCategory(app, "duplicates")
        let bar = app.buttons["category.removeSelected"]
        XCTAssertTrue(bar.waitForExistence(timeout: 10))
        bar.tap()
        XCTAssertTrue(app.buttons["confirm.remove"].waitForExistence(timeout: 10))
    }

    func testTheSheetSaysHowMuchWhereItGoesAndThatItCanComeBack() {
        let app = start()
        openConfirm(app)

        let summary = element(app, "confirm.summary")
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertTrue(summary.label.contains("about 4.8 MB"), summary.label)
        XCTAssertTrue(
            summary.label.contains("3 photos move to Recently Deleted."), summary.label)

        let reassurance = element(app, "confirm.reassurance")
        XCTAssertTrue(reassurance.exists)
        XCTAssertTrue(reassurance.label.contains("Nothing is erased yet"), reassurance.label)

        // The question is the title; the button names the destination and is not a warning.
        XCTAssertTrue(app.navigationBars["Remove 3 Photos?"].exists)
        let remove = app.buttons["confirm.remove"]
        XCTAssertEqual(remove.label, "Move 3 Photos to Recently Deleted")
        XCTAssertTrue(remove.isEnabled)
        XCTAssertTrue(remove.isHittable, "The button is always on screen")
        XCTAssertTrue(app.buttons["confirm.cancel"].exists)

        // One category: no breakdown. Nothing was dropped, nothing needs a second look.
        XCTAssertFalse(element(app, "confirm.removeAllWarning").exists)
        XCTAssertFalse(element(app, "confirm.dropped").exists)
        XCTAssertFalse(element(app, "confirm.error").exists)
        shot(app, "confirm")
    }

    func testCancellingLeavesEverythingAsItWas() {
        let app = start()
        openConfirm(app)
        app.buttons["confirm.cancel"].tap()
        XCTAssertTrue(item(app, "dup1-b").waitForExistence(timeout: 5))
        XCTAssertTrue(item(app, "dup1-b").isSelected)
        XCTAssertFalse(element(app, "confirm.remove").exists)
    }

    func testTheReceiptIsQuietAndHasOneControl() {
        let app = start()
        openConfirm(app)
        app.buttons["confirm.remove"].tap()

        let removed = app.staticTexts["done.removed"]
        XCTAssertTrue(removed.waitForExistence(timeout: 10))
        XCTAssertEqual(removed.label, "3 items removed")

        // The honest figure, not "freed": the space is back once Recently Deleted is emptied.
        let freed = app.staticTexts["done.freed"]
        XCTAssertTrue(freed.exists)
        XCTAssertTrue(freed.label.contains("about"), freed.label)
        XCTAssertTrue(freed.label.contains("once Recently Deleted is emptied"), freed.label)
        XCTAssertFalse(app.staticTexts["done.failures"].exists)

        // One plain sentence about time, the steps one tap away (the same ones as Settings), and
        // the iCloud caveat as a quiet note of its own.
        let restore = element(app, "done.restore")
        XCTAssertTrue(restore.exists)
        XCTAssertTrue(restore.label.contains("at least 30 days"), restore.label)
        XCTAssertTrue(restore.label.contains("erases them for good"), restore.label)
        XCTAssertTrue(element(app, "done.icloud").label.contains("iCloud"))
        XCTAssertFalse(element(app, "restoreHelp.steps").exists, "The steps start folded away")
        shot(app, "done")
        let howTo = element(app, "done.howTo")
        XCTAssertTrue(howTo.exists)
        XCTAssertTrue(howTo.label.contains("How to put them back"), howTo.label)
        howTo.tap()
        let steps = element(app, "restoreHelp.steps")
        XCTAssertTrue(steps.waitForExistence(timeout: 5))
        XCTAssertTrue(steps.label.contains("Recently Deleted"), steps.label)
        XCTAssertTrue(steps.label.contains("Recover"), steps.label)
        shot(app, "done-steps")
        // The only control is Done; the old Close and the Cancel are gone.
        XCTAssertTrue(app.buttons["done.close"].exists)
        XCTAssertFalse(app.buttons["confirm.cancel"].exists)
        XCTAssertFalse(app.buttons["Close"].exists)
        app.buttons["done.close"].tap()
        XCTAssertTrue(app.buttons["done.close"].waitForNonExistence(timeout: 5))
    }

    func testAPartialFailureIsOneCalmLine() {
        let app = start("removalFails")
        openConfirm(app)
        app.buttons["confirm.remove"].tap()
        let failures = app.staticTexts["done.failures"]
        XCTAssertTrue(failures.waitForExistence(timeout: 10))
        XCTAssertTrue(failures.label.contains("could not be removed"), failures.label)
        XCTAssertTrue(failures.label.contains("still in your library"), failures.label)
        XCTAssertEqual(app.staticTexts["done.removed"].label, "2 items removed")
        shot(app, "done-failure")
    }

    /// PhotoKit refuses the whole request: nothing was removed, so the receipt says only that. No
    /// "0 items removed", no honest figure, and no instructions for getting back photos that never left.
    func testWhenNothingWasRemovedTheReceiptSaysOnlyThat() {
        let app = start("removalFailsAll")
        openConfirm(app)
        app.buttons["confirm.remove"].tap()
        let removed = app.staticTexts["done.removed"]
        XCTAssertTrue(removed.waitForExistence(timeout: 10))
        XCTAssertEqual(removed.label, "Nothing was removed")
        let failures = app.staticTexts["done.failures"]
        XCTAssertTrue(failures.exists)
        XCTAssertTrue(failures.label.contains("3 items could not be removed"), failures.label)
        XCTAssertTrue(failures.label.contains("still in your library"), failures.label)
        XCTAssertFalse(app.staticTexts["done.freed"].exists)
        XCTAssertFalse(element(app, "done.restore").exists)
        XCTAssertFalse(element(app, "done.howTo").exists)
        XCTAssertFalse(element(app, "done.icloud").exists)
        shot(app, "done-nothing-removed")
        XCTAssertTrue(app.buttons["done.close"].exists)
    }

    func testRemovingEveryCopyNeedsAnExplicitYes() {
        let app = start()
        scan(app)
        openCategory(app, "duplicates")
        // Select the keeper of the first group too, so no copy of it would stay.
        let group = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'category.group.'")).firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 5))
        group.tap()
        let keeper = app.switches["group.toggle.dup1-a"]
        XCTAssertTrue(keeper.waitForExistence(timeout: 5))
        // The switch is at the trailing end of its row; a tap in the middle lands on the label.
        keeper.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        expectation(for: NSPredicate(format: "value == '1'"), evaluatedWith: keeper)
        waitForExpectations(timeout: 8)
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let bar = app.buttons["category.removeSelected"]
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        bar.tap()
        XCTAssertTrue(app.buttons["confirm.remove"].waitForExistence(timeout: 10))

        // A callout in words, not red; the toggle gates the button.
        let gate = app.switches["confirm.removeAllWarning"]
        XCTAssertTrue(gate.waitForExistence(timeout: 5))
        // The sheet opened tall because a photo meant to stay is selected: the switch is in reach
        // without scrolling.
        if variant != "largetext" { XCTAssertTrue(gate.isHittable) }
        XCTAssertTrue(app.staticTexts["Nothing will be kept from 1 set"].exists)
        XCTAssertFalse(app.buttons["confirm.remove"].isEnabled)
        XCTAssertTrue(element(app, "confirm.footnote").label.contains("Remove them all anyway"))
        shot(app, "confirm-callout")

        gate.tap()
        expectation(
            for: NSPredicate(format: "isEnabled == true"),
            evaluatedWith: app.buttons["confirm.remove"])
        waitForExpectations(timeout: 5)
    }

    func testConfirmStaysUsableAtTheLargestTextSize() {
        let app = start(extra: [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ])
        openConfirm(app)
        let remove = app.buttons["confirm.remove"]
        XCTAssertTrue(remove.isHittable, "The pinned button stays on screen")
        XCTAssertTrue(app.buttons["confirm.cancel"].isHittable)
        shot(app, "confirm-xxxl")
    }

    /// From Home the sheet covers every category: when there are two or more, a short breakdown
    /// says how many photos and how much each one is.
    func testSeveralCategoriesGetAShortBreakdown() {
        let app = start()
        scan(app)
        let all = app.buttons["results.reviewAll"]
        var swipes = 0
        while !(all.exists && all.isHittable), swipes < 4 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(all.isHittable)
        all.tap()
        XCTAssertTrue(app.buttons["confirm.remove"].waitForExistence(timeout: 10))

        func row(_ title: String) -> XCUIElement {
            app.descendants(matching: .any)
                .matching(NSPredicate(format: "label BEGINSWITH %@", "\(title), ")).firstMatch
        }
        XCTAssertTrue(row("Duplicates").waitForExistence(timeout: 5))
        XCTAssertTrue(row("Screenshots").exists)
        XCTAssertTrue(row("Duplicates").label.contains("photos"), row("Duplicates").label)
        XCTAssertTrue(element(app, "confirm.summary").label.contains("photos move to"))
        shot(app, "confirm-all")
        // Pull the sheet up to see the breakdown under the photos.
        element(app, "confirm.summary").swipeUp()
        shot(app, "confirm-all-rows")
    }
}
