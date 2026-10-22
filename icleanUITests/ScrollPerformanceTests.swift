import XCTest

/// How smoothly a long category scrolls, measured as frame hitches. Not part of the regular run
/// (a measurement, not a check): set `SCROLL_PERF=1` (`TEST_RUNNER_SCROLL_PERF=1` with `xcodebuild`).
///
/// It uses a 10,000-item demo library kept on disk (`-PersistStore`), so the first run scans and
/// every later run opens the saved results and goes straight to scrolling: runs before and after a
/// change are comparable.
@MainActor
final class ScrollPerformanceTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["SCROLL_PERF"] != nil else {
            throw XCTSkip("Set SCROLL_PERF=1 (TEST_RUNNER_SCROLL_PERF=1 with xcodebuild).")
        }
    }

    private func openLongCategory(_ category: String) -> XCUIApplication {
        let app = launchApp(
            scenario: "large10k", extraArguments: ["-PersistStore", "-DemoAnalysisLatencyMs", "0"])
        let row = app.descendants(matching: .any)["results.category.\(category)"]
        if !row.waitForExistence(timeout: 20) {
            // First run: nothing saved yet, so scan.
            let scan = app.buttons["home.scan"]
            XCTAssertTrue(scan.waitForExistence(timeout: 20))
            scan.tap()
            XCTAssertTrue(row.waitForExistence(timeout: 900), "no \(category) after the scan")
            // Let the scan finish so the measurement is not competing with it.
            XCTAssertTrue(
                app.staticTexts["scan.status"].waitForNonExistence(timeout: 900),
                "the scan did not end")
        }
        row.tap()
        let firstGroup = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'category.group.'")).firstMatch
        XCTAssertTrue(firstGroup.waitForExistence(timeout: 30))
        return app
    }

    /// Short on purpose: when a list is janky the test cannot reach "app idle" between swipes and
    /// each swipe takes a long time (the unfixed list needed about a minute per swipe).
    private func scrollThroughTheList(_ app: XCUIApplication) {
        for _ in 0..<3 { app.swipeUp(velocity: .fast) }
        for _ in 0..<3 { app.swipeDown(velocity: .fast) }
    }

    func testScrollingALongListOfGroups() throws {
        let app = openLongCategory("similar")
        var metrics: [XCTMetric] = [XCTClockMetric(), XCTCPUMetric(application: app)]
        if #available(iOS 26.0, *) { metrics.append(XCTHitchMetric(application: app)) }
        let options = XCTMeasureOptions()
        options.iterationCount = 2
        measure(metrics: metrics, options: options) { scrollThroughTheList(app) }
    }
}
