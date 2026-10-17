import XCTest

/// Launches the app against the DEBUG demo library (no real photos, no prompts).
@MainActor
extension XCTestCase {
    @discardableResult
    func launchApp(scenario: String = "standard", extraArguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UITesting", "-DemoScenario", scenario] + extraArguments
        app.launch()
        return app
    }

    /// Taps Scan and waits until results (or the clean state) appear.
    func scan(_ app: XCUIApplication, expect identifier: String = "results.category.duplicates") {
        let scanButton = app.buttons["home.scan"]
        XCTAssertTrue(scanButton.waitForExistence(timeout: 10))
        scanButton.tap()
        XCTAssertTrue(app.descendants(matching: .any)[identifier].waitForExistence(timeout: 60))
    }

    func openCategory(_ app: XCUIApplication, _ name: String) {
        let row = app.descendants(matching: .any)["results.category.\(name)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
    }

    func item(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)["category.item.\(id)"].firstMatch
    }

    func confirmRemoval(_ app: XCUIApplication) {
        app.buttons["category.removeSelected"].tap()
        let remove = app.buttons["confirm.remove"]
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.tap()
    }
}
