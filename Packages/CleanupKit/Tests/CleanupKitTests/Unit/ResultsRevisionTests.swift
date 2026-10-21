import Foundation
import Testing

@testable import CleanupKit

/// The results revision moves exactly when what results are built from changes
/// (specs/007-persistent-session). A snapshot is valid only while the revision it was built at is
/// still the store's.
@Suite struct ResultsRevisionTests {
    func store() throws -> SwiftDataStore { try InMemoryStore.make() }

    func item(_ id: String, size: Int64? = nil, estimated: Bool = false, sharpness: Double = 0.8)
        -> LibraryItem
    {
        var i = Make.item(Make.meta(id), sharpness: sharpness)
        i.byteSize = size
        i.isSizeEstimated = estimated
        return i
    }

    /// Runs `action` and reports whether the revision moved.
    func moves(_ store: SwiftDataStore, _ action: () async throws -> Void) async throws -> Bool {
        let before = try await store.revision()
        try await action()
        return try await store.revision() > before
    }

    // MARK: Writes that change what results are built from

    @Test func aNewItemMovesTheRevision() async throws {
        let s = try store()
        #expect(try await moves(s) { try await s.upsert([item("a")]) })
    }

    @Test func anItemWhoseResultsInputChangedMovesTheRevision() async throws {
        let s = try store()
        try await s.upsert([item("a", sharpness: 0.8)])
        #expect(try await moves(s) { try await s.upsert([item("a", sharpness: 0.2)]) })
        var m = Make.meta("a")
        m.isFavorite = true
        #expect(try await moves(s) { try await s.upsert([Make.item(m, sharpness: 0.2)]) })
        var albums = m
        albums.albumNames = ["Trip"]
        #expect(try await moves(s) { try await s.upsert([Make.item(albums, sharpness: 0.2)]) })
    }

    @Test func deletingItemsMovesTheRevisionOnlyIfTheyExisted() async throws {
        let s = try store()
        try await s.upsert([item("a")])
        #expect(try await moves(s) { try await s.deleteItems(["a"]) })
        #expect(!(try await moves(s) { try await s.deleteItems(["a", "never-stored"]) }))
    }

    @Test func keepMarksMoveTheRevisionWhenTheyChange() async throws {
        let s = try store()
        #expect(try await moves(s) { try await s.setKeep("a", true) })
        #expect(!(try await moves(s) { try await s.setKeep("a", true) }))
        #expect(try await moves(s) { try await s.setKeep("a", false) })
        #expect(!(try await moves(s) { try await s.setKeep("a", false) }))
        try await s.setKeep("b", true)
        #expect(try await moves(s) { try await s.clearKeepMarks() })
        #expect(!(try await moves(s) { try await s.clearKeepMarks() }))
    }

    @Test func deleteAllDataMovesTheRevisionAndNeverResetsIt() async throws {
        let s = try store()
        try await s.upsert([item("a")])
        let before = try await s.revision()
        try await s.deleteAllData()
        #expect(try await s.revision() > before)
    }

    // MARK: Writes that do not

    @Test func rewritingIdenticalValuesDoesNotMoveTheRevision() async throws {
        let s = try store()
        try await s.upsert([item("a")])
        #expect(!(try await moves(s) { try await s.upsert([item("a")]) }))
    }

    @Test func bookkeepingAloneDoesNotMoveTheRevision() async throws {
        let s = try store()
        try await s.upsert([item("a")])
        var again = item("a")
        again.scanAttempts = 3
        again.analyzedAt = Date(timeIntervalSince1970: 5)
        #expect(!(try await moves(s) { try await s.upsert([again]) }))
        let session = ScanSession(kind: .full, state: .running, totalItems: 1)
        #expect(!(try await moves(s) { try await s.saveSession(session) }))
        let chunk = ScanChunk(jobID: session.id, sequence: 0, assetIDs: ["a"])
        #expect(!(try await moves(s) { try await s.createJob(session, chunks: [chunk]) }))
        #expect(!(try await moves(s) { try await s.saveChunks([chunk], session: session) }))
    }

    @Test func aCheckpointMovesTheRevisionOnlyThroughItsItems() async throws {
        let s = try store()
        let session = ScanSession(kind: .full, state: .running, totalItems: 2)
        let chunk = ScanChunk(jobID: session.id, sequence: 0, assetIDs: ["a", "b"])
        try await s.createJob(session, chunks: [chunk])
        #expect(
            try await moves(s) {
                try await s.checkpoint(items: [item("a")], chunk: chunk, session: session)
            })
        #expect(
            !(try await moves(s) {
                try await s.checkpoint(items: [item("a")], chunk: chunk, session: session)
            }))
    }

    @Test func savingStateNeverMovesTheRevision() async throws {
        let s = try store()
        try await s.upsert([item("a")])
        #expect(
            !(try await moves(s) {
                try await s.saveState(.decisions, version: 1, payload: Data([1, 2]))
            }))
        #expect(!(try await moves(s) { try await s.deleteState([.decisions]) }))
    }

    // MARK: Measured sizes

    @Test func aMeasuredSizeMovesTheRevisionOnceForTheWholeBatch() async throws {
        let s = try store()
        try await s.upsert([item("a"), item("b"), item("c")])
        let before = try await s.revision()
        try await s.setSizes([
            "a": MeasuredSize(bytes: 10, isEstimated: false),
            "b": MeasuredSize(bytes: 20, isEstimated: false),
            "c": MeasuredSize(bytes: 30, isEstimated: true),
        ])
        // Three sizes in one batch move the revision by exactly one.
        #expect(try await s.revision() == before + 1)
        // The same measured size again changes nothing.
        let after = try await s.revision()
        try await s.setSizes(["a": MeasuredSize(bytes: 10, isEstimated: false)])
        #expect(try await s.revision() == after)
    }

    @Test func anEstimateAloneDoesNotMoveTheRevisionButAMeasurementAfterItDoes() async throws {
        let s = try store()
        try await s.upsert([item("a")])
        #expect(
            !(try await moves(s) {
                try await s.setSizes(["a": MeasuredSize(bytes: 5, isEstimated: true)])
            }))
        #expect(
            try await moves(s) {
                try await s.setSizes(["a": MeasuredSize(bytes: 9, isEstimated: false)])
            })
    }

    @Test func settingSizesNeverWipesTheStoredFingerprints() async throws {
        let s = try store()
        let withBlobs = Make.item(
            Make.meta("a"), dHash: 42, thumbprint: Data(repeating: 7, count: 64),
            print: Data([1, 2, 3]),
            sharpness: 0.5)
        try await s.upsert([withBlobs])
        try await s.setSizes(["a": MeasuredSize(bytes: 123, isEstimated: false)])
        let back = try #require(try await s.items().first)
        #expect(back.analysis?.dHash == 42)
        #expect(back.analysis?.thumbprint == Data(repeating: 7, count: 64))
        #expect(back.analysis?.featurePrint == Data([1, 2, 3]))
        #expect(back.byteSize == 123)
        #expect(
            try await s.sizes(for: ["a", "zz"]) == [
                "a": MeasuredSize(bytes: 123, isEstimated: false)
            ])
    }

    // MARK: Inputs and launch state

    @Test func resultInputsCarryTheRevisionTheyWereReadAt() async throws {
        let s = try store()
        try await s.upsert([item("a")])
        try await s.setKeep("k", true)
        let inputs = try await s.resultInputs()
        #expect(inputs.items.map(\.assetID) == ["a"])
        #expect(inputs.keepMarks == ["k"])
        let current = try await s.revision()
        #expect(inputs.revision == current)
    }

    @Test func theLaunchStateReadsNoItemsButCountsThem() async throws {
        let s = try store()
        try await s.upsert([item("a"), item("b")])
        try await s.saveState(.decisions, version: 1, payload: Data([9]))
        let state = try await s.loadLaunchState()
        #expect(state.itemCount == 2)
        let current = try await s.revision()
        #expect(state.revision == current)
        #expect(state.states[.decisions]?.payload == Data([9]))
        #expect(state.states[.results] == nil)
    }

    // MARK: The snapshot compare-and-set

    @Test func aSnapshotIsWrittenOnlyIfTheStoreHasNotMovedOn() async throws {
        let s = try store()
        try await s.upsert([item("a")])
        let r = try await s.revision()
        #expect(try await s.saveSnapshot(Data([1]), version: 1, ifRevision: r))
        let saved = try #require(try await s.loadLaunchState().states[.results])
        #expect(saved.basedOnRevision == r)
        // The store moves on (a new photo): a build made at the old revision must not be saved.
        try await s.upsert([item("b")])
        #expect(!(try await s.saveSnapshot(Data([2]), version: 1, ifRevision: r)))
        #expect(try await s.loadLaunchState().states[.results]?.payload == Data([1]))
    }

    @Test func aStateRowWithAFailedChecksumIsDroppedNotTrusted() async throws {
        let s = try store()
        try await s.saveState(.decisions, version: 1, payload: Data([1, 2, 3]))
        try await s.saveState(.position, version: 1, payload: Data([4]))
        try await s.corruptStateForTesting(.decisions)
        let state = try await s.loadLaunchState()
        #expect(state.states[.decisions] == nil)
        #expect(state.states[.position]?.payload == Data([4]))
        // It was deleted, so it does not come back.
        #expect(try await s.stateInfo()[.decisions] == nil)
    }

    @Test func stateInfoReportsSizeAndAge() async throws {
        let s = try store()
        try await s.saveState(.decisions, version: 1, payload: Data(repeating: 1, count: 100))
        let info = try #require(try await s.stateInfo()[.decisions])
        #expect(info.bytes == 100)
    }

    @Test func deleteAllDataRemovesSavedState() async throws {
        let s = try store()
        try await s.saveState(.decisions, version: 1, payload: Data([1]))
        try await s.deleteAllData()
        #expect(try await s.stateInfo().isEmpty)
    }

    @Test func theRevisionIsNotLostAcrossReopening() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(
            path: "iclean-rev-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try SwiftDataStore.at(folder: folder)
        try await first.upsert([item("a")])
        let r = try await first.revision()
        #expect(r > 0)
        let second = try SwiftDataStore.at(folder: folder)
        #expect(try await second.revision() == r)
    }
}
