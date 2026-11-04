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

        // The category can hold other groups. How alike a photo and its crop are is Vision's to say, and
        // Vision says it differently on different releases: on iOS 26.5 (the CI runner) the edited pair
        // is a second group here, so the test does not assume the twins are all there is. What it is
        // about is that removing removes exactly what was selected, and so keeps the suggested best
        // shot of every group.
        let listed = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'category.item.'"))
            .allElementsBoundByIndex
        let selectedCount = listed.filter { $0.isSelected }.count
        let description = listed
            .map { "\($0.identifier.dropFirst("category.item.".count))\($0.isSelected ? "*" : "")" }
            .joined(separator: " ")
        XCTAssertGreaterThanOrEqual(selectedCount, 1)

        confirmRemoval(app)
        XCTAssertTrue(app.staticTexts["done.removed"].waitForExistence(timeout: 10))
        // "1 item removed", "2 items removed": the number comes first.
        let label = app.staticTexts["done.removed"].label
        let removed = Int(label.split(separator: " ").first ?? "") ?? -1
        XCTAssertEqual(
            removed, selectedCount,
            "“\(label)” after the category listed (* is selected): \(description)")
    }
}
