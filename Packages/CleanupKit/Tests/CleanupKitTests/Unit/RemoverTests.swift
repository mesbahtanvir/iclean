import Testing

@testable import CleanupKit

@Suite struct RemoverTests {
    func setup() -> (FakePhotoLibrary, CleanupResults) {
        let lib = FakePhotoLibrary()
        let image = TestImages.scene(seed: 9, width: 32, height: 32)
        var items: [LibraryItem] = []
        for id in ["k", "x", "y", "s"] {
            lib.add(Make.meta(id), preview: .local(image))
            items.append(Make.item(Make.meta(id), size: id == "s" ? nil : 100))
        }
        let detectors: [any CategoryDetector] = [
            StubDetector(category: .duplicates) { _ in
                [ResultGroup(type: .duplicatePhotos, members: ["k", "x", "y"], keepers: ["k"])]
            },
            StubDetector(category: .screenshots, needsAnalysis: false) { _ in
                [ResultGroup(type: .single, members: ["s"])]
            },
        ]
        return (lib, DefaultResultsBuilder(detectors: detectors).buildResults(items: items, keepMarks: []))
    }

    @Test func summaryByCategory() {
        let (lib, results) = setup()
        let preview = DefaultRemover(library: lib).summary(for: ["x", "y", "s"], in: results)
        #expect(preview.count == 3)
        #expect(preview.byCategory[.duplicates]?.count == 2)
        #expect(preview.byCategory[.duplicates]?.bytes == 200)
        #expect(preview.byCategory[.screenshots]?.count == 1)
        #expect(preview.isEstimate)
        #expect(preview.wholeGroupsSelected.isEmpty)
    }

    @Test func refusesWholeGroupWithoutConfirmation() async {
        let (lib, results) = setup()
        let remover = DefaultRemover(library: lib)
        await #expect(throws: RemovalError.self) {
            try await remover.remove(["k", "x", "y"], in: results, confirmRemoveAll: false)
        }
        #expect(lib.allIDs.count == 4)
        let summary = try? await remover.remove(["k", "x", "y"], in: results, confirmRemoveAll: true)
        #expect(summary?.removedCount == 3)
    }

    @Test func partialFailureCountsOnlyRemovedBytes() async throws {
        let (lib, results) = setup()
        lib.failingRemovals = ["y"]
        let summary = try await DefaultRemover(library: lib)
            .remove(["x", "y"], in: results, confirmRemoveAll: false)
        #expect(summary.removedCount == 1)
        #expect(summary.failedAssetIDs == ["y"])
        #expect(summary.bytesFreed == 100)
        #expect(!summary.isEstimate)
    }

    @Test func estimateFlagPropagates() async throws {
        let (lib, results) = setup()
        let summary = try await DefaultRemover(library: lib)
            .remove(["s"], in: results, confirmRemoveAll: false)
        #expect(summary.isEstimate)
    }

    @Test func cancelledPromptRemovesNothing() async throws {
        let (lib, results) = setup()
        lib.cancelRemoval = true
        let summary = try await DefaultRemover(library: lib)
            .remove(["x"], in: results, confirmRemoveAll: false)
        #expect(summary.cancelled)
        #expect(summary.removedCount == 0)
        #expect(lib.allIDs.count == 4)
    }
}
