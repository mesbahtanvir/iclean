import XCTest

/// Story 3: thin out similar shots.
@MainActor
final class SimilarFlowTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testKeepingTheSuggestionRemovesOnlyTheRest() {
        let app = launchApp()
        scan(app, expect: "results.category.similar")
        openCategory(app, "similar")
        // Two shots of one moment are one group with one suggested best shot (the burst frames are
        // the Bursts category's since spec 015).
        XCTAssertTrue(item(app, "twin0").waitForExistence(timeout: 10))
        let selected = (0..<2).filter { item(app, "twin\($0)").isSelected }
        XCTAssertEqual(selected.count, 1)
        XCTAssertFalse(item(app, "burst0").exists)
        // Which photos the category lists and has selected, so a wrong count below says what it removed.
        let listed = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'category.item.'"))
            .allElementsBoundByIndex
            .map { "\($0.identifier.dropFirst("category.item.".count))\($0.isSelected ? "*" : "")" }
            .joined(separator: " ")
        confirmRemoval(app)
        XCTAssertTrue(app.staticTexts["done.removed"].waitForExistence(timeout: 10))
        XCTAssertEqual(
            app.staticTexts["done.removed"].label, "1 item removed",
            "the category listed (* is selected): \(listed)")
    }
}
