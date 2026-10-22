import Foundation
import Testing

@testable import CleanupKit

/// 003 plan, risk 1: the store gained an entity and optional columns. They are additive, so
/// SwiftData migrates them without a migration plan. This opens a store written by the
/// previous schema (Fixtures/previous-store, see its README) with the current one and
/// proves nothing is lost, and that an unfinished old-style scan carries on from its count.
@Suite struct StoreMigrationTests {
    let image = TestImages.scene(seed: 3, width: 64, height: 48)
    let modified = Date(timeIntervalSince1970: 0)
    let sessionID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    /// A fresh copy of the fixture, so a test can open and change it.
    func previousStore() throws -> URL {
        let source = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
            .appending(path: "previous-store")
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "iclean-migration-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: source, to: folder)
        return folder
    }

    @Test func aStoreFromBeforeTheDurableScanOpensWithItsDataIntact() async throws {
        let folder = try previousStore()
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = try SwiftDataStore.at(folder: folder)
        let items = try await store.items()
        #expect(Set(items.map(\.assetID)) == ["old-1", "old-2"])
        let analyzed = try #require(items.first { $0.assetID == "old-1" })
        #expect(analyzed.analysis?.dHash == 5)
        #expect(analyzed.analysis?.featurePrint == Data([4]))
        #expect(analyzed.metadata.albumNames == ["Trip"])
        #expect(analyzed.scanFailure == nil)
        #expect(analyzed.scanAttempts == 0)
        // Spec 010: a store from before records no skipped Vision work, and nothing is repaired.
        #expect(analyzed.analysis?.skippedVision == [])
        #expect(try await store.itemSummaries().allSatisfy { $0.skippedVision == [] })
        // Columns added later open as "not known yet", not as "none" (date-aware keepers).
        #expect(analyzed.metadata.addedDate == nil)
        #expect(analyzed.metadata.hasLocation == nil)
        let notScanned = try #require(items.first { $0.assetID == "old-2" })
        #expect(notScanned.analysisSource == .notScanned)
        #expect(notScanned.scanAttempts == 0)

        #expect(try await store.keepMarks() == ["old-1"])
        let session = try #require(try await store.currentSession())
        #expect(session.id == sessionID)
        #expect(session.state == .running)
        #expect(session.totalItems == 4)
        #expect(session.processedItems == 2)
        #expect(session.crashCount == 0 && session.failedItems == 0 && session.baseProcessed == 0)

        // The new entity and columns are usable on the migrated file.
        try await store.upsert([Make.item(Make.meta("new-1"))])
        var finished = session
        finished.state = .completed
        try await store.saveSession(finished)
        let job = ScanSession(kind: .full, state: .running, totalItems: 1)
        try await store.createJob(
            job, chunks: [ScanChunk(jobID: job.id, sequence: 0, assetIDs: ["new-1"])])
        #expect(try await store.chunks(job: job.id).count == 1)
    }

    @Test func anUnfinishedScanFromBeforeTheDurableScanContinuesFromItsCount() async throws {
        let folder = try previousStore()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try SwiftDataStore.at(folder: folder)

        // The library holds the two stored items and two that were never analyzed.
        let lib = FakePhotoLibrary()
        for id in ["old-1", "old-2", "n3", "n4"] {
            lib.add(Make.meta(id, date: modified), preview: .local(image))
        }
        // old-2 was not analyzed last time: a full scan tries it again (003 FR-008).
        let scanner = ScanPipeline(
            library: lib, store: store, analyzer: StubAnalyzer(),
            policy: ScanRetryPolicy(backoff: [.milliseconds(5)], itemTimeout: .seconds(5)))
        var first: ScanProgress?
        var last: ScanProgress?
        for await p in await scanner.startFullScan() {
            if first == nil { first = p }
            last = p
        }
        // Counted from the old session's 2 processed items, not from zero.
        #expect((first?.processed ?? 0) >= 2)
        #expect(last?.state == .completed)
        #expect(last?.processed == last?.total)
        // The item that was analyzed before is not analyzed again.
        #expect(!lib.previewRequests.contains("old-1"))
        #expect(Set(lib.previewRequests) == ["old-2", "n3", "n4"])
        #expect(try await store.items().count == 4)
        let session = try await store.currentSession()
        #expect(session?.state == .completed)
        #expect(session?.baseProcessed == 2)
        #expect(try await store.chunks(job: session!.id).isEmpty)
    }
}
