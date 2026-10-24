import XCTest

/// Spec 011: the person chooses how far Similar Shots looks.
@MainActor
final class LevelsFlowTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// Results are built again when a level is picked, so the list changes a moment after the tap.
    private func waitUntil(_ timeout: TimeInterval = 15, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }

    func testTheLevelOfSimilarShotsCanBeChangedAndWideSelectsNothing() {
        let app = launchApp()
        scan(app, expect: "results.category.similar")
        openCategory(app, "similar")
        func selectedFrames() -> Int { (0..<2).filter { item(app, "twin\($0)").isSelected }.count }

        let levels = app.descendants(matching: .any)["category.levels"]
        XCTAssertTrue(levels.waitForExistence(timeout: 10))
        let buttons = levels.buttons
        XCTAssertEqual(buttons.count, 3)
        // "Same shot" is today's behaviour and the default: the two shots are grouped, one selected.
        XCTAssertTrue(buttons.element(boundBy: 1).isSelected)
        XCTAssertTrue(item(app, "twin0").waitForExistence(timeout: 10))
        XCTAssertEqual(selectedFrames(), 1)

        // "Same scene" looks further and selects nothing for the person.
        buttons.element(boundBy: 2).tap()
        XCTAssertTrue(waitUntil { buttons.element(boundBy: 2).isSelected })
        XCTAssertTrue(item(app, "twin0").waitForExistence(timeout: 10))
        XCTAssertTrue(waitUntil { selectedFrames() == 0 }, "selected: \(selectedFrames())")

        // Back to "Same shot": the suggestion returns.
        buttons.element(boundBy: 1).tap()
        XCTAssertTrue(waitUntil { buttons.element(boundBy: 1).isSelected })
        XCTAssertTrue(waitUntil { selectedFrames() == 1 }, "selected: \(selectedFrames())")
    }
}
