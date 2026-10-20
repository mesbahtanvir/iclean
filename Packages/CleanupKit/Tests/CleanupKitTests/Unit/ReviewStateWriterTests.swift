import Foundation
import Testing

@testable import CleanupKit

@Suite struct ReviewStateWriterTests {
    func intent(_ ids: [String]) -> ReviewIntent {
        var i = ReviewIntent()
        i.setSelected(ids, true, at: Date(timeIntervalSince1970: 1_700_000_000))
        return i
    }

    func saved(_ store: SwiftDataStore) async throws -> ReviewIntent? {
        guard let e = try await store.loadLaunchState().states[.decisions] else { return nil }
        return try StateCodec.open(e.payload, as: ReviewIntent.self)
    }

    /// Waits for a timed write without racing the clock: a loaded machine only makes it slower.
    func eventually(_ check: () async throws -> Bool) async throws -> Bool {
        for _ in 0..<200 {
            if try await check() { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    @Test func aChangeIsWrittenAfterTheQuietPeriod() async throws {
        let store = try InMemoryStore.make()
        let writer = ReviewStateWriter(
            store: store, debounce: .milliseconds(60), maxWait: .seconds(2))
        let g = await writer.currentGeneration()
        await writer.update(decisions: intent(["a"]), generation: g)
        #expect(try await saved(store) == nil)
        let written = try await eventually {
            try await saved(store)?.forcedOn.keys.sorted() == ["a"]
        }
        #expect(written)
    }

    @Test func aBurstOfChangesIsWrittenWithTheLatestValues() async throws {
        let store = try InMemoryStore.make()
        // A quiet period longer than the whole burst, however slowly the machine runs it.
        let writer = ReviewStateWriter(store: store, debounce: .seconds(2), maxWait: .seconds(30))
        let g = await writer.currentGeneration()
        for n in 1...10 {
            await writer.update(decisions: intent((0..<n).map { "p\($0)" }), generation: g)
        }
        #expect(try await saved(store) == nil, "nothing is written during the burst")
        let written = try await eventually { try await saved(store)?.forcedOn.count == 10 }
        #expect(written)
    }

    @Test func aLongBurstIsStillWrittenAtTheMaximumWait() async throws {
        let store = try InMemoryStore.make()
        // The quiet period is so long that only the maximum wait can write anything here.
        let writer = ReviewStateWriter(
            store: store, debounce: .seconds(60), maxWait: .milliseconds(300))
        let g = await writer.currentGeneration()
        var writtenDuringTheBurst = false
        // Changes keep arriving, so the quiet period never ends; the write must still happen.
        for n in 1...100 {
            await writer.update(decisions: intent(["p\(n)"]), generation: g)
            if try await saved(store) != nil {
                writtenDuringTheBurst = true
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(writtenDuringTheBurst, "the maximum wait writes while changes are still arriving")
    }

    @Test func flushWritesAtOnceAndReturnsWhenDone() async throws {
        let store = try InMemoryStore.make()
        let writer = ReviewStateWriter(store: store, debounce: .seconds(30), maxWait: .seconds(60))
        let g = await writer.currentGeneration()
        await writer.update(
            decisions: intent(["a", "b"]), position: ReviewPosition(path: [.category(.duplicates)]),
            generation: g)
        await writer.flush()
        #expect(try await saved(store)?.forcedOn.count == 2)
        let position = try #require(try await store.loadLaunchState().states[.position])
        #expect(
            try StateCodec.open(position.payload, as: ReviewPosition.self).path == [
                .category(.duplicates)
            ])
    }

    @Test func flushWithNothingPendingWritesNothing() async throws {
        let store = try InMemoryStore.make()
        let writer = ReviewStateWriter(store: store)
        await writer.flush()
        #expect(try await store.stateInfo().isEmpty)
    }

    @Test func invalidateDropsWhatIsPendingAndRefusesOlderUpdates() async throws {
        let store = try InMemoryStore.make()
        let writer = ReviewStateWriter(
            store: store, debounce: .milliseconds(50), maxWait: .seconds(1))
        let old = await writer.currentGeneration()
        await writer.update(decisions: intent(["a"]), generation: old)
        await writer.invalidate()
        // An update handed in before the invalidation is refused, and nothing pending is written.
        await writer.update(decisions: intent(["late"]), generation: old)
        try await Task.sleep(for: .milliseconds(300))
        await writer.flush()
        #expect(try await saved(store) == nil)
        // A new generation works again.
        let fresh = await writer.currentGeneration()
        #expect(fresh == old + 1)
        await writer.update(decisions: intent(["b"]), generation: fresh)
        await writer.flush()
        #expect(try await saved(store)?.forcedOn.keys.sorted() == ["b"])
    }

    @Test func deleteAllDataAfterInvalidateLeavesNothingBehind() async throws {
        let store = try InMemoryStore.make()
        let writer = ReviewStateWriter(
            store: store, debounce: .milliseconds(20), maxWait: .seconds(1))
        let g = await writer.currentGeneration()
        await writer.update(decisions: intent(["a"]), generation: g)
        await writer.invalidate()
        try await store.deleteAllData()
        try await Task.sleep(for: .milliseconds(200))
        #expect(try await store.stateInfo().isEmpty)
    }
}
