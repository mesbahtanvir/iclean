import Foundation

/// How a grid of photos is laid out, and so how many pixels each picture needs. Pure arithmetic, so a
/// grid never asks PhotoKit for more pixels than it draws (a 512 px image costs about 1.4 MB).
public enum GridMetrics {
    /// How many columns an adaptive grid fits in `width`.
    public static func columns(width: Double, minimum: Double, spacing: Double) -> Int {
        guard width > 0, minimum > 0 else { return 1 }
        return max(1, Int(((width + spacing) / (minimum + spacing)).rounded(.down)))
    }

    /// The width of one cell.
    public static func cellWidth(width: Double, minimum: Double, spacing: Double) -> Double {
        let n = Double(columns(width: width, minimum: minimum, spacing: spacing))
        return (width - spacing * (n - 1)) / n
    }

    /// The pixels to ask for: a cell's width in pixels, rounded up to a multiple of 64 so nearby
    /// widths share cached pictures, and kept within 128...`cap`.
    public static func pixels(
        width: Double, minimum: Double, spacing: Double, scale: Double, cap: Int = 512
    ) -> Int {
        let cell = cellWidth(width: width, minimum: minimum, spacing: spacing)
        let rounded = Int((cell * scale / 64).rounded(.up)) * 64
        return min(max(rounded, 128), cap)
    }
}
