import Foundation
import PhotoGateway

/// Cheap per-thumbnail pixel math (SCAN_PIPELINE.md §5-S2). All functions are
/// pure and operate on the ~512 px grayscale thumbnail — trivial CPU work.
public enum PixelMath {
    public struct CheapSignals: Sendable, Codable, Hashable {
        public let laplacianVariance: Double
        public let meanLuminance: Double
        public let luminanceBottomConcentration: Double // fraction of pixels in bottom 32/255
        public let pixelVariance: Double
        public let cornerBlobSuspect: Bool // finger-over-lens candidate flag

        public init(
            laplacianVariance: Double,
            meanLuminance: Double,
            luminanceBottomConcentration: Double,
            pixelVariance: Double,
            cornerBlobSuspect: Bool
        ) {
            self.laplacianVariance = laplacianVariance
            self.meanLuminance = meanLuminance
            self.luminanceBottomConcentration = luminanceBottomConcentration
            self.pixelVariance = pixelVariance
            self.cornerBlobSuspect = cornerBlobSuspect
        }
    }

    /// One pass computing everything S2 needs.
    public static func cheapSignals(_ thumb: GrayThumbnail) -> CheapSignals {
        CheapSignals(
            laplacianVariance: laplacianVariance(thumb),
            meanLuminance: meanLuminance(thumb),
            luminanceBottomConcentration: bottomConcentration(thumb),
            pixelVariance: pixelVariance(thumb),
            cornerBlobSuspect: cornerBlobSuspect(thumb)
        )
    }

    /// 4-neighbor Laplacian variance — the blur signal. Normalized per-pixel so
    /// values are comparable across thumbnail sizes.
    public static func laplacianVariance(_ thumb: GrayThumbnail) -> Double {
        let width = thumb.width
        let height = thumb.height
        guard width > 2, height > 2 else { return 0 }
        let pixels = thumb.pixels

        var sum = 0.0
        var sumSquares = 0.0
        let count = Double((width - 2) * (height - 2))

        for y in 1..<(height - 1) {
            let row = y * width
            for x in 1..<(width - 1) {
                let index = row + x
                let center = 4 * Int(pixels[index])
                let neighbors = Int(pixels[index - 1]) + Int(pixels[index + 1])
                    + Int(pixels[index - width]) + Int(pixels[index + width])
                let laplacian = Double(center - neighbors)
                sum += laplacian
                sumSquares += laplacian * laplacian
            }
        }
        let mean = sum / count
        return sumSquares / count - mean * mean
    }

    public static func meanLuminance(_ thumb: GrayThumbnail) -> Double {
        guard !thumb.pixels.isEmpty else { return 0 }
        var total = 0
        for pixel in thumb.pixels { total += Int(pixel) }
        return Double(total) / Double(thumb.pixels.count)
    }

    /// Fraction of pixels darker than 32/255 — the "dark shot" histogram signal.
    public static func bottomConcentration(_ thumb: GrayThumbnail) -> Double {
        guard !thumb.pixels.isEmpty else { return 0 }
        var dark = 0
        for pixel in thumb.pixels where pixel < 32 { dark += 1 }
        return Double(dark) / Double(thumb.pixels.count)
    }

    /// Near-zero variance = blank frame (SCAN_PIPELINE.md §5-S2, DESIGN.md §4.3).
    public static func pixelVariance(_ thumb: GrayThumbnail) -> Double {
        guard !thumb.pixels.isEmpty else { return 0 }
        var sum = 0.0
        var sumSquares = 0.0
        for pixel in thumb.pixels {
            let value = Double(pixel)
            sum += value
            sumSquares += value * value
        }
        let count = Double(thumb.pixels.count)
        let mean = sum / count
        return sumSquares / count - mean * mean
    }

    /// Corner-anchored uniform low-variance blob — finger-over-lens candidate.
    /// Checks each corner quarter for very low internal variance while the
    /// opposite region has normal variance.
    public static func cornerBlobSuspect(_ thumb: GrayThumbnail) -> Bool {
        let width = thumb.width
        let height = thumb.height
        guard width >= 8, height >= 8 else { return false }
        let halfW = width / 2
        let halfH = height / 2

        func regionVariance(x0: Int, y0: Int, x1: Int, y1: Int) -> Double {
            var sum = 0.0
            var sumSquares = 0.0
            var count = 0.0
            var y = y0
            while y < y1 {
                var x = x0
                let row = y * width
                while x < x1 {
                    let value = Double(thumb.pixels[row + x])
                    sum += value
                    sumSquares += value * value
                    count += 1
                    x += 2 // sample every other pixel; precision isn't needed here
                }
                y += 2
            }
            guard count > 0 else { return 0 }
            let mean = sum / count
            return sumSquares / count - mean * mean
        }

        let corners = [
            regionVariance(x0: 0, y0: 0, x1: halfW, y1: halfH),
            regionVariance(x0: halfW, y0: 0, x1: width, y1: halfH),
            regionVariance(x0: 0, y0: halfH, x1: halfW, y1: height),
            regionVariance(x0: halfW, y0: halfH, x1: width, y1: height),
        ]
        guard let minimum = corners.min(), let maximum = corners.max() else { return false }
        // One quadrant nearly flat while another is textured.
        return minimum < 40 && maximum > 400
    }
}
