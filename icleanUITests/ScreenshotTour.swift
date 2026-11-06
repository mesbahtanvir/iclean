import XCTest

/// Not a check of behavior: walks every screen and saves a PNG of each, so a design review can look
/// at the real screens in light, dark and large text. Skipped unless `SCREENSHOT_DIR` is set (with
/// `xcodebuild` pass `TEST_RUNNER_SCREENSHOT_DIR=<folder>`), so the regular suite is unaffected.
@MainActor
final class ScreenshotTour: XCTestCase {
    private var directory: URL!
    private var variant = "light"

    override func setUpWithError() throws {
        continueAfterFailure = true
        guard let path = ProcessInfo.processInfo.environment["SCREENSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("Set SCREENSHOT_DIR (TEST_RUNNER_SCREENSHOT_DIR with xcodebuild).")
        }
        directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// The simulator keeps the appearance between tests; put it back to light for the next one.
    override func tearDown() async throws {
        XCUIDevice.shared.appearance = .light
    }

    func testLight() { tour("light", appearance: .light) }
    func testDark() { tour("dark", appearance: .dark) }
    func testLargeText() { tour("largetext", appearance: .light) }
    /// The very largest accessibility size, where layouts break first.
    func testLargestText() { tour("xxxl", appearance: .light) }

    // MARK: Helpers

    private func start(_ scenario: String, extra: [String] = []) -> XCUIApplication {
        var arguments = extra
        if variant == "largetext" {
            arguments += [
                "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL",
            ]
        }
        if variant == "xxxl" {
            arguments += [
                "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
            ]
        }
        return launchApp(scenario: scenario, extraArguments: arguments)
    }

    private func settle(_ seconds: Double = 0.7) { Thread.sleep(forTimeInterval: seconds) }

    private func shot(_ app: XCUIApplication, _ name: String) {
        settle()
        let screenshot = app.screenshot()
        try? screenshot.pngRepresentation.write(
            to: directory.appending(path: "\(variant)-\(name).png"))
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "\(variant)-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    // MARK: Tapping a row that a pinned control may cover

    /// Where a tap reaches a row of the Results list: below the navigation bar and above the pinned
    /// Review button (and the fade over its top). At the largest text sizes a row is about as tall as what
    /// is left between them, so its middle or its top edge can be under either, and a tap there opens the
    /// Confirm sheet instead of the row.
    private func tapBand(_ app: XCUIApplication) -> ClosedRange<CGFloat> {
        let screen = app.frame
        let bar = app.navigationBars.firstMatch
        let top = (bar.exists ? bar.frame.maxY : screen.minY + 100) + 6
        let pinned = element(app, "results.reviewAll")
        let bottom = (pinned.exists ? pinned.frame.minY : screen.maxY - 40) - 24
        return top...max(top + 1, bottom)
    }

    /// Moves the list by a part of a screen. `up` moves the content up (the finger goes up), which shows
    /// what is further down. It holds the finger still at the end, so the list does not coast on.
    private func scroll(_ app: XCUIApplication, up: Bool) {
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.66 : 0.34))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.38 : 0.62))
        from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.3)
    }

    /// Taps the row with this identifier at a point that nothing covers, scrolling the list in steps until
    /// enough of the row is in the band between the navigation bar and the pinned button. A list holds only
    /// the rows near the screen, so a row is first looked for further down the list, then back up it.
    /// False when the list has no such row.
    @discardableResult
    private func tapRow(_ app: XCUIApplication, _ id: String) -> Bool {
        let row = element(app, id)
        _ = row.waitForExistence(timeout: 5)
        for step in 0..<24 {
            if row.exists {
                let band = tapBand(app)
                let frame = row.frame
                let top = max(frame.minY, band.lowerBound)
                let bottom = min(frame.maxY, band.upperBound)
                if bottom - top >= 60 {
                    let x = frame.minX + frame.width * 0.35
                    let y = top + min(40, (bottom - top) / 2)
                    app.coordinate(withNormalizedOffset: .zero)
                        .withOffset(CGVector(dx: x - app.frame.minX, dy: y - app.frame.minY)).tap()
                    return true
                }
                // In sight but not in the band: move it toward the middle of the band.
                scroll(app, up: frame.midY > (band.lowerBound + band.upperBound) / 2)
            } else {
                scroll(app, up: step < 10)
            }
        }
        return false
    }

    private func back(_ app: XCUIApplication) {
        let button = app.navigationBars.buttons.element(boundBy: 0)
        if button.exists { button.tap() }
        settle(0.4)
    }

    // MARK: The tour

    private func tour(_ name: String, appearance: XCUIDevice.Appearance) {
        variant = name
        XCUIDevice.shared.appearance = appearance

        // First launch, and the denied state.
        var app = start("notDetermined")
        if element(app, "access.allow").waitForExistence(timeout: 10) { shot(app, "00-access") }
        app.terminate()
        app = start("denied")
        if element(app, "access.openSettings").waitForExistence(timeout: 10) {
            shot(app, "00-access-denied")
        }
        app.terminate()

        // Nothing to clean, and only some photos shared.
        app = start("empty")
        if element(app, "home.scan").waitForExistence(timeout: 10) {
            shot(app, "01-home-empty-library")
            element(app, "home.scan").tap()
            if element(app, "results.empty").waitForExistence(timeout: 30) { shot(app, "02-clean") }
        }
        app.terminate()
        app = start("limited")
        if element(app, "home.scan").waitForExistence(timeout: 10) { shot(app, "01-home-limited") }
        app.terminate()

        // A scan in progress, running and paused.
        app = start("slow")
        if element(app, "home.scan").waitForExistence(timeout: 10) {
            element(app, "home.scan").tap()
            if element(app, "scan.pause").waitForExistence(timeout: 10) {
                // The scan is slow on purpose, but how slow depends on how many photos the machine checks
                // at once: on a quick one it was over before the tour tapped Pause, and the tap failed. Look
                // at it early, and pause it only if it is still going.
                Thread.sleep(forTimeInterval: 1.5)
                shot(app, "02-scanning")
                let pause = element(app, "scan.pause")
                if pause.exists {
                    pause.tap()
                    if element(app, "scan.resume").waitForExistence(timeout: 10) {
                        shot(app, "02-scanning-paused")
                    }
                }
            }
        }
        app.terminate()

        // A scan in tiers (spec 017): its three tiers while it runs, and the finds grouped by the
        // tier that found them. `verySlow` keeps the photo check going while the first finds show.
        app = start("verySlow", extra: ["-Tiered", "on"])
        if element(app, "home.scan").waitForExistence(timeout: 10) {
            element(app, "home.scan").tap()
            if element(app, "scan.tier.instant").waitForExistence(timeout: 20) {
                shot(app, "02-tiers-running")
            }
            if element(app, "results.section.instant").waitForExistence(timeout: 20) {
                shot(app, "02-tiers-groups")
                app.swipeUp()
                shot(app, "02-tiers-groups-bottom")
            }
        }
        app.terminate()

        // The deep check held back (Low Power Mode): the flat list with the offer to run it.
        app = start("standard", extra: ["-Tiered", "on", "-LowPowerMode", "on"])
        if element(app, "home.scan").waitForExistence(timeout: 10) {
            element(app, "home.scan").tap()
            if element(app, "home.deepScan").waitForExistence(timeout: 60) {
                shot(app, "02-tiers-offer")
            }
        }
        app.terminate()

        // Results and every screen under them.
        app = start("standard")
        guard element(app, "home.scan").waitForExistence(timeout: 10) else { return }
        shot(app, "01-home")
        element(app, "home.scan").tap()
        guard element(app, "results.category.duplicates").waitForExistence(timeout: 60) else {
            return
        }
        shot(app, "03-results")
        app.swipeUp()
        shot(app, "03-results-bottom")
        app.swipeDown()

        for category in ["duplicates", "similar", "blurry", "screenshots", "largeVideos"] {
            guard tapRow(app, "results.category.\(category)") else { continue }
            settle(1.0)
            // A tap that reached the pinned Review button opens the Confirm sheet, not the category. Say so,
            // instead of saving that sheet as the picture of the category.
            if element(app, "confirm.cancel").exists {
                XCTFail("The tap for \(category) reached the Review button, not its row")
                element(app, "confirm.cancel").tap()
                settle(0.5)
                continue
            }
            shot(app, "04-category-\(category)")
            if category == "duplicates" {
                let group = app.descendants(matching: .any)
                    .matching(NSPredicate(format: "identifier BEGINSWITH 'category.group.'"))
                    .firstMatch
                if group.waitForExistence(timeout: 3) {
                    group.tap()
                    if element(app, "group.compare").waitForExistence(timeout: 5) {
                        shot(app, "05-group")
                    }
                    back(app)
                }
                let photo = element(app, "category.item.dup1-a")
                if photo.waitForExistence(timeout: 3) {
                    photo.press(forDuration: 0.8)
                    if element(app, "viewer.toggleSelect").waitForExistence(timeout: 5) {
                        shot(app, "06-viewer")
                        app.buttons["Done"].firstMatch.tap()
                        settle(0.5)
                    }
                }
                let remove = element(app, "category.removeSelected")
                if remove.waitForExistence(timeout: 3) {
                    remove.tap()
                    if element(app, "confirm.remove").waitForExistence(timeout: 8) {
                        shot(app, "07-confirm")
                        element(app, "confirm.cancel").tap()
                        settle(0.5)
                    }
                }
            }
            back(app)
        }

        // Settings and the screens under it.
        let settings = element(app, "home.settings")
        if settings.waitForExistence(timeout: 5) {
            settings.tap()
            if element(app, "settings.deleteAllData").waitForExistence(timeout: 5) {
                shot(app, "09-settings")
                let saved = element(app, "settings.savedData")
                if saved.exists {
                    saved.tap()
                    if element(app, "saved.clearResults").waitForExistence(timeout: 5) {
                        shot(app, "10-saved")
                    }
                    back(app)
                }
                let recent = element(app, "settings.recentScans")
                if recent.exists {
                    recent.tap()
                    settle(1.0)
                    shot(app, "11-recent-scans")
                    back(app)
                }
            }
            back(app)
        }

        // The summary after removing, last because it changes the library.
        if tapRow(app, "results.category.duplicates") {
            let remove = element(app, "category.removeSelected")
            if remove.waitForExistence(timeout: 5) {
                remove.tap()
                if element(app, "confirm.remove").waitForExistence(timeout: 8) {
                    element(app, "confirm.remove").tap()
                    if element(app, "done.removed").waitForExistence(timeout: 15) {
                        shot(app, "08-done")
                    }
                }
            }
        } else {
            XCTFail("The Duplicates row could not be reached to remove its items")
        }
        app.terminate()
    }
}
