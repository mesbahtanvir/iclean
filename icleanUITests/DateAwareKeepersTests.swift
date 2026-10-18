import XCTest

/// Copies of one photo with different dates: the copy whose date is most probably the real one is
/// the one suggested for keeping, and the group says why.
@MainActor
final class DateAwareKeepersTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testTheCopyWithTheMostLikelyDateIsKept() {
        let app = launchApp(scenario: "dates")
        scan(app)
        openCategory(app, "duplicates")

        // Exact copies: the one that keeps its capture date and location is kept, although the
        // other has a bigger file.
        XCTAssertTrue(item(app, "date-orig").waitForExistence(timeout: 5))
        XCTAssertFalse(item(app, "date-orig").isSelected)
        XCTAssertTrue(item(app, "date-resaved").isSelected)
        // A date that is the start of 1970 cannot be right: the lower resolution copy with a real
        // date is kept.
        XCTAssertFalse(item(app, "date-real").isSelected)
        XCTAssertTrue(item(app, "date-default").isSelected)
    }

    func testTheGroupSaysWhyADateLooksWrong() {
        let app = launchApp(scenario: "dates")
        scan(app)
        openCategory(app, "duplicates")
        let groupLinks = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'category.group.'"))
        XCTAssertTrue(groupLinks.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(groupLinks.count, 2)
        var sawSavedGroup = false
        var sawDefaultGroup = false
        for index in 0..<2 {
            groupLinks.element(boundBy: index).tap()
            XCTAssertTrue(
                app.descendants(matching: .any)["group.compare"].waitForExistence(timeout: 5))
            func exists(_ id: String, timeout: TimeInterval = 3) -> Bool {
                app.descendants(matching: .any)[id].firstMatch.waitForExistence(timeout: timeout)
            }
            if app.switches["group.toggle.date-resaved"].waitForExistence(timeout: 3) {
                sawSavedGroup = true
                // The copy dated by when it was saved, and without the location, says so.
                XCTAssertTrue(exists("group.dateNote.date-resaved.savedDate"))
                XCTAssertTrue(exists("group.dateNote.date-resaved.strippedLocation"))
                // The suggested copy has nothing against it.
                XCTAssertTrue(exists("group.dateLikely.date-orig"))
                XCTAssertFalse(exists("group.dateNote.date-orig.savedDate", timeout: 1))
                XCTAssertFalse(exists("group.dateNote.date-orig.strippedLocation", timeout: 1))
            } else {
                sawDefaultGroup = true
                XCTAssertTrue(exists("group.dateNote.date-default.placeholder"))
                XCTAssertTrue(exists("group.dateLikely.date-real"))
                XCTAssertFalse(exists("group.dateNote.date-real.placeholder", timeout: 1))
            }
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(groupLinks.firstMatch.waitForExistence(timeout: 5))
        }
        XCTAssertTrue(sawSavedGroup && sawDefaultGroup)
    }
}
