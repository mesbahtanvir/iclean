import CoreGraphics
import Foundation

/// A 32×32 grayscale miniature of an image, compared two ways (research R3, R4):
///
/// - `similarity`: correlation of the miniatures — "same scene / layout". Used for
///   similar shots.
/// - `detailSimilarity`: correlation of their fine detail (each pixel minus its local
///   average). Copies of one photo keep their detail even after resizing or heavy
///   recompression (≥ 0.88); crops and different photos — even different blurry ones
///   that share a smooth layout — do not (≤ 0.16).
public enum Thumbprint {
    public static let side = 32

    public static func compute(_ image: CGImage) -> Data {
        guard let gray = GrayImage(image, width: side, height: side) else { return Data() }
        return Data(gray.pixels)
    }

    /// Correlation of the miniatures, from -1 to 1.
    public static func similarity(_ a: Data, _ b: Data) -> Double {
        guard let x = values(a), let y = values(b) else { return -1 }
        let flatA = isFlat(x)
        let flatB = isFlat(y)
        // Two flat images (e.g. all black) match only if their brightness matches.
        if flatA || flatB { return flatA && flatB && abs(mean(x) - mean(y)) < 4 ? 1 : 0 }
        return correlation(x, y)
    }

    /// Correlation of the fine detail, from -1 to 1.
    public static func detailSimilarity(_ a: Data, _ b: Data) -> Double {
        guard let x = values(a), let y = values(b) else { return -1 }
        let flatA = isFlat(x)
        let flatB = isFlat(y)
        if flatA || flatB { return flatA && flatB && abs(mean(x) - mean(y)) < 4 ? 1 : 0 }
        return correlation(highPass(x), highPass(y))
    }

    /// Average absolute difference in brightness (0…255) between the miniatures.
    /// Copies keep their brightness; different scenes with similar layouts do not.
    public static func meanAbsoluteDifference(_ a: Data, _ b: Data) -> Double {
        guard let x = values(a), let y = values(b) else { return 255 }
        return zip(x, y).reduce(0) { $0 + abs($1.0 - $1.1) } / Double(x.count)
    }

    static func values(_ data: Data) -> [Double]? {
        guard data.count == side * side else { return nil }
        return data.map(Double.init)
    }

    static func mean(_ v: [Double]) -> Double { v.reduce(0, +) / Double(v.count) }

    static func isFlat(_ v: [Double]) -> Bool {
        let m = mean(v)
        return v.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(v.count) < 1
    }

    /// Each pixel minus the average of its 5×5 neighbourhood.
    static func highPass(_ v: [Double]) -> [Double] {
        let n = side
        var out = [Double](repeating: 0, count: v.count)
        for y in 0..<n {
            for x in 0..<n {
                var sum = 0.0
                var count = 0.0
                for dy in -2...2 {
                    for dx in -2...2 {
                        let xx = x + dx
                        let yy = y + dy
                        guard xx >= 0, xx < n, yy >= 0, yy < n else { continue }
                        sum += v[yy * n + xx]
                        count += 1
                    }
                }
                out[y * n + x] = v[y * n + x] - sum / count
            }
        }
        return out
    }

    static func correlation(_ x: [Double], _ y: [Double]) -> Double {
        let mx = mean(x)
        let my = mean(y)
        var sxy = 0.0
        var sxx = 0.0
        var syy = 0.0
        for i in x.indices {
            let dx = x[i] - mx
            let dy = y[i] - my
            sxy += dx * dy
            sxx += dx * dx
            syy += dy * dy
        }
        guard sxx > 1e-9, syy > 1e-9 else { return 0 }
        return sxy / (sxx * syy).squareRoot()
    }
}
