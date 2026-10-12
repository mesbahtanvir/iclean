import Foundation
import PhotoGateway

/// dHash and pHash over grayscale thumbnails (SCAN_PIPELINE.md §5-S2, §6.2).
public enum PerceptualHash {
    // MARK: - dHash: 9×8 downsample, adjacent-pixel gradient sign.

    public static func dHash64(_ thumb: GrayThumbnail) -> UInt64 {
        let grid = resample(thumb, width: 9, height: 8)
        var hash: UInt64 = 0
        var bit = 0
        for y in 0..<8 {
            for x in 0..<8 {
                if grid[y * 9 + x] > grid[y * 9 + x + 1] {
                    hash |= 1 << UInt64(bit)
                }
                bit += 1
            }
        }
        return hash
    }

    // MARK: - pHash: 32×32 downsample, DCT-II, 8×8 low-frequency block vs. median.

    public static func pHash64(_ thumb: GrayThumbnail) -> UInt64 {
        let size = 32
        let grid = resample(thumb, width: size, height: size)

        // Precomputed cosine table for the 32-point DCT.
        var cosTable = [Double](repeating: 0, count: size * size)
        for k in 0..<size {
            for n in 0..<size {
                cosTable[k * size + n] = cos(Double.pi * Double(k) * (2.0 * Double(n) + 1.0) / (2.0 * Double(size)))
            }
        }

        // Separable 2D DCT-II: rows then columns; we only need the top-left 8×8.
        var rowTransformed = [Double](repeating: 0, count: size * size)
        for y in 0..<size {
            for k in 0..<8 { // only 8 output frequencies needed per row
                var acc = 0.0
                for n in 0..<size {
                    acc += grid[y * size + n] * cosTable[k * size + n]
                }
                rowTransformed[y * size + k] = acc
            }
        }
        var dct = [Double](repeating: 0, count: 8 * 8)
        for k in 0..<8 {
            for j in 0..<8 {
                var acc = 0.0
                for n in 0..<size {
                    acc += rowTransformed[n * size + j] * cosTable[k * size + n]
                }
                dct[k * 8 + j] = acc
            }
        }

        // Median over the 8×8 block excluding the DC term.
        var ac = Array(dct[1...])
        ac.sort()
        let median = ac[ac.count / 2]

        var hash: UInt64 = 0
        for index in 0..<64 where dct[index] > median {
            hash |= 1 << UInt64(index)
        }
        return hash
    }

    public static func hamming64(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }

    // MARK: - Bilinear resample to a small grid.

    static func resample(_ thumb: GrayThumbnail, width outWidth: Int, height outHeight: Int) -> [Double] {
        var out = [Double](repeating: 0, count: outWidth * outHeight)
        guard thumb.width > 1, thumb.height > 1 else { return out }

        let xScale = Double(thumb.width - 1) / Double(max(1, outWidth - 1))
        let yScale = Double(thumb.height - 1) / Double(max(1, outHeight - 1))

        for oy in 0..<outHeight {
            let sy = Double(oy) * yScale
            let y0 = min(Int(sy), thumb.height - 2)
            let fy = sy - Double(y0)
            for ox in 0..<outWidth {
                let sx = Double(ox) * xScale
                let x0 = min(Int(sx), thumb.width - 2)
                let fx = sx - Double(x0)

                let p00 = Double(thumb.pixels[y0 * thumb.width + x0])
                let p10 = Double(thumb.pixels[y0 * thumb.width + x0 + 1])
                let p01 = Double(thumb.pixels[(y0 + 1) * thumb.width + x0])
                let p11 = Double(thumb.pixels[(y0 + 1) * thumb.width + x0 + 1])

                let top = p00 + (p10 - p00) * fx
                let bottom = p01 + (p11 - p01) * fx
                out[oy * outWidth + ox] = top + (bottom - top) * fy
            }
        }
        return out
    }
}
