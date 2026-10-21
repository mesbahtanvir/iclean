import CleanupKit
import CoreGraphics
import Foundation

/// Times each part of the per-photo analysis on photo-like 512 px images, so a change that skips
/// a part for some photos can be weighed against what it costs (`ScaleBench --stages`).
func photoLikeImage(seed: UInt64, width: Int = 512, height: Int = 384) -> CGImage {
    var rng = Rng(state: seed &* 0x9E37_79B9_7F4A_7C15 | 1)
    let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let colors = [
        CGColor(red: rng.unit(), green: rng.unit(), blue: rng.unit(), alpha: 1),
        CGColor(red: rng.unit(), green: rng.unit(), blue: rng.unit(), alpha: 1),
    ]
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(
        gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
    for _ in 0..<60 {
        ctx.setFillColor(CGColor(red: rng.unit(), green: rng.unit(), blue: rng.unit(), alpha: 1))
        let rect = CGRect(
            x: rng.unit() * Double(width), y: rng.unit() * Double(height),
            width: 10 + rng.unit() * Double(width) / 3, height: 10 + rng.unit() * Double(height) / 3
        )
        if rng.unit() > 0.5 { ctx.fill(rect) } else { ctx.fillEllipse(in: rect) }
    }
    return ctx.makeImage()!
}

func runStageTimings(iterations: Int) async {
    let images = (0..<iterations).map { photoLikeImage(seed: UInt64($0 + 1)) }
    func time(_ name: String, _ body: (CGImage) async -> Void) async {
        _ = await body(images[0])  // warm up
        let start = ContinuousClock.now
        for image in images { await body(image) }
        let total = ContinuousClock.now - start
        print(
            String(
                format: "  %-22@ %7.2f ms per photo", name as NSString,
                Double(ms(total)) / Double(iterations)))
        fflush(stdout)
    }
    print("Per-photo analysis stages, \(iterations) photos of 512×384, one at a time")
    await time("dHash") { _ = dHash($0) }
    await time("Thumbprint") { _ = Thumbprint.compute($0) }
    await time("Sharpness") { _ = Sharpness.score($0) }
    await time("FeaturePrint (Vision)") { _ = try? await FeaturePrint.compute($0) }
    await time("Aesthetics (Vision)") { _ = await Aesthetics.score($0) }
    await time("FaceQuality (Vision)") { _ = await FaceQuality.score($0) }
    await time("DefaultAnalyzer (all)") {
        _ = try? await DefaultAnalyzer().analyze(
            $0,
            metadata: AssetMetadata(assetID: "x", kind: .photo, pixelWidth: 4032, pixelHeight: 3024)
        )
    }
}
