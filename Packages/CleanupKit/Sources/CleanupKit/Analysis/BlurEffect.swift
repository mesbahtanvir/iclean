import CoreGraphics

/// No-reference blur measure (Crété-Roffet et al., 2007): re-blur the image and
/// measure how much of its local variation survives. A sharp image loses a lot; an
/// already-blurry one loses little. Computed on a 256 px grayscale copy, which also
/// averages away most sensor noise. Returns 0 (sharp) … 1 (fully blurred).
public enum BlurEffect {
    public static let analysisSize = 256

    public static func score(_ image: CGImage) -> Double {
        guard let g = GrayImage(image, maxDimension: analysisSize), g.width > 10, g.height > 10 else {
            return 1
        }
        let f = g.pixels.map(Float.init)
        return max(
            directional(f, width: g.width, height: g.height, dx: 1, dy: 0),
            directional(f, width: g.width, height: g.height, dx: 0, dy: 1))
    }

    private static func directional(_ f: [Float], width w: Int, height h: Int, dx: Int, dy: Int) -> Double {
        let radius = 4
        // Box-blur along the direction.
        var b = [Float](repeating: 0, count: f.count)
        for y in 0..<h {
            for x in 0..<w {
                var sum: Float = 0
                var n: Float = 0
                for k in -radius...radius {
                    let xx = x + k * dx
                    let yy = y + k * dy
                    guard xx >= 0, xx < w, yy >= 0, yy < h else { continue }
                    sum += f[yy * w + xx]
                    n += 1
                }
                b[y * w + x] = sum / n
            }
        }
        var sF = 0.0
        var sV = 0.0
        for y in dy..<h {
            for x in dx..<w {
                let i = y * w + x
                let j = (y - dy) * w + (x - dx)
                let dF = abs(f[i] - f[j])
                let dB = abs(b[i] - b[j])
                sF += Double(dF)
                sV += Double(max(0, dF - dB))
            }
        }
        guard sF > 0 else { return 1 }
        return (sF - sV) / sF
    }
}
