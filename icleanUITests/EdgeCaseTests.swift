import XCTest

/// Edge cases from the spec (quickstart Scenario 7).
@MainActor
final class EdgeCaseTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testLimitedAccessShowsBanner() {
        let app = launchApp(scenario: "limited")
        XCTAssertTrue(app.descendants(matching: .any)["home.limitedAccess"].waitForExistence(timeout: 5))
    }

    func testDeniedAccessScansNothing() {
        let app = launchApp(scenario: "denied")
        XCTAssertTrue(app.buttons["access.openSettings"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["home.scan"].exists)
    }

    func testNothingFound() {
        let app = launchApp(scenario: "empty")
        scan(app, expect: "results.empty")
    }

    func testPartialRemovalFailureIsReported() {
        let app = launchApp(scenario: "removalFails")
        scan(app)
        openCategory(app, "duplicates")
        confirmRemoval(app)
        XCTAssertTrue(app.staticTexts["done.failures"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["done.removed"].label, "2 items removed")
    }

    func testPhotoDeletedElsewhereDisappears() {
        let app = launchApp(scenario: "deleteDuringReview")
        scan(app)
        openCategory(app, "duplicates")
        XCTAssertTrue(item(app, "dup1-a").waitForExistence(timeout: 5))
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: item(app, "dup1-b"))
        waitForExpectations(timeout: 15)
    }

    func testInterruptedScanResumesAfterRelaunch() {
        var app = launchApp(scenario: "slow", extraArguments: ["-PersistStore", "-ResetStore"])
        app.buttons["home.scan"].tap()
        XCTAssertTrue(app.buttons["scan.pause"].waitForExistence(timeout: 5))
        sleep(3)
        app.terminate()
        app = launchApp(scenario: "slow", extraArguments: ["-PersistStore"])
        let resume = app.buttons["home.resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 10))
        resume.tap()
        XCTAssertTrue(app.descendants(matching: .any)["results.category.duplicates"].waitForExistence(timeout: 60))
    }

    func testDeleteAllData() {
        let app = launchApp()
        scan(app)
        app.buttons["home.settings"].tap()
        app.buttons["settings.deleteAllData"].tap()
        app.buttons["settings.confirmDelete"].firstMatch.tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["home.scan"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["results.category.duplicates"].exists)
    }
}
