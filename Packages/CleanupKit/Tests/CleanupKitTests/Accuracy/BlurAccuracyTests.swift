import CoreGraphics
import Foundation
import Testing

@testable import CleanupKit

extension LabeledFixtures {
    /// Synthetic blur set: sharp photos, clearly blurry ones, soft ones (ambiguous,
    /// left unlabeled), low-texture sharp scenes and blurry portrait shots.
    static func blur() -> [LabeledImage] {
        var out: [LabeledImage] = []
        var rng = SeededRandom(seed: 77)
        var minute = 100_000.0
        func next() -> Double { minute += 120; return minute }
        for i in 0..<60 {
            out.append(LabeledImage(file: "blur/sharp\(i).jpg", image: TestImages.scene(seed: UInt64(20_000 + i)), minutes: next(), blurry: false))
        }
        for i in 0..<40 {
            let factor = 10 + rng.unit() * 14
            let image = TestImages.addGrain(TestImages.blurred(TestImages.scene(seed: UInt64(21_000 + i)), factor: factor), seed: UInt64(i))
            out.append(LabeledImage(file: "blur/blurry\(i).jpg", image: image, minutes: next(), blurry: true))
        }
        for i in 0..<20 {
            let image = TestImages.blurred(TestImages.scene(seed: UInt64(22_000 + i)), factor: 3)
            out.append(LabeledImage(file: "blur/soft\(i).jpg", image: image, minutes: next(), blurry: nil))
        }
        for i in 0..<15 {
            out.append(LabeledImage(file: "blur/lowtexture\(i).jpg", image: TestImages.lowTexture(seed: UInt64(23_000 + i)), minutes: next(), blurry: false))
        }
        for i in 0..<10 {
            let image = TestImages.blurred(TestImages.scene(seed: UInt64(24_000 + i)), factor: 16)
            out.append(LabeledImage(file: "blur/portrait\(i).jpg", image: image, minutes: next(), blurry: false, portrait: true))
        }
        return out
    }
}

/// SC-003: ≥ 85% of clearly blurry photos flagged; < 10% of flagged photos are sharp.
@Suite struct BlurAccuracyTests {
    @Test func localPreviews() async throws {
        try await measure(LabeledFixtures.blur(), name: "local 512 px")
    }

    /// Cloud-only items are analyzed from small previews.
    @Test func cloudPreviews() async throws {
        let small = LabeledFixtures.blur().map { l -> LabeledImage in
            var l = l
            l.image = TestImages.resized(l.image, scale: 256.0 / Double(max(l.image.width, l.image.height)))
            return l
        }
        try await measure(small, name: "preview 256 px", minimumRecall: 0.6)
    }

    @Test(.enabled(if: LabeledFixtures.real()?.contains { $0.blurry != nil } == true))
    func realPhotos() async throws {
        try await measure(LabeledFixtures.real()!.filter { $0.blurry != nil }, name: "real")
    }

    func measure(_ images: [LabeledImage], name: String, minimumRecall: Double = 0.85) async throws {
        let items = try await LabeledFixtures.analyze(images)
        let flagged = Set(BlurDetector().detect(items: items).flatMap(\.members))
        let blurry = images.filter { $0.blurry == true }.map(\.file)
        let sharp = Set(images.filter { $0.blurry == false }.map(\.file))
        let recall = Double(blurry.filter(flagged.contains).count) / Double(blurry.count)
        let falseFlags = flagged.isEmpty ? 0 : Double(flagged.filter(sharp.contains).count) / Double(flagged.count)
        print("Blur accuracy (\(name)): recall \(recall), false flags \(falseFlags), flagged \(flagged.count)")
        #expect(recall >= minimumRecall)
        #expect(falseFlags < 0.10)
        #expect(images.filter(\.portrait).allSatisfy { !flagged.contains($0.file) })
    }
}
