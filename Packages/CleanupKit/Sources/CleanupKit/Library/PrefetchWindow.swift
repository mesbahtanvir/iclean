import Foundation

/// Which items of an ordered list to keep warm while the person scrolls, and which to let go.
///
/// The picture of a cell is made before the cell arrives, in the direction the list is moving, so
/// scrolling shows pictures instead of grey boxes. Pure arithmetic over positions in the list, so
/// it can be tested without a screen.
public struct PrefetchWindow: Sendable, Equatable {
    public enum Direction: Sendable, Equatable {
        case forward, backward, idle
    }

    /// Screens of items to warm ahead, in the direction of travel.
    public var screensAhead: Double
    /// Screens of items to keep behind (for scrolling back).
    public var screensBehind: Double
    /// Screens to keep on each side when the list is not moving.
    public var screensWhenIdle: Double

    public init(screensAhead: Double = 3, screensBehind: Double = 1, screensWhenIdle: Double = 1.5)
    {
        self.screensAhead = screensAhead
        self.screensBehind = screensBehind
        self.screensWhenIdle = screensWhenIdle
    }

    /// The positions to keep warm: everything visible, plus a margin that is longer in the direction
    /// of travel. `visible` is the range on screen; its size stands for one screen. Clamped to the list.
    public func warm(visible: ClosedRange<Int>, direction: Direction, count: Int) -> ClosedRange<
        Int
    >? {
        guard count > 0 else { return nil }
        let screen = max(1, visible.count)
        func items(_ screens: Double) -> Int { Int((screens * Double(screen)).rounded(.up)) }
        let before: Int
        let after: Int
        switch direction {
        case .forward:
            before = items(screensBehind)
            after = items(screensAhead)
        case .backward:
            before = items(screensAhead)
            after = items(screensBehind)
        case .idle:
            before = items(screensWhenIdle)
            after = items(screensWhenIdle)
        }
        let low = max(0, visible.lowerBound - before)
        let high = min(count - 1, visible.upperBound + after)
        guard low <= high else { return nil }
        return low...high
    }
}
