import CoreGraphics
import Foundation
import ImageIO

@testable import CleanupKit

/// A labeled test image. Labels match `Fixtures/labels.json`.
struct LabeledImage {
    var file: String
    var image: CGImage
    var kind: ItemKind = .photo
    var minutes: Double
    var duplicateGroup: String?
    var similarGroup: String?
    var edited = false
    var favorite = false
    var blurry: Bool?
    var portrait = false
    var longExposure = false
    var duration: Double?

    var metadata: AssetMetadata {
        let date = Date(timeIntervalSince1970: 1_600_000_000 + minutes * 60)
        return AssetMetadata(
            assetID: file, kind: kind, captureDate: date, modificationDate: date,
            pixelWidth: image.width, pixelHeight: image.height, duration: duration,
            isFavorite: favorite, hasAdjustments: edited, isPortrait: portrait,
            isLongExposure: longExposure)
    }
}

/// Builds the synthetic labeled set, or loads real fixtures from `Fixtures/` when a
/// `labels.json` is present (research R14).
enum LabeledFixtures {
    static var repoRoot: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Real photos, if someone added them under `Fixtures/` with a `labels.json`.
    static func real() -> [LabeledImage]? {
        let labelsURL = repoRoot.appending(path: "Fixtures/labels.json")
        guard let data = try? Data(contentsOf: labelsURL),
            let labels = try? JSONDecoder().decode([Label].self, from: data)
        else { return nil }
        return labels.enumerated().compactMap { i, label in
            let url = repoRoot.appending(path: "Fixtures").appending(path: label.file)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else { return nil }
            return LabeledImage(
                file: label.file, image: image, minutes: Double(i) * 30,
                duplicateGroup: label.duplicateGroup, similarGroup: label.similarGroup,
                edited: label.edited ?? false, favorite: label.favorite ?? false,
                blurry: label.blurry, portrait: label.portrait ?? false,
                longExposure: label.longExposure ?? false)
        }
    }

    struct Label: Codable {
        var file: String
        var duplicateGroup: String?
        var similarGroup: String?
        var edited: Bool?
        var favorite: Bool?
        var blurry: Bool?
        var portrait: Bool?
        var longExposure: Bool?
    }

    /// Synthetic duplicates set: 40 groups of 2–4 copies (resized, recompressed),
    /// 20 edited versions of group originals, and 60 unrelated photos.
    static func duplicates() -> [LabeledImage] {
        var out: [LabeledImage] = []
        var rng = SeededRandom(seed: 2026)
        var minute = 0.0
        for g in 0..<40 {
            let base = TestImages.scene(seed: UInt64(1_000 + g))
            out.append(LabeledImage(file: "duplicates/g\(g)-orig.png", image: base, minutes: minute, duplicateGroup: "g\(g)"))
            let copies = 1 + Int(rng.unit() * 3)
            for c in 0..<copies {
                minute += 90
                let variant: CGImage
                switch (g + c) % 3 {
                case 0: variant = TestImages.resized(base, scale: 0.4 + rng.unit() * 0.4)
                case 1: variant = TestImages.recompressed(base, quality: 0.3 + rng.unit() * 0.6)
                default:
                    variant = TestImages.recompressed(TestImages.resized(base, scale: 0.5), quality: 0.6)
                }
                out.append(LabeledImage(
                    file: "duplicates/g\(g)-copy\(c).jpg", image: variant, minutes: minute,
                    duplicateGroup: "g\(g)", favorite: c == 0 && g % 10 == 0))
            }
            if g < 20 {
                minute += 5
                let edit = g % 2 == 0 ? TestImages.cropped(base, fraction: 0.8) : base
                out.append(LabeledImage(
                    file: "duplicates/g\(g)-edited.jpg", image: edit, minutes: minute, edited: true))
            }
            minute += 600
        }
        for i in 0..<60 {
            minute += 600
            out.append(LabeledImage(
                file: "duplicates/single\(i).jpg", image: TestImages.scene(seed: UInt64(5_000 + i)),
                minutes: minute))
        }
        return out
    }

    /// Analyzes images the way the scanner does.
    static func analyze(_ images: [LabeledImage], analyzer: Analyzer = DefaultAnalyzer()) async throws -> [LibraryItem] {
        var items: [LibraryItem] = []
        for labeled in images {
            let analysis = try await analyzer.analyze(labeled.image, metadata: labeled.metadata)
            items.append(LibraryItem(
                metadata: labeled.metadata, analysisSource: .localPreview, analysis: analysis,
                byteSize: Int64(labeled.image.width * labeled.image.height / 3)))
        }
        return items
    }

    /// Writes a labeled set to disk so `scripts/seed-simulator.sh` can import it.
    static func export(_ images: [LabeledImage], to folder: URL) throws -> [Label] {
        var labels: [Label] = []
        for labeled in images {
            let url = folder.appending(path: labeled.file)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let type = url.pathExtension == "png" ? "public.png" : "public.jpeg"
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else {
                continue
            }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            let date = formatter.string(from: labeled.metadata.captureDate ?? .now)
            let properties: [CFString: Any] = [
                kCGImagePropertyExifDictionary: [
                    kCGImagePropertyExifDateTimeOriginal: date,
                    kCGImagePropertyExifDateTimeDigitized: date,
                ]
            ]
            CGImageDestinationAddImage(dest, labeled.image, properties as CFDictionary)
            CGImageDestinationFinalize(dest)
            labels.append(Label(
                file: labeled.file, duplicateGroup: labeled.duplicateGroup,
                similarGroup: labeled.similarGroup, edited: labeled.edited,
                favorite: labeled.favorite, blurry: labeled.blurry, portrait: labeled.portrait,
                longExposure: labeled.longExposure))
        }
        return labels
    }
}
