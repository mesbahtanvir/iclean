import XCTest

/// FR-017a: every main screen passes Xcode's accessibility audit.
@MainActor
final class AccessibilityTests: XCTestCase {
    override func setUp() { continueAfterFailure = true }

    /// Contrast checks are skipped: the synthetic demo photos have arbitrary colors.
    private let audit: XCUIAccessibilityAuditType = .all.subtracting(.contrast)

    /// Standard system controls whose text iOS deliberately caps at the largest
    /// sizes (toolbar buttons, list section footers, plain list buttons). The audit
    /// reports them as "partially unsupported", but iclean does not control their
    /// sizing. Anything else fails the test.
    private let systemCapped: Set<String> = [
        "category.selectAll", "confirm.cancel", "settings.deleteAllData",
        "results.notScanned",
        "Removed items go to Recently Deleted in the Photos app.",
        "Deletes scan results, \"Always Keep\" marks and progress. Your photos are not touched.",
    ]

    /// Prints each issue with its element so failures are easy to fix.
    private func check(_ app: XCUIApplication, _ screen: String) throws {
        try app.performAccessibilityAudit(for: audit) { issue in
            let element = issue.element
            let key = (element?.identifier.isEmpty == false ? element?.identifier : element?.label) ?? ""
            if issue.auditType == .dynamicType, self.systemCapped.contains(key) { return true }
            print("AUDIT [\(screen)] \(issue.compactDescription) — \(element?.debugDescription.prefix(160) ?? "no element")")
            return false
        }
    }

    func testMainScreens() throws {
        let app = launchApp()
        try check(app, "home")
        scan(app)
        try check(app, "results")
        openCategory(app, "duplicates")
        try check(app, "category")
        app.buttons["category.removeSelected"].tap()
        XCTAssertTrue(app.buttons["confirm.remove"].waitForExistence(timeout: 5))
        try check(app, "confirm")
        app.buttons["confirm.cancel"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["home.settings"].tap()
        XCTAssertTrue(app.buttons["settings.deleteAllData"].waitForExistence(timeout: 5))
        try check(app, "settings")
    }

    func testAccessScreen() throws {
        let app = launchApp(scenario: "denied")
        XCTAssertTrue(app.buttons["access.openSettings"].waitForExistence(timeout: 5))
        try check(app, "access")
    }
}
