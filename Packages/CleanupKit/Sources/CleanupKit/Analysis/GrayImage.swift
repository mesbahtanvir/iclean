import CoreGraphics

/// An 8-bit grayscale copy of an image, used by dHash and sharpness.
struct GrayImage {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    /// Draws `image` into a grayscale buffer of exactly `width` × `height`.
    init?(_ image: CGImage, width: Int, height: Int, interpolation: CGInterpolationQuality = .high) {
        guard width > 0, height > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: width * height)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard
                let context = CGContext(
                    data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            context.interpolationQuality = interpolation
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.width = width
        self.height = height
        self.pixels = buffer
    }

    /// Draws `image` scaled so its longer side is at most `maxDimension`.
    init?(_ image: CGImage, maxDimension: Int) {
        let scale = min(1, Double(maxDimension) / Double(max(image.width, image.height)))
        self.init(
            image, width: max(1, Int((Double(image.width) * scale).rounded())),
            height: max(1, Int((Double(image.height) * scale).rounded())))
    }

    subscript(x: Int, y: Int) -> UInt8 { pixels[y * width + x] }
}
