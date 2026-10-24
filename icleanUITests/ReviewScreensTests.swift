import XCTest

/// The review screens of spec 012 (6.5 to 6.8): the category screen and its bars, Large Videos,
/// group compare and the viewer. The flow tests (`DuplicatesFlowTests` and the others) keep the
/// behaviour; these read the words and the states the design promises.
@MainActor
final class ReviewScreensTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    override func tearDown() async throws {
        XCUIDevice.shared.appearance = .light
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    /// Waits until the element's label satisfies the predicate (the bars read an asynchronous summary).
    private func waitForLabel(_ element: XCUIElement, _ format: String, timeout: TimeInterval = 8) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: format), object: element)
        XCTAssertEqual(
            XCTWaiter().wait(for: [expectation], timeout: timeout), .completed,
            "Label was \"\(element.label)\", expected \(format)")
    }

    /// Taps the switch itself: the element is the whole row, and a tap on its label (the middle)
    /// does nothing outside a list.
    private func flip(_ toggle: XCUIElement) {
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
    }

    private func groupLinks(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'category.group.'"))
    }

    // MARK: Category

    func testTheBarAndTheToolbarButtonSpeakTheSelection() {
        let app = launchApp()
        scan(app)
        openCategory(app, "duplicates")
        let bar = app.buttons["category.removeSelected"]
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        waitForLabel(bar, "label CONTAINS 'Remove 3 Photos'")
        // One line; where they go is said on the Confirm sheet (spec 014).
        XCTAssertFalse(bar.label.contains("goes to Recently Deleted"), bar.label)
        XCTAssertTrue(bar.isEnabled)

        // Every suggested item is selected, so the button offers to keep them all.
        let all = app.buttons["category.selectAll"]
        XCTAssertTrue(all.waitForExistence(timeout: 5))
        XCTAssertEqual(all.label, "Keep All")
        all.tap()
        waitForLabel(bar, "label CONTAINS 'Choose Items to Remove'")
        XCTAssertFalse(bar.isEnabled)
        XCTAssertEqual(all.label, "Select Suggested")
        // It never selects a keeper.
        XCTAssertFalse(item(app, "dup1-a").isSelected)
        all.tap()
        waitForLabel(bar, "label CONTAINS 'Remove 3 Photos'")
        XCTAssertFalse(item(app, "dup1-a").isSelected)
        XCTAssertTrue(item(app, "dup1-b").isSelected)
    }

    func testTheCaptionAndTheGroupHeader() {
        let app = launchApp()
        scan(app)
        openCategory(app, "duplicates")
        let caption = app.staticTexts[
            "Copies of the same photo. We keep one of each and select the rest for removal."]
        XCTAssertTrue(caption.waitForExistence(timeout: 5))
        // "{n} sets · {size}" under the caption.
        let summary = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '2 sets'"))
        XCTAssertTrue(summary.firstMatch.waitForExistence(timeout: 5))
        // The whole header row is the link to compare: name, how many are selected, Compare.
        let link = groupLinks(app).firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        XCTAssertTrue(link.label.contains("3 copies"), link.label)
        XCTAssertTrue(link.label.contains("selected"), link.label)
        XCTAssertTrue(link.label.contains("Compare"), link.label)
    }

    func testACellDescribesAndItsValueIsTheState() {
        let app = launchApp()
        scan(app)
        openCategory(app, "duplicates")
        let keeper = item(app, "dup2-fav")
        XCTAssertTrue(keeper.waitForExistence(timeout: 5))
        // The label is a description only.
        XCTAssertTrue(keeper.label.hasPrefix("Photo, "), keeper.label)
        XCTAssertTrue(keeper.label.contains("Suggested to keep."), keeper.label)
        XCTAssertTrue(keeper.label.contains("Favorite."), keeper.label)
        XCTAssertTrue(keeper.label.contains("In albums: Holiday."), keeper.label)
        XCTAssertFalse(keeper.label.contains("Selected"), keeper.label)
        XCTAssertEqual(keeper.value as? String, "Staying in your library")
        XCTAssertEqual(item(app, "dup2-a").value as? String, "Selected for removal")
    }

    func testLargeVideosAreAListWithNothingSelected() {
        let app = launchApp()
        scan(app, expect: "results.category.largeVideos")
        openCategory(app, "largeVideos")
        let big = item(app, "vid-big")
        XCTAssertTrue(big.waitForExistence(timeout: 5))
        // Size, length and date in words, for VoiceOver.
        XCTAssertTrue(big.label.hasPrefix("Video, 5 minutes, 900 MB"), big.label)
        XCTAssertEqual(big.value as? String, "Staying in your library")
        let bar = app.buttons["category.removeSelected"]
        XCTAssertFalse(bar.isEnabled)
        XCTAssertTrue(bar.label.contains("Choose Items to Remove"), bar.label)
        XCTAssertEqual(app.buttons["category.selectAll"].label, "Select All Videos")
        big.tap()
        waitForLabel(bar, "label CONTAINS 'Remove 1 Video'")
        XCTAssertTrue(bar.isEnabled)
        XCTAssertTrue(big.isSelected)
        // Select All Videos then Keep All.
        app.buttons["category.selectAll"].tap()
        waitForLabel(bar, "label CONTAINS 'Remove 3 Videos'")
        XCTAssertEqual(app.buttons["category.selectAll"].label, "Keep All")
    }

    func testTappingTheVideoPreviewOpensTheViewerAndARowTogglesIt() {
        let app = launchApp()
        scan(app, expect: "results.category.largeVideos")
        openCategory(app, "largeVideos")
        let row = item(app, "vid-big")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let preview = row.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 16 + 36, dy: row.frame.height / 2))
        preview.tap()
        // Looking is not choosing.
        let toggle = app.buttons["viewer.toggleSelect"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertFalse(row.isSelected)
        XCTAssertEqual(toggle.label, "Select for Removal")
        // A video on the device has a play control; the clip plays in place.
        let play = app.buttons["viewer.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 10))
        play.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: play)
        waitForExpectations(timeout: 5)
        toggle.tap()
        XCTAssertEqual(toggle.label, "Keep This Video")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: row)
        waitForExpectations(timeout: 5)
    }

    func testAVideoThatIsNotOnTheDeviceHasNoPlayControl() {
        let app = launchApp()
        scan(app, expect: "results.category.largeVideos")
        openCategory(app, "largeVideos")
        // `vid-sd` stands for a video that is only in iCloud.
        let row = item(app, "vid-sd")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: 16 + 36, dy: row.frame.height / 2)).tap()
        XCTAssertTrue(app.buttons["viewer.toggleSelect"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["viewer.play"].waitForExistence(timeout: 2))
    }

    /// Removing every item of a category and closing the receipt leaves nothing to look at there, so
    /// the person is taken back to Home, not left on a screen with a stale caption and a dead bar.
    func testEmptyingACategoryReturnsToHome() {
        let app = launchApp()
        scan(app, expect: "results.category.screenshots")
        openCategory(app, "screenshots")
        confirmRemoval(app)
        XCTAssertTrue(app.staticTexts["done.removed"].waitForExistence(timeout: 10))
        app.buttons["done.close"].tap()
        // Home again: the other categories are there, and this one is gone from the list.
        XCTAssertTrue(
            element(app, "results.category.duplicates").waitForExistence(timeout: 10),
            "Back on Home")
        XCTAssertTrue(app.buttons["home.settings"].exists)
        XCTAssertFalse(element(app, "results.category.screenshots").exists)
        XCTAssertFalse(app.buttons["category.removeSelected"].exists, "No dead bar left behind")
        XCTAssertFalse(app.staticTexts["All Clear"].exists)
    }

    // MARK: Group compare

    func testTheSummaryLineFollowsTheSwitches() {
        let app = launchApp()
        scan(app)
        openCategory(app, "duplicates")
        groupLinks(app).firstMatch.tap()
        XCTAssertTrue(element(app, "group.compare").waitForExistence(timeout: 5))
        // The title is the group's own name.
        XCTAssertTrue(app.navigationBars["3 copies"].waitForExistence(timeout: 5))
        let summary = app.staticTexts["group.summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        waitForLabel(summary, "label BEGINSWITH 'Keeping 1 · removing 2'")
        // The switch says what it does to which copy.
        let toggle = app.switches["group.toggle.dup1-b"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertTrue(toggle.label.hasPrefix("Remove copy 2 of 3, "), toggle.label)
        XCTAssertEqual(toggle.value as? String, "1")
        flip(toggle)
        waitForLabel(summary, "label BEGINSWITH 'Keeping 2 · removing 1'")
        // The keeper is named in words, not only by colour.
        XCTAssertTrue(app.staticTexts["Suggested to keep"].exists)
    }

    func testTheCompareSwitchRemovesTheKeeperToo() {
        let app = launchApp()
        scan(app)
        openCategory(app, "duplicates")
        groupLinks(app).firstMatch.tap()
        let toggle = app.switches["group.toggle.dup1-a"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0")
        flip(toggle)
        let summary = app.staticTexts["group.summary"]
        waitForLabel(summary, "label BEGINSWITH 'Keeping 0 · removing 3'")
    }

    func testSimilarShotsExplainTheirSwitch() {
        let app = launchApp()
        scan(app, expect: "results.category.similar")
        openCategory(app, "similar")
        groupLinks(app).firstMatch.tap()
        XCTAssertTrue(element(app, "group.compare").waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["2 similar shots"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Turn off a photo’s Remove switch to keep it."].exists)
        // Similar shots have no "Keep This Copy": the best shot is chosen for you.
        XCTAssertFalse(app.buttons["group.makeKeeper"].exists)
    }

    func testTappingTheComparedPhotoOpensTheViewer() {
        let app = launchApp()
        scan(app)
        openCategory(app, "duplicates")
        groupLinks(app).firstMatch.tap()
        let photo = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Photo 1 of 3'"))
        XCTAssertTrue(photo.firstMatch.waitForExistence(timeout: 5))
        photo.firstMatch.tap()
        XCTAssertTrue(app.buttons["viewer.toggleSelect"].waitForExistence(timeout: 5))
        // Looking did not change the choice.
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.switches["group.toggle.dup1-a"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.switches["group.toggle.dup1-a"].value as? String, "0")
    }

    // MARK: Viewer

    func testTheViewerSaysWhatWillHappenAndChangesIt() {
        let app = launchApp()
        scan(app, expect: "results.category.blurry")
        openCategory(app, "blurry")
        let cell = item(app, "blur1")
        XCTAssertTrue(cell.waitForExistence(timeout: 5))
        cell.press(forDuration: 0.8)
        let state = app.staticTexts["viewer.state"]
        XCTAssertTrue(state.waitForExistence(timeout: 5))
        XCTAssertEqual(state.label, "Selected for removal")
        let toggle = app.buttons["viewer.toggleSelect"]
        XCTAssertEqual(toggle.label, "Keep This Photo")
        // Two labelled buttons, and a line under them about Always Keep.
        XCTAssertEqual(app.buttons["viewer.alwaysKeep"].label, "Always Keep")
        XCTAssertTrue(app.staticTexts["Never suggest this photo again."].exists)
        toggle.tap()
        expectation(
            for: NSPredicate(format: "label == 'Staying in your library'"), evaluatedWith: state)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(toggle.label, "Select for Removal")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(cell.waitForExistence(timeout: 5))
        expectation(for: NSPredicate(format: "isSelected == false"), evaluatedWith: cell)
        waitForExpectations(timeout: 5)
    }

    func testDoubleTapZoomsInAndOut() {
        let app = launchApp()
        scan(app, expect: "results.category.blurry")
        openCategory(app, "blurry")
        item(app, "blur1").press(forDuration: 0.8)
        XCTAssertTrue(app.buttons["viewer.toggleSelect"].waitForExistence(timeout: 5))
        let photo = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Photo' AND value BEGINSWITH 'Zoom'"))
            .firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        XCTAssertEqual(photo.value as? String, "Zoom 100 percent")
        photo.doubleTap()
        expectation(
            for: NSPredicate(format: "value == 'Zoom 250 percent'"), evaluatedWith: photo)
        waitForExpectations(timeout: 5)
        photo.doubleTap()
        expectation(
            for: NSPredicate(format: "value == 'Zoom 100 percent'"), evaluatedWith: photo)
        waitForExpectations(timeout: 5)
    }

    // MARK: Gallery

    /// Not a check: saves a PNG of each review screen when `SCREENSHOT_DIR` is set (with `xcodebuild`
    /// pass `TEST_RUNNER_SCREENSHOT_DIR=<folder>`), so the screens can be looked at in light, dark and
    /// large text. Skipped otherwise.
    func testGalleryLight() throws { try gallery("light", appearance: .light) }
    func testGalleryDark() throws { try gallery("dark", appearance: .dark) }
    func testGalleryLargeText() throws { try gallery("largetext", appearance: .light) }

    private func gallery(_ variant: String, appearance: XCUIDevice.Appearance) throws {
        guard let path = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("Set SCREENSHOT_DIR (TEST_RUNNER_SCREENSHOT_DIR with xcodebuild).")
        }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCUIDevice.shared.appearance = appearance
        var arguments: [String] = []
        if variant == "largetext" {
            arguments = [
                "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL",
            ]
        }
        func shot(_ app: XCUIApplication, _ name: String) {
            Thread.sleep(forTimeInterval: 0.8)
            try? app.screenshot().pngRepresentation.write(
                to: folder.appending(path: "review-\(variant)-\(name).png"))
        }

        // At large text the rows of Home do not all fit: scroll to the one wanted.
        func open(_ app: XCUIApplication, _ name: String) {
            let row = element(app, "results.category.\(name)")
            for up in [true, false] {
                for _ in 0..<6 where !(row.exists && row.isHittable) {
                    if up { app.swipeUp() } else { app.swipeDown() }
                }
            }
            row.tap()
        }

        let app = launchApp(extraArguments: arguments)
        scan(app)

        // Large Videos, nothing selected and then one chosen.
        open(app, "largeVideos")
        _ = item(app, "vid-big").waitForExistence(timeout: 5)
        shot(app, "01-large-videos")
        item(app, "vid-big").tap()
        shot(app, "02-large-videos-selected")
        // At large text the row is stacked and its preview toggles like the rest of the row; the
        // viewer is reached with the VoiceOver action "View full screen" instead.
        if variant != "largetext" {
            let row = item(app, "vid-big")
            row.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: 16 + 36, dy: 44)).tap()
            if app.buttons["viewer.play"].waitForExistence(timeout: 10) {
                shot(app, "03-viewer-video")
                app.buttons["viewer.play"].tap()
                Thread.sleep(forTimeInterval: 0.6)
                shot(app, "04-viewer-video-playing")
            }
            app.buttons["Done"].firstMatch.tap()
        }
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // A grid with a selection, a group, the compare screen of a duplicate and of similar shots.
        open(app, "duplicates")
        _ = item(app, "dup1-a").waitForExistence(timeout: 5)
        item(app, "dup1-a").tap()
        shot(app, "05-duplicates-keeper-selected")
        item(app, "dup1-a").tap()
        let link = groupLinks(app).firstMatch
        if link.waitForExistence(timeout: 5) {
            link.tap()
            if element(app, "group.compare").waitForExistence(timeout: 5) {
                shot(app, "06-compare-duplicates")
                app.swipeUp()
                shot(app, "07-compare-duplicates-scrolled")
            }
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        app.navigationBars.buttons.element(boundBy: 0).tap()
        open(app, "similar")
        if groupLinks(app).firstMatch.waitForExistence(timeout: 5) {
            groupLinks(app).firstMatch.tap()
            if element(app, "group.compare").waitForExistence(timeout: 5) {
                shot(app, "08-compare-similar")
            }
        }
        app.terminate()

        // A library where the first group has a favorite and the dates disagree.
        let dates = launchApp(scenario: "dates", extraArguments: arguments)
        scan(dates)
        openCategory(dates, "duplicates")
        if groupLinks(dates).firstMatch.waitForExistence(timeout: 5) {
            groupLinks(dates).firstMatch.tap()
            if element(dates, "group.compare").waitForExistence(timeout: 5) {
                shot(dates, "09-compare-dates")
            }
        }
        dates.terminate()
    }
}
