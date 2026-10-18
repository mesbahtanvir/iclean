import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A rendered asset on disk.
public struct RenderedFile: Sendable, Hashable {
    public var assetID: String
    public var url: URL
    public var width: Int
    public var height: Int
    public var bytes: Int64
}

/// Draws baseline assets from their recipes. Pure drawing and encoding: no Photos
/// library, so it runs on every platform and in host tests.
public enum BaselineRenderer {
    // MARK: Files

    /// Renders every asset into `folder` and returns what was written, by asset id.
    public static func renderAll(_ catalog: BaselineCatalog, to folder: URL) async throws
        -> [String: RenderedFile]
    {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var out: [String: RenderedFile] = [:]
        for asset in catalog.assets {
            out[asset.id] = try await render(asset, to: folder)
        }
        return out
    }

    public static func render(_ asset: BaselineAsset, to folder: URL) async throws -> RenderedFile {
        let url = folder.appending(path: asset.filename)
        try? FileManager.default.removeItem(at: url)
        switch asset.recipe.format {
        case .mov(let w, let h, let bitrate):
            guard case .video(let seed, let seconds) = asset.recipe.base else {
                throw BaselineError.badRecipe(asset.id)
            }
            try await writeVideo(
                to: url, seed: seed, seconds: seconds, width: w, height: h, bitrate: bitrate)
            return RenderedFile(
                assetID: asset.id, url: url, width: w, height: h, bytes: fileSize(url))
        case .jpeg, .png:
            let image = try image(for: asset.recipe)
            try writeImage(image, format: asset.recipe.format, date: asset.captureDate,
                screenshot: asset.kind == .screenshot, to: url)
            return RenderedFile(
                assetID: asset.id, url: url, width: image.width, height: image.height,
                bytes: fileSize(url))
        }
    }

    private static func fileSize(_ url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    // MARK: Images

    /// The pixels of a photo recipe.
    public static func image(for recipe: BaselineRecipe) throws -> CGImage {
        var image: CGImage
        switch recipe.base {
        case .scene(let seed): image = Draw.scene(seed: seed)
        case .lowTexture(let seed): image = Draw.lowTexture(seed: seed)
        case .stripes(let seed, let w, let h): image = Draw.stripes(seed: seed, width: w, height: h)
        case .burstFrame(let sceneSeed, let index):
            // The camera drifts a little and the subject walks across, like a real burst.
            let base = Draw.scene(seed: 30_000 + sceneSeed)
            image = Draw.withSubject(
                Draw.shifted(base, dx: index * 8, dy: index * 3), seed: sceneSeed, step: index)
        case .video: throw BaselineError.badRecipe("video recipe used as an image")
        }
        for step in recipe.steps {
            switch step {
            case .resize(let s): image = Draw.resized(image, scale: s)
            case .recompress(let q): image = try Draw.recompressed(image, quality: q)
            case .crop(let f): image = Draw.cropped(image, fraction: f)
            case .blur(let f): image = Draw.blurred(image, factor: f)
            case .motionBlur(let n): image = Draw.motionBlurred(image, length: n)
            }
        }
        return image
    }

    private static func writeImage(
        _ image: CGImage, format: BaselineRecipe.Format, date: Date, screenshot: Bool, to url: URL
    ) throws {
        let type: UTType = format == .png ? .png : .jpeg
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
        else { throw BaselineError.writeFailed(url.lastPathComponent) }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        let stamp = formatter.string(from: date)
        var exif: [CFString: Any] = [
            kCGImagePropertyExifDateTimeOriginal: stamp,
            kCGImagePropertyExifDateTimeDigitized: stamp,
        ]
        // Photos tags an image as a screenshot when its Exif user comment says so.
        if screenshot { exif[kCGImagePropertyExifUserComment] = "Screenshot" }
        var properties: [CFString: Any] = [kCGImagePropertyExifDictionary: exif]
        if case .jpeg(let quality) = format {
            properties[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw BaselineError.writeFailed(url.lastPathComponent) }
    }

    // MARK: Video

    /// Encodes a short H.264 clip: a scene with a subject moving across it.
    private static func writeVideo(
        to url: URL, seed: UInt64, seconds: Double, width: Int, height: Int, bitrate: Int
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate, AVVideoExpectedSourceFrameRateKey: 10,
                AVVideoMaxKeyFrameIntervalKey: 10,
            ],
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            ])
        guard writer.canAdd(input) else { throw BaselineError.writeFailed(url.lastPathComponent) }
        writer.add(input)
        guard writer.startWriting() else { throw BaselineError.writeFailed(url.lastPathComponent) }
        writer.startSession(atSourceTime: .zero)

        // The scene is drawn once at the video size; only the subject moves per frame.
        let scene = Draw.resized(Draw.scene(seed: seed), to: CGSize(width: width, height: height))
        let frames = Int(seconds * 10)
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            guard let pool = adaptor.pixelBufferPool else { throw BaselineError.writeFailed("pool") }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { throw BaselineError.writeFailed("buffer") }
            Draw.videoFrame(scene, index: i, of: frames, into: buffer)
            adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(i), timescale: 10))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed {
            throw BaselineError.writeFailed(writer.error?.localizedDescription ?? "video")
        }
    }
}

public enum BaselineError: Error, CustomStringConvertible {
    case badRecipe(String)
    case writeFailed(String)
    case notAuthorized(String)
    case importFailed(String)

    public var description: String {
        switch self {
        case .badRecipe(let s): "bad recipe: \(s)"
        case .writeFailed(let s): "could not write \(s)"
        case .notAuthorized(let s): "Photos access was not granted (status: \(s))"
        case .importFailed(let s): "import failed: \(s)"
        }
    }
}

// MARK: - Drawing (the calibrated recipes from the accuracy tests)

enum Draw {
    static func scene(seed: UInt64, width: Int = 640, height: Int = 480) -> CGImage {
        var rng = SeededRandom(seed: seed)
        let ctx = context(width: width, height: height)
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

    static func lowTexture(seed: UInt64, width: Int = 640, height: Int = 480) -> CGImage {
        var rng = SeededRandom(seed: seed)
        let ctx = context(width: width, height: height)
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

    static func stripes(seed: UInt64, width: Int, height: Int) -> CGImage {
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

    static func shifted(_ image: CGImage, dx: Int, dy: Int) -> CGImage {
        let ctx = context(width: image.width, height: image.height)
        ctx.draw(image, in: CGRect(x: dx, y: dy, width: image.width, height: image.height))
        return ctx.makeImage()!
    }

    /// A bright subject that contrasts with any background, so every step changes enough of
    /// the picture to be a different frame and not a copy of the previous one.
    static func withSubject(_ image: CGImage, seed: UInt64, step: Int) -> CGImage {
        let ctx = context(width: image.width, height: image.height)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.setFillColor(CGColor(red: 0.96, green: 0.9, blue: 0.15, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 70 + step * 45, y: 110, width: 150, height: 230))
        ctx.setFillColor(CGColor(red: 0.08, green: 0.1, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 100 + step * 45, y: 320, width: 90, height: 110))
        return addGrain(ctx.makeImage()!, seed: seed &+ UInt64(step))
    }

    static func resized(_ image: CGImage, scale: Double) -> CGImage {
        resized(
            image,
            to: CGSize(
                width: max(1, Int(Double(image.width) * scale)),
                height: max(1, Int(Double(image.height) * scale))))
    }

    static func resized(_ image: CGImage, to size: CGSize) -> CGImage {
        let ctx = context(width: Int(size.width), height: Int(size.height))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
        return ctx.makeImage()!
    }

    static func blurred(_ image: CGImage, factor: Double) -> CGImage {
        let small = resized(image, scale: 1 / factor)
        let ctx = context(width: image.width, height: image.height)
        ctx.interpolationQuality = .high
        ctx.draw(small, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()!
    }

    /// Averages `length` horizontally shifted copies: a camera that moved sideways.
    static func motionBlurred(_ image: CGImage, length: Int) -> CGImage {
        let src = context(width: image.width, height: image.height)
        var sum = [Float](repeating: 0, count: src.bytesPerRow * image.height)
        for k in 0..<length {
            src.clear(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            src.draw(
                image,
                in: CGRect(x: k - length / 2, y: 0, width: image.width, height: image.height))
            let data = src.data!.assumingMemoryBound(to: UInt8.self)
            for i in 0..<sum.count { sum[i] += Float(data[i]) }
        }
        let out = context(width: image.width, height: image.height)
        let data = out.data!.assumingMemoryBound(to: UInt8.self)
        for i in 0..<sum.count { data[i] = i % 4 == 3 ? 255 : UInt8(sum[i] / Float(length)) }
        return out.makeImage()!
    }

    static func cropped(_ image: CGImage, fraction: Double) -> CGImage {
        let w = Int(Double(image.width) * fraction)
        let h = Int(Double(image.height) * fraction)
        return image.cropping(
            to: CGRect(x: (image.width - w) / 2, y: (image.height - h) / 2, width: w, height: h))!
    }

    static func recompressed(_ image: CGImage, quality: Double) throws -> CGImage {
        let data = NSMutableData()
        guard
            let dest = CGImageDestinationCreateWithData(
                data, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw BaselineError.writeFailed("recompress") }
        CGImageDestinationAddImage(
            dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        CGImageDestinationFinalize(dest)
        guard let source = CGImageSourceCreateWithData(data, nil),
            let out = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw BaselineError.writeFailed("recompress") }
        return out
    }

    /// One frame of a clip: the scene with a subject that walks from left to right.
    static func videoFrame(_ scene: CGImage, index: Int, of count: Int, into buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        guard
            let ctx = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer), width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        ctx.draw(scene, in: CGRect(x: 0, y: 0, width: w, height: h))
        let progress = Double(index) / Double(max(1, count - 1))
        let sw = Double(w) * 0.2
        let sh = Double(h) * 0.42
        ctx.setFillColor(CGColor(red: 0.9, green: 0.3, blue: 0.2, alpha: 1))
        ctx.fillEllipse(
            in: CGRect(x: progress * (Double(w) - sw), y: Double(h) * 0.3, width: sw, height: sh))
    }

    static func context(width: Int, height: Int) -> CGContext {
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
