import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Synthetic images for tests.
enum TestImages {
    /// A detailed, deterministic scene: random rectangles and circles.
    static func scene(seed: UInt64, width: Int = 640, height: Int = 480) -> CGImage {
        var rng = SeededRandom(seed: seed)
        let ctx = context(width: width, height: height)
        // Photo-like background: a smooth gradient between two random colors.
        let colors = [
            CGColor(red: rng.unit(), green: rng.unit(), blue: rng.unit(), alpha: 1),
            CGColor(red: rng.unit(), green: rng.unit(), blue: rng.unit(), alpha: 1),
        ]
        let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: nil)!
        ctx.drawLinearGradient(
            gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        for _ in 0..<60 {
            ctx.setFillColor(
                CGColor(red: rng.unit(), green: rng.unit(), blue: rng.unit(), alpha: 1))
            let rect = CGRect(
                x: rng.unit() * Double(width), y: rng.unit() * Double(height),
                width: 10 + rng.unit() * Double(width) / 3,
                height: 10 + rng.unit() * Double(height) / 3)
            if rng.unit() > 0.5 { ctx.fill(rect) } else { ctx.fillEllipse(in: rect) }
        }
        return addGrain(ctx.makeImage()!, seed: seed)
    }

    /// Adds light sensor-like noise so flat areas are not perfectly flat.
    static func addGrain(_ image: CGImage, seed: UInt64, amount: Double = 10) -> CGImage {
        var rng = SeededRandom(seed: seed ^ 0xABCDEF)
        let ctx = context(width: image.width, height: image.height)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
        for i in 0..<(ctx.bytesPerRow * image.height) where i % 4 != 3 {
            let v = Double(data[i]) + (rng.unit() - 0.5) * amount
            data[i] = UInt8(max(0, min(255, v)))
        }
        return ctx.makeImage()!
    }

    /// A sharp but low-detail scene, like a clear sky over a wall.
    static func lowTexture(seed: UInt64, width: Int = 640, height: Int = 480) -> CGImage {
        var rng = SeededRandom(seed: seed)
        let ctx = context(width: width, height: height)
        // Skies vary in tone from photo to photo.
        let top = 0.2 + rng.unit() * 0.6
        let colors = [
            CGColor(red: top * 0.6, green: top * 0.8, blue: top, alpha: 1),
            CGColor(red: 0.7 + rng.unit() * 0.3, green: 0.75 + rng.unit() * 0.25, blue: 1, alpha: 1),
        ]
        let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: nil)!
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: height), options: [])
        ctx.setFillColor(CGColor(red: rng.unit(), green: rng.unit(), blue: rng.unit(), alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: Int(Double(height) * (0.2 + rng.unit() * 0.3))))
        return addGrain(ctx.makeImage()!, seed: seed, amount: 6)
    }

    /// A structurally different image: stripes and a checkerboard.
    static func stripes(seed: UInt64, width: Int = 640, height: Int = 480) -> CGImage {
        var rng = SeededRandom(seed: seed)
        let ctx = context(width: width, height: height)
        let band = 8 + Int(rng.unit() * 24)
        for x in stride(from: 0, to: width, by: band) {
            ctx.setFillColor(CGColor(red: rng.unit(), green: rng.unit(), blue: rng.unit(), alpha: 1))
            ctx.fill(CGRect(x: x, y: 0, width: band, height: height))
        }
        let cell = 20 + Int(rng.unit() * 20)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        for y in stride(from: 0, to: height / 2, by: cell) {
            for x in stride(from: 0, to: width, by: cell) where (x / cell + y / cell) % 2 == 0 {
                ctx.fill(CGRect(x: x, y: y, width: cell, height: cell))
            }
        }
        return ctx.makeImage()!
    }

    /// The same scene with the camera moved by (dx, dy) pixels.
    static func shifted(_ image: CGImage, dx: Int, dy: Int) -> CGImage {
        let ctx = context(width: image.width, height: image.height)
        ctx.draw(image, in: CGRect(x: dx, y: dy, width: image.width, height: image.height))
        return ctx.makeImage()!
    }

    /// Draws a subject that moves with `step` (a person walking through a burst).
    static func withSubject(_ image: CGImage, seed: UInt64, step: Int) -> CGImage {
        var rng = SeededRandom(seed: seed &+ 7)
        let ctx = context(width: image.width, height: image.height)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.setFillColor(CGColor(red: rng.unit(), green: rng.unit(), blue: rng.unit(), alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 120 + step * 35, y: 140, width: 130, height: 200))
        ctx.setFillColor(CGColor(red: rng.unit(), green: rng.unit(), blue: rng.unit(), alpha: 1))
        ctx.fill(CGRect(x: 150 + step * 35, y: 340, width: 70, height: 90))
        return addGrain(ctx.makeImage()!, seed: seed &+ UInt64(step))
    }

    /// Same image at another size.
    static func resized(_ image: CGImage, scale: Double) -> CGImage {
        let w = max(1, Int(Double(image.width) * scale))
        let h = max(1, Int(Double(image.height) * scale))
        let ctx = context(width: w, height: h)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    /// Strong blur: shrink by `factor` then enlarge back.
    static func blurred(_ image: CGImage, factor: Double = 12) -> CGImage {
        let small = resized(image, scale: 1 / factor)
        let ctx = context(width: image.width, height: image.height)
        ctx.interpolationQuality = .high
        ctx.draw(small, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()!
    }

    /// JPEG round trip at the given quality.
    static func recompressed(_ image: CGImage, quality: Double = 0.4) -> CGImage {
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(
            dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        CGImageDestinationFinalize(dest)
        let source = CGImageSourceCreateWithData(data, nil)!
        return CGImageSourceCreateImageAtIndex(source, 0, nil)!
    }

    /// Cropped to the centre `fraction` (an edit, not a duplicate).
    static func cropped(_ image: CGImage, fraction: Double = 0.6) -> CGImage {
        let w = Int(Double(image.width) * fraction)
        let h = Int(Double(image.height) * fraction)
        return image.cropping(
            to: CGRect(x: (image.width - w) / 2, y: (image.height - h) / 2, width: w, height: h))!
    }

    private static func context(width: Int, height: Int) -> CGContext {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }
}

struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
