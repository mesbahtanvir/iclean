import CoreGraphics

/// Sharpness from 0 (fully blurred) to 1 (sharp), research R5.
///
/// The base score is `1 - BlurEffect.score`: sharp photos measure about 0.7–0.8,
/// clearly blurry ones below 0.55. Two guards keep photos with little detail (plain
/// skies, walls, dark frames) from looking blurry:
/// - **Featureless**: no edge stronger than `featurelessEdgeContrast` — nothing to judge,
///   so the photo counts as sharp.
/// - **Crisp edges**: the strongest edges change within one pixel rather than smearing
///   over several (`edgeCrispness ≥ crispEdges`) — the photo is in focus even if most of
///   it is smooth. Blurry photos measure ≤ 0.37, sharp ones ≥ 0.50.
public enum Sharpness {
    public static let featurelessEdgeContrast = 12.0
    public static let crispEdges = 0.45

    public static func score(_ image: CGImage) -> Double {
        let base = 1 - BlurEffect.score(image)
        guard base < BlurThresholds.sharpness,
            let gray = GrayImage(image, maxDimension: BlurEffect.analysisSize)
        else { return base }
        let edges = EdgeStats(gray)
        if edges.contrast < featurelessEdgeContrast { return 1 }
        if edges.crispness >= crispEdges { return max(base, BlurThresholds.sharpness + 0.05) }
        return base
    }
}

/// The strongest edges of a grayscale image: how strong (contrast) and how sharp
/// (crispness = one-pixel step ÷ six-pixel step, both at the 99.9th percentile).
struct EdgeStats {
    let contrast: Double
    let crispness: Double

    init(_ g: GrayImage) {
        var near = [Int](repeating: 0, count: 256)
        var far = [Int](repeating: 0, count: 256)
        for y in 0..<g.height {
            for x in 0..<g.width {
                if x >= 6 {
                    near[abs(Int(g[x, y]) - Int(g[x - 1, y]))] += 1
                    far[abs(Int(g[x, y]) - Int(g[x - 6, y]))] += 1
                }
                if y >= 6 {
                    near[abs(Int(g[x, y]) - Int(g[x, y - 1]))] += 1
                    far[abs(Int(g[x, y]) - Int(g[x, y - 6]))] += 1
                }
            }
        }
        let n = Self.percentile(near, 0.999)
        let f = Self.percentile(far, 0.999)
        contrast = n
        crispness = f == 0 ? 1 : n / f
    }

    static func percentile(_ histogram: [Int], _ q: Double) -> Double {
        let total = histogram.reduce(0, +)
        let target = Int(Double(total) * q)
        var seen = 0
        for (value, count) in histogram.enumerated() {
            seen += count
            if seen >= target { return Double(value) }
        }
        return 255
    }
}
