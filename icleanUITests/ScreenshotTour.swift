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

    /// At large text a long list is taller than the screen, so a row can be off it and not tappable:
    /// scroll until it can be tapped.
    @discardableResult
    private func reveal(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let target = element(app, id)
        _ = target.waitForExistence(timeout: 5)
        var swipes = 0
        while !target.isHittable, swipes < 6 {
            app.swipeUp()
            swipes += 1
        }
        // The row may instead be above the part that is showing.
        swipes = 0
        while !target.isHittable, swipes < 12 {
            app.swipeDown()
            swipes += 1
        }
        return target
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
                Thread.sleep(forTimeInterval: 4)
                shot(app, "02-scanning")
                element(app, "scan.pause").tap()
                if element(app, "scan.resume").waitForExistence(timeout: 10) {
                    shot(app, "02-scanning-paused")
                }
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
            let row = reveal(app, "results.category.\(category)")
            guard row.exists else { continue }
            row.tap()
            settle(1.0)
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
        reveal(app, "results.category.duplicates").tap()
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
        app.terminate()
    }
}
