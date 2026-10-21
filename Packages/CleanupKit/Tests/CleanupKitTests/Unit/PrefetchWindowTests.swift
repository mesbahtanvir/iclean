import CoreGraphics
import Foundation
import Testing

@testable import CleanupKit

/// Smooth scrolling: which pictures are made before their cells arrive.
@Suite struct PrefetchWindowTests {
    let window = PrefetchWindow()

    // MARK: The window

    @Test func scrollingDownWarmsMoreAheadThanBehind() {
        let warm = window.warm(visible: 100...129, direction: .forward, count: 1_000)
        // One screen is 30 items: 1 screen behind, 3 ahead.
        #expect(warm == 70...219)
    }

    @Test func scrollingUpWarmsMoreAboveThanBelow() {
        let warm = window.warm(visible: 100...129, direction: .backward, count: 1_000)
        #expect(warm == 10...159)
    }

    @Test func aListThatIsNotMovingKeepsAMarginOnBothSides() {
        let warm = window.warm(visible: 100...129, direction: .idle, count: 1_000)
        #expect(warm == 55...174)
    }

    @Test func theWindowNeverLeavesTheList() {
        #expect(window.warm(visible: 0...29, direction: .backward, count: 1_000) == 0...59)
        #expect(window.warm(visible: 970...999, direction: .forward, count: 1_000) == 940...999)
        #expect(window.warm(visible: 0...2, direction: .forward, count: 3) == 0...2)
    }

    @Test func anEmptyListHasNothingToWarm() {
        #expect(window.warm(visible: 0...0, direction: .forward, count: 0) == nil)
    }

    // MARK: The default stream, used by every library without a faster path

    @Test func theDefaultStreamDeliversThePreviewOnceAsTheFinalPicture() async {
        let lib = FakePhotoLibrary()
        lib.add(Make.meta("a"), preview: .local(TestImages.scene(seed: 1, width: 32, height: 24)))
        var pictures: [ThumbnailImage] = []
        for await picture in lib.thumbnails(for: "a", pixelSize: 64, fit: .fill) {
            pictures.append(picture)
        }
        #expect(pictures.count == 1)
        #expect(pictures.first?.isFinal == true)
    }

    @Test func theDefaultStreamEndsWithNothingForAnItemWithNoPicture() async {
        let lib = FakePhotoLibrary()
        lib.add(Make.meta("gone"), preview: .unavailable)
        var count = 0
        for await _ in lib.thumbnails(for: "gone", pixelSize: 64, fit: .fill) { count += 1 }
        #expect(count == 0)
        // Prefetching is a no-op for these libraries and must not fail.
        lib.startPrefetching(["gone"], pixelSize: 64, fit: .fill)
        lib.stopPrefetching(["gone"], pixelSize: 64, fit: .fill)
    }
}
