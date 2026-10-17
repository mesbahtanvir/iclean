import CoreGraphics
import Foundation
import Testing

@testable import CleanupKit

@Suite struct DuplicatePhotoDetectorTests {
    /// Analyzes an image the way the scanner does.
    static func analyzed(
        _ id: String, _ image: CGImage, width: Int? = nil, height: Int? = nil,
        edited: Bool = false, favorite: Bool = false, minutes: Double = 0, size: Int64 = 1_000
    ) async throws -> LibraryItem {
        let w = width ?? image.width
        let h = height ?? image.height
        let m = Make.meta(
            id, date: Date(timeIntervalSince1970: minutes * 60), width: w, height: h,
            favorite: favorite, edited: edited)
        let analysis = try await DefaultAnalyzer().analyze(image, metadata: m)
        return LibraryItem(metadata: m, analysisSource: .localPreview, analysis: analysis, byteSize: size)
    }

    let detector = DuplicatePhotoDetector()

    @Test func copiesAtOtherSizesAndFormatsGroupTogether() async throws {
        let base = TestImages.scene(seed: 21)
        let items = [
            try await Self.analyzed("orig", base),
            try await Self.analyzed("half", TestImages.resized(base, scale: 0.5)),
            try await Self.analyzed("jpeg", TestImages.recompressed(base)),
            try await Self.analyzed("other", TestImages.scene(seed: 22)),
        ]
        let groups = detector.detect(items: items)
        #expect(groups.count == 1)
        #expect(Set(groups[0].members) == ["orig", "half", "jpeg"])
        #expect(groups[0].type == .duplicatePhotos)
        #expect(groups[0].keepers.count == 1)
    }

    @Test func editedVersionsAreNeverGroupedWithOriginals() async throws {
        let base = TestImages.scene(seed: 31)
        let items = [
            try await Self.analyzed("orig", base),
            // Same pixels but marked edited (e.g. a filter that barely changed the preview).
            try await Self.analyzed("edited", base, edited: true),
        ]
        #expect(detector.detect(items: items).isEmpty)
    }

    @Test func lookAlikesAreNotDuplicates() async throws {
        let items = try await (0..<6).asyncMap { i in
            try await Self.analyzed("p\(i)", TestImages.scene(seed: UInt64(40 + i)))
        }
        #expect(detector.detect(items: items).isEmpty)
    }

    @Test func aspectRatioMismatchNeverGroups() async throws {
        let base = TestImages.scene(seed: 51)
        let items = [
            try await Self.analyzed("landscape", base, width: 4032, height: 3024),
            try await Self.analyzed("square", base, width: 3024, height: 3024),
        ]
        #expect(detector.detect(items: items).isEmpty)
    }

    @Test func videosAndScreenshotsAreIgnored() async throws {
        let base = TestImages.scene(seed: 61)
        var a = try await Self.analyzed("a", base)
        var b = try await Self.analyzed("b", base)
        a.metadata.kind = .screenshot
        b.metadata.kind = .screenshot
        #expect(detector.detect(items: [a, b]).isEmpty)
    }

    @Test func cloudPreviewGroupsHaveLowerConfidence() async throws {
        let base = TestImages.scene(seed: 71)
        var a = try await Self.analyzed("a", base)
        let b = try await Self.analyzed("b", base)
        a.analysisSource = .cloudPreview
        let groups = detector.detect(items: [a, b])
        #expect(groups.first?.confidence == .lower)
    }

    @Test func scalesWithoutComparingEveryPair() async throws {
        // 2,000 distinct hashes plus one duplicate pair: must finish quickly.
        var rng = SeededRandom(seed: 5)
        var items = (0..<2_000).map { i in
            Make.item(Make.meta("r\(i)"), dHash: rng.next(), print: Data())
        }
        let base = try await Self.analyzed("dupA", TestImages.scene(seed: 81))
        var copy = base
        copy.metadata.assetID = "dupB"
        items += [base, copy]
        // The index must not hand back anything close to every pair (≈ 2 million).
        let pairs = HashIndex(maxDistance: DuplicateThresholds.hashDistance)
            .candidatePairs(items.map { $0.analysis?.dHash ?? 0 })
        #expect(pairs.count < 1_000)
        #expect(detector.detect(items: items).count == 1)
    }
}

extension Sequence {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var out: [T] = []
        for e in self { out.append(try await transform(e)) }
        return out
    }
}
