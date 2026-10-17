import CoreGraphics
import Foundation
import Testing

@testable import CleanupKit

@Suite struct SimilarShotsDetectorTests {
    let detector = SimilarShotsDetector()

    func shot(
        _ id: String, _ image: CGImage, seconds: Double, burst: String? = nil,
        favorite: Bool = false
    ) async throws -> LibraryItem {
        let m = Make.meta(id, date: Date(timeIntervalSince1970: seconds), favorite: favorite, burst: burst)
        let a = try await DefaultAnalyzer().analyze(image, metadata: m)
        return LibraryItem(metadata: m, analysisSource: .localPreview, analysis: a)
    }

    static func burstFrame(_ base: CGImage, _ i: Int) -> CGImage {
        let ctx = CGContext(
            data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(base, in: CGRect(x: i * 4, y: i * 2, width: base.width, height: base.height))
        return ctx.makeImage()!
    }

    @Test func shotsOfTheSameMomentGroup() async throws {
        let base = TestImages.scene(seed: 300)
        var items: [LibraryItem] = []
        for i in 0..<4 {
            items.append(try await shot("s\(i)", Self.burstFrame(base, i), seconds: Double(i) * 2))
        }
        items.append(try await shot("other", TestImages.scene(seed: 301), seconds: 10))
        let groups = detector.detect(items: items)
        #expect(groups.count == 1)
        #expect(Set(groups[0].members) == ["s0", "s1", "s2", "s3"])
        #expect(groups[0].keepers.count == 1)
    }

    @Test func photosMoreThanAMinuteApartDoNotGroup() async throws {
        let base = TestImages.scene(seed: 310)
        let items = [
            try await shot("a", base, seconds: 0),
            try await shot("b", Self.burstFrame(base, 1), seconds: 120),
        ]
        #expect(detector.detect(items: items).isEmpty)
    }

    @Test func sameBurstAlwaysGroups() async throws {
        let items = [
            try await shot("a", TestImages.scene(seed: 320), seconds: 0, burst: "B"),
            try await shot("b", TestImages.scene(seed: 321), seconds: 200, burst: "B"),
        ]
        #expect(detector.detect(items: items).count == 1)
    }

    @Test func itemsAlreadyInDuplicatesAreExcluded() async throws {
        let base = TestImages.scene(seed: 330)
        let items = [
            try await shot("a", base, seconds: 0),
            try await shot("copy", base, seconds: 1),
            try await shot("b", Self.burstFrame(base, 2), seconds: 2),
        ]
        let builder = DefaultResultsBuilder(detectors: [DuplicatePhotoDetector(), detector])
        let results = builder.buildResults(items: items, keepMarks: [])
        #expect(Set(results.category(.duplicates)?.allMembers ?? []) == ["a", "copy"])
        // Only one photo is left for Similar, so there is no similar group.
        #expect(results.category(.similar) == nil)
    }

    @Test func bestShotIsFavoriteElseSharpestElseBestFace() {
        func item(_ id: String, sharp: Double, face: Double? = nil, fav: Bool = false) -> LibraryItem {
            Make.item(Make.meta(id, favorite: fav), sharpness: sharp, face: face)
        }
        #expect(KeeperRules.similarKeepers([item("a", sharp: 0.6), item("b", sharp: 0.8)]) == ["b"])
        #expect(
            KeeperRules.similarKeepers([item("a", sharp: 0.8, face: 0.3), item("b", sharp: 0.79, face: 0.9)])
                == ["b"])
        #expect(KeeperRules.similarKeepers([item("a", sharp: 0.9), item("f", sharp: 0.2, fav: true)]) == ["f"])
    }
}
