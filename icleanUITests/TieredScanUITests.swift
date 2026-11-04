import XCTest

/// Spec 017: while a tiered scan runs, Home shows its three tiers and groups the finds by the tier
/// that found them. These tests ask for tiers with `-Tiered on`; under `-UITesting` the other tests
/// still run the one-pass scan they were written for. `verySlow` makes every preview take 6 s, so
/// the photo check is still going when the first results appear.
@MainActor
final class TieredScanUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id]
    }

    func testTheThreeTiersAreShownAndQuickWinsAreReadyFirst() {
        let app = launchApp(scenario: "verySlow", extraArguments: ["-Tiered", "on"])
        app.buttons["home.scan"].tap()

        let quick = element(app, "scan.tier.instant")
        XCTAssertTrue(quick.waitForExistence(timeout: 20))
        XCTAssertTrue(element(app, "scan.tier.photos").exists)
        XCTAssertTrue(element(app, "scan.tier.deep").exists)

        // Quick wins are done before any photo is opened; the photo check is under way; the deep check
        // waits for it. The row says so in words, not only in a glyph.
        XCTAssertTrue(quick.label.contains("Ready"), quick.label)
        XCTAssertFalse(element(app, "scan.tier.photos").label.contains("Ready"))
        XCTAssertTrue(element(app, "scan.tier.deep").label.contains("Waiting"))
    }

    func testTheFindsAreGroupedByTierWhileTheScanRuns() {
        let app = launchApp(scenario: "verySlow", extraArguments: ["-Tiered", "on"])
        app.buttons["home.scan"].tap()

        XCTAssertTrue(element(app, "results.category.screenshots").waitForExistence(timeout: 20))
        // What the library describes without opening a photo is under "Ready now"; the groups for
        // the later tiers say what is coming; nothing is listed that the photo check has not found.
        XCTAssertTrue(element(app, "results.section.instant").exists)
        XCTAssertTrue(element(app, "results.section.photos").exists)
        XCTAssertTrue(element(app, "results.section.deep").exists)
        XCTAssertFalse(element(app, "results.category.duplicates").exists)
        XCTAssertTrue(app.buttons["scan.pause"].exists)
        // The Review bar and the hero work as in the one-pass scan.
        XCTAssertTrue(element(app, "home.hero").exists)
    }

    /// Spec 017 FR-010 and FR-015: in Low Power Mode the deep check does not start by itself, Home
    /// says so and offers it, and running it by hand finds what only it can find.
    func testLowPowerModeHoldsTheDeepCheckBackAndRunNowStartsIt() {
        let app = launchApp(
            scenario: "standard", extraArguments: ["-Tiered", "on", "-LowPowerMode", "on"])
        scan(app, expect: "results.category.duplicates")
        XCTAssertTrue(app.buttons["scan.pause"].waitForNonExistence(timeout: 60))

        // The photo check is done and the deep check is held: Home offers it and says why.
        let offer = element(app, "home.deepScan")
        XCTAssertTrue(offer.waitForExistence(timeout: 10))
        XCTAssertTrue(offer.label.contains("Run Now"), offer.label)
        XCTAssertTrue(offer.label.contains("Low Power Mode"), offer.label)
        // What only the deep check finds is not listed as if there were none.
        XCTAssertFalse(element(app, "results.category.similar").exists)

        offer.tap()
        XCTAssertTrue(element(app, "results.category.similar").waitForExistence(timeout: 60))
        XCTAssertTrue(element(app, "home.deepScan").waitForNonExistence(timeout: 60))
    }

    func testAScanEndsAsTheFlatListOfBefore() {
        let app = launchApp(scenario: "standard", extraArguments: ["-Tiered", "on"])
        scan(app, expect: "results.category.duplicates")
        // Both tiers have run: no scan card, no tier groups, no offer to look deeper.
        XCTAssertTrue(app.buttons["scan.pause"].waitForNonExistence(timeout: 60))
        XCTAssertFalse(element(app, "scan.tier.deep").exists)
        XCTAssertFalse(element(app, "results.section.deep").exists)
        XCTAssertFalse(element(app, "home.deepScan").exists)
        XCTAssertTrue(element(app, "results.category.duplicates").exists)
    }
}
