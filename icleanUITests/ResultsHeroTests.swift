import XCTest

/// Spec 011 section 6.3: Home says how much can be freed once, and the number, the Review bar and
/// the Confirm sheet agree because they read the same selection.
@MainActor
final class ResultsHeroTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    // MARK: Helpers

    private func hero(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["home.hero"].firstMatch
    }

    private func reviewBar(_ app: XCUIApplication) -> XCUIElement {
        app.buttons["results.reviewAll"]
    }

    private func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        return (1..<match.numberOfRanges).compactMap {
            Range(match.range(at: $0), in: text).map { String(text[$0]) }
        }
    }

    /// "You can free about 36 megabytes from 12 selected items. You choose what goes."
    private func heroFigures(_ app: XCUIApplication) -> (size: String, count: String) {
        let label = hero(app).label
        let parts = firstMatch(
            #"(\d[\d,.]* [A-Za-z]+) from ([\d,]+) (?:selected )?items?"#, in: label)
        XCTAssertNotNil(parts, "hero label: \(label)")
        return (parts?[0] ?? "", parts?[1] ?? "")
    }

    /// "Review 12 Items, about 36 megabytes"
    private func barFigures(_ app: XCUIApplication) -> (size: String, count: String) {
        let label = reviewBar(app).label
        let parts = firstMatch(
            #"Review ([\d,]+) Items?, (?:about )?(\d[\d,.]* [A-Za-z]+)"#, in: label)
        XCTAssertNotNil(parts, "review bar label: \(label)")
        return (parts?[1] ?? "", parts?[0] ?? "")
    }

    private func waitForLabel(
        _ element: XCUIElement, toChangeFrom old: String, timeout: TimeInterval = 10
    ) {
        expectation(
            for: NSPredicate(format: "label != %@", old), evaluatedWith: element)
        waitForExpectations(timeout: timeout)
    }

    private func back(_ app: XCUIApplication) {
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    // MARK: Tests

    func testHeroAndReviewBarAgreeAndFollowASelectionChange() {
        let app = launchApp()
        scan(app)
        XCTAssertTrue(hero(app).waitForExistence(timeout: 10))
        XCTAssertTrue(reviewBar(app).waitForExistence(timeout: 10))
        let hero1 = heroFigures(app)
        let bar1 = barFigures(app)
        XCTAssertEqual(hero1.count, bar1.count, "The hero and the Review bar count the same items")
        XCTAssertEqual(hero1.size, bar1.size, "The hero and the Review bar size the same items")
        XCTAssertTrue(
            hero(app).label.hasPrefix("You can free"), "hero label: \(hero(app).label)")

        // Keep one more copy: the hero and the bar both move, and still agree.
        let before = hero(app).label
        openCategory(app, "duplicates")
        XCTAssertTrue(item(app, "dup1-b").waitForExistence(timeout: 5))
        XCTAssertTrue(item(app, "dup1-b").isSelected)
        item(app, "dup1-b").tap()
        back(app)
        waitForLabel(hero(app), toChangeFrom: before)
        let hero2 = heroFigures(app)
        XCTAssertTrue(reviewBar(app).waitForExistence(timeout: 5))
        let bar2 = barFigures(app)
        XCTAssertEqual(hero2.count, bar2.count)
        XCTAssertEqual(hero2.size, bar2.size)
        XCTAssertEqual(
            Int(hero2.count), (Int(hero1.count) ?? 0) - 1, "One fewer item is selected")
    }

    func testReviewAllIsAButtonAndIsAbsentWhenNothingIsSelected() {
        let app = launchApp()
        scan(app)
        XCTAssertTrue(reviewBar(app).waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["results.reviewAll"].isHittable, "A Button, in reach")
        XCTAssertTrue(
            app.descendants(matching: .any)["results.reviewNote"].exists,
            "The reassurance sits with the bar")

        // Keep everything that was suggested: nothing is selected, so there is no Review bar at
        // all (hidden, not a disabled button), and the hero says so.
        for category in ["duplicates", "similar", "blurry", "screenshots"] {
            openCategory(app, category)
            let all = app.buttons["category.selectAll"]
            XCTAssertTrue(all.waitForExistence(timeout: 5))
            all.tap()
            back(app)
        }
        expectation(
            for: NSPredicate(format: "exists == false"), evaluatedWith: reviewBar(app))
        waitForExpectations(timeout: 10)
        XCTAssertTrue(hero(app).label.contains("Nothing selected yet"), hero(app).label)
        // The categories are still there to open.
        XCTAssertTrue(app.descendants(matching: .any)["results.category.duplicates"].exists)

        // Selecting again brings the bar back.
        openCategory(app, "screenshots")
        app.buttons["category.selectAll"].tap()
        back(app)
        XCTAssertTrue(reviewBar(app).waitForExistence(timeout: 10))
    }

    func testRemovingTheWholeSelectionFromTheBarStillShowsTheReceipt() {
        let app = launchApp()
        scan(app)
        let review = reviewBar(app)
        XCTAssertTrue(review.waitForExistence(timeout: 10))
        review.tap()
        let remove = app.buttons["confirm.remove"]
        XCTAssertTrue(remove.waitForExistence(timeout: 10))
        remove.tap()

        // The removal empties the selection, so the Review bar goes away underneath the sheet. The
        // sheet belongs to Home, not to the bar, so the receipt stays.
        let removed = app.staticTexts["done.removed"]
        XCTAssertTrue(removed.waitForExistence(timeout: 10))
        let close = app.buttons["done.close"]
        XCTAssertTrue(close.exists)
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(removed.exists, "The receipt survives the bar disappearing")
        XCTAssertTrue(close.exists)

        close.tap()
        expectation(
            for: NSPredicate(format: "exists == false"), evaluatedWith: reviewBar(app))
        waitForExpectations(timeout: 10)
        XCTAssertTrue(hero(app).waitForExistence(timeout: 5))
        XCTAssertTrue(hero(app).label.contains("Nothing selected yet"), hero(app).label)
    }

    /// A row with nothing selected must not sound as if its figure were selected: it says what could
    /// be freed. (On screen the figure reads "up to 924.2 MB", so the meaning does not rest on a gray.)
    func testARowWithNothingSelectedSpeaksTheTotalThatCouldBeFreed() {
        let app = launchApp()
        scan(app, expect: "results.category.largeVideos")
        let large = app.descendants(matching: .any)["results.category.largeVideos"].firstMatch
        XCTAssertTrue(large.label.hasPrefix("Large Videos, None selected, up to "), large.label)
        XCTAssertTrue(large.label.hasSuffix("could be freed"), large.label)
        XCTAssertFalse(large.label.contains("about"), large.label)
        // A row with a selection speaks the size of the selection first.
        let screenshots = app.descendants(matching: .any)["results.category.screenshots"].firstMatch
        XCTAssertTrue(screenshots.exists)
        XCTAssertTrue(screenshots.label.hasPrefix("Screenshots, "), screenshots.label)
        XCTAssertTrue(screenshots.label.contains("selected"), screenshots.label)
        XCTAssertFalse(screenshots.label.contains("could be freed"), screenshots.label)
    }

    func testTheHeroAndTheScanStatusWhileScanning() {
        // Every preview takes six seconds, so the scan is still going when the quick wins appear.
        let app = launchApp(scenario: "verySlow")
        app.buttons["home.scan"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["results.category.screenshots"].waitForExistence(
                timeout: 30))
        XCTAssertTrue(hero(app).waitForExistence(timeout: 10))
        XCTAssertTrue(
            hero(app).label.hasPrefix("So far you can free"), "hero label: \(hero(app).label)")
        // The card: a status, a bar, one count line, Pause and Stop.
        XCTAssertTrue(app.staticTexts["scan.status"].exists)
        XCTAssertTrue(app.buttons["scan.pause"].exists)
        XCTAssertTrue(app.buttons["scan.stop"].exists)
        let count = app.staticTexts.matching(
            NSPredicate(format: "label MATCHES %@", #"[\d,]+ of [\d,]+ checked"#)
        ).firstMatch
        XCTAssertTrue(count.exists, "The count is one text, \"<n> of <m> checked\"")
        // No scan or resume offer while scanning.
        XCTAssertFalse(app.buttons["home.scan"].exists)
        XCTAssertFalse(app.buttons["home.resume"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["results.empty"].exists)
    }
}
