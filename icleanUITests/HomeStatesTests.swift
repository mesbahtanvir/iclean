import XCTest

/// Spec 012 section 6.2: Home is one of a few states, resolved in a fixed order, and each says one
/// thing. The Settings gear, the notices and the scan control behave the same in all of them.
@MainActor
final class HomeStatesTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func anything(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    func testAllowingAccessLeadsToTheFirstRunScreen() {
        let app = launchApp(scenario: "notDetermined")
        let allow = app.buttons["access.allow"]
        XCTAssertTrue(allow.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["home.scan"].exists, "Nothing is scanned before access")
        allow.tap()
        let scan = app.buttons["home.scan"]
        XCTAssertTrue(scan.waitForExistence(timeout: 10))
        XCTAssertEqual(scan.label, "Scan Library")
        XCTAssertFalse(app.buttons["access.allow"].exists)
    }

    func testFirstRunOffersOneProminentScanLibraryButton() {
        let app = launchApp()
        let scan = app.buttons["home.scan"]
        XCTAssertTrue(scan.waitForExistence(timeout: 10))
        XCTAssertEqual(scan.label, "Scan Library")
        // A large capsule in the middle of the screen, not a small row.
        XCTAssertGreaterThanOrEqual(scan.frame.height, 44)
        XCTAssertGreaterThanOrEqual(scan.frame.width, 120)
        XCTAssertTrue(app.staticTexts["Find photos you can clean up"].exists)
        // Nothing to say about results yet, and nothing to resume.
        XCTAssertFalse(anything(app, "home.hero").exists)
        XCTAssertFalse(app.buttons["home.resume"].exists)
        XCTAssertFalse(anything(app, "home.lastScan").exists)
        XCTAssertFalse(anything(app, "results.empty").exists)
        XCTAssertTrue(app.buttons["home.settings"].exists)
    }

    func testLimitedAccessNoteIsThereInTheFirstScreenAndInTheList() {
        let app = launchApp(scenario: "limited")
        XCTAssertTrue(app.buttons["home.scan"].waitForExistence(timeout: 10))
        XCTAssertTrue(anything(app, "home.limitedAccess").exists)
        scan(app)
        let note = anything(app, "home.limitedAccess")
        var swipes = 0
        while !note.exists && swipes < 4 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(note.exists, "The note is the last thing in the list")
    }

    func testAnUnreadableStoreShowsOnlyTheNoticeAndTheGear() {
        let app = launchApp(extraArguments: ["-DemoStoreProblem", "failed"])
        XCTAssertTrue(anything(app, "home.storeUnreadable").waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["home.settings"].exists)
        // Never "nothing to clean up", and nothing to start from here.
        XCTAssertFalse(anything(app, "results.empty").exists)
        XCTAssertFalse(app.buttons["home.scan"].exists)
        XCTAssertFalse(app.buttons["home.resume"].exists)
    }

    func testAStoreThatKeepsNothingIsAFootnoteAndScanningStillWorks() {
        let app = launchApp(extraArguments: ["-DemoStoreProblem", "volatile"])
        XCTAssertTrue(app.buttons["home.scan"].waitForExistence(timeout: 10))
        XCTAssertTrue(anything(app, "home.storeVolatile").exists)
        XCTAssertTrue(app.buttons["home.settings"].exists)
    }

    func testTheSettingsGearIsInEveryState() {
        let app = launchApp(scenario: "slow")
        let gear = app.buttons["home.settings"]
        XCTAssertTrue(gear.waitForExistence(timeout: 10), "first run")
        app.buttons["home.scan"].tap()
        XCTAssertTrue(app.buttons["scan.pause"].waitForExistence(timeout: 10))
        XCTAssertTrue(gear.exists, "while scanning")
        XCTAssertTrue(
            anything(app, "results.category.duplicates").waitForExistence(timeout: 90))
        XCTAssertTrue(gear.exists, "with results")
    }

    /// Pause and Resume are one button whose words change, and Stop has a 44 pt hit area both ways.
    func testPauseBecomesResumeAndBack() {
        let app = launchApp(scenario: "slow")
        app.buttons["home.scan"].tap()
        let pause = app.buttons["scan.pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 10))
        XCTAssertEqual(pause.label, "Pause")
        // Rounded: a frame at a third-of-a-point offset under the large title comes back as
        // 43.99999999999994, which is 44.
        XCTAssertGreaterThanOrEqual(pause.frame.height.rounded(), 44)
        let stop = app.buttons["scan.stop"]
        XCTAssertGreaterThanOrEqual(stop.frame.width.rounded(), 44)
        XCTAssertGreaterThanOrEqual(stop.frame.height.rounded(), 44)
        pause.tap()
        let resume = app.buttons["scan.resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 10))
        XCTAssertEqual(resume.label, "Resume")
        XCTAssertFalse(app.buttons["scan.pause"].exists)
        XCTAssertTrue(anything(app, "scan.status").label.hasPrefix("Paused"))
        XCTAssertGreaterThanOrEqual(app.buttons["scan.stop"].frame.width, 44)
        resume.tap()
        XCTAssertTrue(app.buttons["scan.pause"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["scan.resume"].exists)
    }

    func testStoppingAFirstScanOffersScanLibraryAndNoResume() {
        let app = launchApp(scenario: "slow")
        app.buttons["home.scan"].tap()
        let stop = app.buttons["scan.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        stop.tap()
        // Stop keeps what was found and there is no resume after a stop in the same session: the
        // control is the one that starts a scan, and no full scan has finished yet.
        let scan = app.buttons["home.scan"]
        XCTAssertTrue(scan.waitForExistence(timeout: 30))
        XCTAssertEqual(scan.label, "Scan Library")
        XCTAssertFalse(app.buttons["home.resume"].exists)
        XCTAssertFalse(anything(app, "home.lastScan").exists)
        XCTAssertFalse(app.buttons["scan.pause"].exists)
    }

    func testACleanLibraryEndsInNothingToCleanUp() {
        let app = launchApp(scenario: "clean")
        scan(app, expect: "results.empty")
        XCTAssertTrue(app.staticTexts["Nothing to clean up"].exists)
        let description = app.staticTexts.matching(
            NSPredicate(
                format: "label BEGINSWITH 'We checked' OR label BEGINSWITH 'No duplicates'")
        ).firstMatch
        XCTAssertTrue(description.exists)
        let again = app.buttons["home.scan"]
        XCTAssertTrue(again.exists)
        XCTAssertEqual(again.label, "Scan Again")
        XCTAssertFalse(anything(app, "results.category.duplicates").exists)
        XCTAssertFalse(app.buttons["results.reviewAll"].exists)
        XCTAssertTrue(app.buttons["home.settings"].exists)
    }

    func testAnEmptyLibraryEndsInNoPhotosToCheck() {
        let app = launchApp(scenario: "empty")
        scan(app, expect: "results.empty")
        XCTAssertTrue(app.staticTexts["No photos to check"].exists)
        XCTAssertFalse(app.staticTexts["Nothing to clean up"].exists)
    }

    func testRemovingEverythingEndsInAllCleanedUp() {
        let app = launchApp()
        scan(app)
        let review = app.buttons["results.reviewAll"]
        XCTAssertTrue(review.waitForExistence(timeout: 10))
        review.tap()
        let remove = app.buttons["confirm.remove"]
        XCTAssertTrue(remove.waitForExistence(timeout: 10))
        remove.tap()
        let close = app.buttons["done.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        close.tap()

        // Large Videos is never preselected: choose them too, and remove those.
        openCategory(app, "largeVideos")
        let all = app.buttons["category.selectAll"]
        XCTAssertTrue(all.waitForExistence(timeout: 5))
        all.tap()
        confirmRemoval(app)
        let closeAgain = app.buttons["done.close"]
        XCTAssertTrue(closeAgain.waitForExistence(timeout: 10))
        // Nothing is left in Large Videos, so closing the receipt goes back to Home by itself.
        closeAgain.tap()

        XCTAssertTrue(anything(app, "results.empty").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["All cleaned up"].exists)
        XCTAssertTrue(app.buttons["home.scan"].exists)
    }

    func testAnInterruptedScanOffersResumeAndNotScanAfterARelaunch() {
        var app = launchApp(
            scenario: "slow", extraArguments: ["-PersistStore", "-ResetStore", "-ChunkSize", "4"])
        app.buttons["home.scan"].tap()
        XCTAssertTrue(app.buttons["scan.pause"].waitForExistence(timeout: 10))
        sleep(5)
        app.terminate()

        app = launchApp(scenario: "slow", extraArguments: ["-PersistStore", "-ChunkSize", "4"])
        XCTAssertTrue(app.buttons["home.resume"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["home.scan"].exists, "There is never both Resume and Scan")
        XCTAssertTrue(app.buttons["home.settings"].exists)
    }

    // MARK: Accessibility

    /// Contrast is skipped like in AccessibilityTests: the demo photos have arbitrary colours.
    private let audit: XCUIAccessibilityAuditType = .all.subtracting(.contrast)

    /// A system list header: iOS caps how far its text grows, and the audit reports that for every
    /// section header (AccessibilityTests allows the same kind of system-capped text). The Review bar
    /// is capped at accessibility1 on purpose.
    private let systemCapped: Set<String> = [
        "results.foundSoFar", "results.reviewAll.title", "results.reviewAll.size",
    ]

    /// Fails on any issue, and says which element it is.
    private func runAudit(_ app: XCUIApplication, _ screen: String) throws {
        try app.performAccessibilityAudit(for: audit) { issue in
            let element = issue.element
            if issue.auditType == .dynamicType,
                self.systemCapped.contains(element?.identifier ?? "")
            {
                return true
            }
            print(
                "AUDIT [\(screen)] \(issue.compactDescription) | id \(element?.identifier ?? "-") | label \(element?.label ?? "-") | frame \(element.map { "\($0.frame)" } ?? "-")"
            )
            return false
        }
    }

    func testTheScanCardPassesTheAccessibilityAudit() throws {
        let app = launchApp(scenario: "slow")
        app.buttons["home.scan"].tap()
        XCTAssertTrue(app.buttons["scan.pause"].waitForExistence(timeout: 10))
        // With a count and a bar (not the indeterminate start).
        let count = app.staticTexts.matching(
            NSPredicate(format: "label MATCHES %@", #"[\d,]+ of [\d,]+ checked"#)
        ).firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 15))
        try runAudit(app, "scanning")
    }

    func testTheOneSentenceStatesPassTheAccessibilityAudit() throws {
        let clean = launchApp(scenario: "clean")
        scan(clean, expect: "results.empty")
        try runAudit(clean, "clean")
        clean.terminate()

        let empty = launchApp(scenario: "empty")
        scan(empty, expect: "results.empty")
        try runAudit(empty, "empty library")
        empty.terminate()

        let limited = launchApp(scenario: "limited")
        XCTAssertTrue(anything(limited, "home.limitedAccess").waitForExistence(timeout: 10))
        try runAudit(limited, "limited")
    }
}
