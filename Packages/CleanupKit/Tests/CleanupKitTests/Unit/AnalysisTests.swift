import CoreGraphics
import Testing

@testable import CleanupKit

@Suite struct AnalysisTests {
    let original = TestImages.scene(seed: 1)
    let other = TestImages.scene(seed: 2)

    @Test func dHashToleratesResizeAndRecompression() {
        let base = dHash(original)
        let limit = DuplicateThresholds.hashDistance
        #expect(hammingDistance(base, dHash(TestImages.resized(original, scale: 0.5))) <= limit)
        #expect(hammingDistance(base, dHash(TestImages.recompressed(original))) <= limit)
    }

    @Test func thumbprintSeparatesCopiesFromOtherPhotos() {
        let t = Thumbprint.compute(original)
        let limit = DuplicateThresholds.thumbprint
        #expect(Thumbprint.detailSimilarity(t, Thumbprint.compute(TestImages.resized(original, scale: 0.5))) >= limit)
        #expect(Thumbprint.detailSimilarity(t, Thumbprint.compute(TestImages.recompressed(original, quality: 0.2))) >= limit)
        #expect(Thumbprint.detailSimilarity(t, Thumbprint.compute(other)) < 0.3)
        #expect(Thumbprint.detailSimilarity(t, Thumbprint.compute(TestImages.cropped(original))) < limit)
        // Different photos that are both very blurry share a smooth layout, not detail.
        let blurA = Thumbprint.compute(TestImages.blurred(original, factor: 16))
        let blurB = Thumbprint.compute(TestImages.blurred(other, factor: 16))
        #expect(Thumbprint.detailSimilarity(blurA, blurB) < 0.3)
    }

    @Test func dHashSeparatesUnrelatedImages() {
        #expect(hammingDistance(dHash(original), dHash(other)) > 10)
    }

    @Test func blurLowersSharpness() {
        #expect(Sharpness.score(TestImages.blurred(original)) < BlurThresholds.sharpness)
        #expect(Sharpness.score(original) > BlurThresholds.sharpness + 0.1)
    }

    @Test func featurePrintCopyIsCloserThanUnrelated() async throws {
        let a = try await FeaturePrint.compute(original)
        let copy = try await FeaturePrint.compute(TestImages.resized(original, scale: 0.5))
        let unrelated = try await FeaturePrint.compute(TestImages.stripes(seed: 1))
        #expect(FeaturePrint.distance(a, copy) < FeaturePrint.distance(a, unrelated))
    }
}
