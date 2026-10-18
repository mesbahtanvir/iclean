import XCTest

/// The debug screen for the baseline photo library. It is a Debug-only tool, so the test
/// only checks that it opens and offers its three actions; the library check itself needs
/// real Photos access and is run with `scripts/run-baseline.sh`.
@MainActor
final class BaselineLibraryTests: XCTestCase {
    func testTheBaselineScreenOpensFromSettings() {
        let app = launchApp()
        app.buttons["home.settings"].tap()
        let link = app.descendants(matching: .any)["settings.baseline"].firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 5), "Debug builds list the baseline screen")
        link.tap()

        XCTAssertTrue(app.buttons["baseline.run"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["baseline.import"].exists)
        XCTAssertTrue(app.buttons["baseline.remove"].exists)
        XCTAssertEqual(app.staticTexts["baseline.status"].firstMatch.label, "Ready")
    }
}
