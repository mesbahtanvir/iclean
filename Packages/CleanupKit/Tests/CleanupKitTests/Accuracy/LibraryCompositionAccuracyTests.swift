import Foundation
import Testing

@testable import CleanupKit

/// Runs every photo detector together on the whole labeled set, like a real scan,
/// and checks that each category holds what it should (no cross-contamination).
@Suite struct LibraryCompositionAccuracyTests {
    @Test func categoriesHoldTheRightPhotos() async throws {
        let images = LabeledFixtures.duplicates() + LabeledFixtures.extraSets()
        let labels = Dictionary(uniqueKeysWithValues: images.map { ($0.file, $0) })
        let items = try await LabeledFixtures.analyze(images)
        let results = DefaultResultsBuilder(detectors: [
            DuplicatePhotoDetector(), SimilarShotsDetector(), BlurDetector(), ScreenshotsCategory(),
        ]).buildResults(items: items, keepMarks: [])

        func precision(_ c: CleanupCategory, _ isRight: (LabeledImage) -> Bool) -> Double {
            let ids = results.category(c)?.removable ?? []
            guard !ids.isEmpty else { return 0 }
            let right = ids.filter { labels[$0].map(isRight) ?? false }.count
            print("Composition \(c): \(ids.count) removable, precision \(Double(right) / Double(ids.count))")
            return Double(right) / Double(ids.count)
        }
        // Near-identical burst frames may also count as duplicates; anything else may not.
        #expect(precision(.duplicates) { $0.duplicateGroup != nil || $0.similarGroup != nil } >= 0.98)
        #expect(precision(.similar) { $0.similarGroup != nil } >= 0.95)
        #expect(precision(.blurry) { $0.blurry == true } >= 0.95)
        #expect(precision(.screenshots) { $0.kind == .screenshot } == 1)

        // At least half of the burst frames end up in Similar. Frames where almost
        // nothing changed are near-identical and may be listed as duplicates instead.
        let burstFrames = images.filter { $0.similarGroup != nil }.count - 20
        let similarRemovable = results.category(.similar)?.removable.count ?? 0
        #expect(Double(similarRemovable) >= Double(burstFrames) * 0.5)
    }
}
