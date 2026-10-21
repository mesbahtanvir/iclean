import Testing

@testable import CleanupKit

@Suite struct GridMetricsTests {
    @Test func aPhoneFitsThreeColumns() {
        #expect(GridMetrics.columns(width: 402, minimum: 104, spacing: 2) == 3)
        let cell = GridMetrics.cellWidth(width: 402, minimum: 104, spacing: 2)
        #expect(abs(cell - 132.67) < 0.01)
    }

    @Test func pixelsAreTheCellsWidthRoundedUpToAMultipleOf64() {
        // 132.67 pt at 3x is 398 px, which rounds up to 448.
        #expect(GridMetrics.pixels(width: 402, minimum: 104, spacing: 2, scale: 3) == 448)
        // Nearby widths share a size, so cached pictures are reused.
        #expect(GridMetrics.pixels(width: 400, minimum: 104, spacing: 2, scale: 3) == 448)
    }

    @Test func largeTextMakesBiggerCellsAndTheCapHolds() {
        // The grid minimum rises to 150 at accessibility sizes: two columns of 200 pt, 600 px.
        #expect(GridMetrics.columns(width: 402, minimum: 150, spacing: 2) == 2)
        #expect(GridMetrics.pixels(width: 402, minimum: 150, spacing: 2, scale: 3) == 512)
        #expect(GridMetrics.pixels(width: 402, minimum: 150, spacing: 2, scale: 3, cap: 768) == 640)
    }

    @Test func aWideWindowGetsSmallerPicturesPerCell() {
        #expect(GridMetrics.columns(width: 1000, minimum: 150, spacing: 4) == 6)
        #expect(
            GridMetrics.pixels(width: 1000, minimum: 150, spacing: 4, scale: 2, cap: 768) == 384)
    }

    @Test func nonsenseInputsStillGiveASafeSize() {
        #expect(GridMetrics.columns(width: 0, minimum: 104, spacing: 2) == 1)
        #expect(GridMetrics.pixels(width: 10, minimum: 104, spacing: 2, scale: 1) == 128)
    }
}
