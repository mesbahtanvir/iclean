import Foundation
import Testing

@testable import CleanupKit

@Suite struct DuplicateVideoDetectorTests {
    func video(
        _ id: String, seed: UInt64, scale: Double = 1, duration: Double, w: Int = 1920, h: Int = 1080,
        minutes: Double = 0, favorite: Bool = false
    ) async throws -> LibraryItem {
        let poster = TestImages.resized(TestImages.scene(seed: seed, width: 640, height: 360), scale: scale)
        let m = Make.meta(
            id, kind: .video, date: Date(timeIntervalSince1970: minutes * 60), width: w, height: h,
            favorite: favorite, duration: duration)
        let a = try await DefaultAnalyzer().analyze(poster, metadata: m)
        return LibraryItem(metadata: m, analysisSource: .localPreview, analysis: a, byteSize: Int64(w * h))
    }

    @Test func copiesGroupAndHigherQualityIsKept() async throws {
        let items = [
            try await video("hd", seed: 1, duration: 12, minutes: 5),
            try await video("sd", seed: 1, scale: 0.5, duration: 12.3, w: 1280, h: 720, minutes: 1),
            try await video("other", seed: 2, duration: 12),
        ]
        let groups = DuplicateVideoDetector().detect(items: items)
        #expect(groups.count == 1)
        #expect(Set(groups[0].members) == ["hd", "sd"])
        #expect(groups[0].keepers == ["hd"])
    }

    @Test func differentLengthsNeverGroup() async throws {
        let items = [
            try await video("a", seed: 3, duration: 12),
            try await video("b", seed: 3, duration: 20),
        ]
        #expect(DuplicateVideoDetector().detect(items: items).isEmpty)
    }

    @Test func favoriteIsKept() async throws {
        let items = [
            try await video("hd", seed: 4, duration: 8),
            try await video("fav", seed: 4, scale: 0.5, duration: 8, w: 1280, h: 720, favorite: true),
        ]
        #expect(DuplicateVideoDetector().detect(items: items).first?.keepers == ["fav"])
    }
}
