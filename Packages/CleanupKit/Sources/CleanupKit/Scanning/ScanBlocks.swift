import Foundation

/// Where a scan publishes results (spec 008, 004 D2): after a small first block, so the first
/// duplicates and blurry photos can be reviewed within about half a minute, then after larger
/// ones, so a 30,000-photo library is rebuilt a dozen times and not thousands.
enum ScanBlocks {
    /// Photos in the first block.
    static let first = 500
    /// Photos in the second block.
    static let second = 1_000
    /// Photos in every later block.
    static let steady = 2_500

    /// The next block edge after `processed` photos have been checked.
    static func edge(after processed: Int) -> Int {
        var edge = first
        var step = second
        while edge <= processed {
            edge += step
            step = steady
        }
        return edge
    }
}
