import XCTest
@testable import ProposalStore
@testable import CommitEngine
import ScanEngine
import PhotoGateway

final class StoreTests: XCTestCase {
    private func makeStore() throws -> (AppDatabase, GRDBPipelineStore, DeckStore) {
        let database = try AppDatabase.inMemory()
        return (database, GRDBPipelineStore(database: database), DeckStore(database: database))
    }

    private func draft(_ members: [String], keeper: String? = "keeper") -> ProposalDraft {
        ProposalDraft(
            actionType: .exactDuplicate, unit: .cluster, memberIds: members,
            keeperId: keeper, reason: ReasonParams(key: "reason.dupe.identical"),
            regretTier: 0, confidence: 1, estBytes: 512
        )
    }

    func testMigrationsRun() throws {
        _ = try makeStore()
    }

    func testUpsertKeepsStateOnRegeneration() async throws {
        let (_, pipeline, deck) = try makeStore()
        try await pipeline.upsertProposals([draft(["a", "b"])], clusterSessionId: nil)
        let card = try XCTUnwrap(deck.pendingWindow(family: .duplicates).first)

        _ = try deck.approve(id: card.id) // → staged
        // Regeneration with the same dedupeKey must NOT resurrect it as pending.
        try await pipeline.upsertProposals([draft(["a", "b"])], clusterSessionId: nil)
        XCTAssertTrue(deck.pendingWindow(family: .duplicates).isEmpty)
        XCTAssertEqual(try deck.stagingTotals().count, 1)
    }

    func testCompareAndSetLosesToInvalidation() async throws {
        let (_, pipeline, deck) = try makeStore()
        try await pipeline.upsertProposals([draft(["a", "b"])], clusterSessionId: nil)
        let card = try XCTUnwrap(deck.pendingWindow(family: .duplicates).first)

        try await pipeline.invalidateProposals(touchingAssetIds: ["a"])
        XCTAssertEqual(try deck.approve(id: card.id), .invalidatedMidSwipe)
    }

    func testRejectWritesSuppressionAndUndoLiftsIt() async throws {
        let (_, pipeline, deck) = try makeStore()
        try await pipeline.upsertProposals([draft(["a", "b"])], clusterSessionId: nil)
        let card = try XCTUnwrap(deck.pendingWindow(family: .duplicates).first)

        _ = try deck.reject(id: card.id)
        var suppressed = try await pipeline.suppressedAssetIds(actionType: .exactDuplicate)
        XCTAssertEqual(suppressed, ["a", "b"])

        // Swipe-down pops the verdict and lifts the suppressions.
        XCTAssertEqual(try deck.undoLast(), card.id)
        suppressed = try await pipeline.suppressedAssetIds(actionType: .exactDuplicate)
        XCTAssertTrue(suppressed.isEmpty)
        XCTAssertEqual(deck.pendingWindow(family: .duplicates).count, 1)
    }

    func testScanStateRetrySchedule() async throws {
        let (_, pipeline, _) = try makeStore()
        let stub = AssetStub(id: "x", mediaKind: .image, createdAt: Date(), pixelWidth: 100, pixelHeight: 100)
        try await pipeline.upsertAssets([stub])

        let now = Date()
        try await pipeline.recordStageOutcome(assetIds: ["x"], stage: .s2, status: .failed, version: 1, now: now)
        // Immediately after failure: nextRetryAt is in the future → not batched.
        let tooSoon = try await pipeline.nextBatch(stage: .s2, limit: 10, now: now, currentVersion: 1)
        XCTAssertTrue(tooSoon.isEmpty)
        // After the backoff window it becomes eligible again.
        let later = now.addingTimeInterval(120)
        let eligible = try await pipeline.nextBatch(stage: .s2, limit: 10, now: later, currentVersion: 1)
        XCTAssertEqual(eligible, ["x"])
    }

    func testVersionBumpReschedulesDoneRows() async throws {
        let (_, pipeline, _) = try makeStore()
        let stub = AssetStub(id: "x", mediaKind: .image, createdAt: Date(), pixelWidth: 100, pixelHeight: 100)
        try await pipeline.upsertAssets([stub])
        try await pipeline.recordStageOutcome(assetIds: ["x"], stage: .s2, status: .done, version: 1, now: Date())

        XCTAssertTrue(try await pipeline.nextBatch(stage: .s2, limit: 10, now: Date(), currentVersion: 1).isEmpty)
        // Version bump: done rows with stale versions become pending lazily.
        XCTAssertEqual(try await pipeline.nextBatch(stage: .s2, limit: 10, now: Date(), currentVersion: 2), ["x"])
    }
}

final class CommitEngineTests: XCTestCase {
    func testAllowanceGateHoldsOverflow() async throws {
        // Free allowance covers the whole first session; overflow stays staged.
        let database = try AppDatabase.inMemory()
        let pipeline = GRDBPipelineStore(database: database)
        let deck = DeckStore(database: database)

        var fixtures: [MockFixtureBuilder.Entry] = []
        var memberIds: [String] = []
        for index in 0..<120 {
            let id = "asset-\(String(format: "%03d", index))"
            memberIds.append(id)
            fixtures.append(.init(id: id))
        }
        let gateway = MockFixtureBuilder.gateway(entries: fixtures)
        try await pipeline.upsertAssets(fixtures.map(\.stub))

        // Stage 120 single-item proposals.
        for id in memberIds {
            let draft = ProposalDraft(
                actionType: .blankFrame, unit: .photo, memberIds: [id], keeperId: nil,
                reason: ReasonParams(key: "reason.junk.blank"),
                regretTier: 1, confidence: 1, estBytes: 100
            )
            try await pipeline.upsertProposals([draft], clusterSessionId: nil)
        }
        for card in deck.pendingWindow(family: .junk, limit: 200) {
            _ = try deck.approve(id: card.id)
        }

        let entitlements = FixedEntitlements(unlocked: false)
        let runner = CommitRunner(database: database, gateway: gateway, entitlements: entitlements)
        let outcome = try await runner.commitStaged()

        XCTAssertEqual(outcome.deletedCount, 100, "the free allowance is exactly one session")
        XCTAssertEqual(outcome.heldByPaywall, 20)
        XCTAssertEqual(try deck.stagingTotals().count, 20, "declined items stay staged — never discarded")
    }
}

/// Tiny local stand-in for FixtureKit's gateway (iCleanData tests avoid a
/// cross-package test dependency).
enum MockFixtureBuilder {
    struct Entry {
        let id: String
        var stub: AssetStub {
            AssetStub(id: id, mediaKind: .image, createdAt: Date(), pixelWidth: 100, pixelHeight: 100)
        }
    }

    final class Gateway: PhotoLibraryGateway, @unchecked Sendable {
        var assets: Set<String>
        init(ids: [String]) { assets = Set(ids) }

        func enumerateAssets(batchSize: Int) -> AsyncThrowingStream<[AssetStub], Error> {
            AsyncThrowingStream { $0.finish() }
        }
        func persistentChanges(since token: Data?) -> AsyncThrowingStream<ChangeSet, Error> {
            AsyncThrowingStream { $0.finish() }
        }
        func userAlbums() async throws -> [AlbumInfo] { [] }
        func grayThumbnail(assetId: String, maxDimension: Int, allowNetwork: Bool) async -> ThumbnailResult {
            .failed("fixture")
        }
        func probeOriginalAvailability(assetId: String) async -> Availability { .local }
        func byteHashIfLocal(assetId: String) async -> Data? { nil }
        func resourceInfo(assetId: String) async -> ResourceInfo? { nil }
        func visionSignals(assetId: String, maxDimension: Int) async -> VisionSignals? { nil }
        func confirmNoFaces(assetId: String) async -> Bool { true }
        func featureDistances(assetIds: [String], maxDimension: Int) async -> FeatureDistanceComputer? { nil }
        func cloudIdentifiers(forLocalIds: [String]) async -> [String: String] { [:] }
        func localIdentifiers(forCloudIds: [String]) async -> [String: String] { [:] }
        func performCommitChunk(_ plan: CommitChunkPlan) async throws {
            for id in plan.deleteIds { assets.remove(id) }
        }
        func existingAssetIds(among ids: [String]) async -> Set<String> {
            Set(ids.filter { assets.contains($0) })
        }
        func modificationDates(for ids: [String]) async -> [String: Date] { [:] }
    }

    static func gateway(entries: [Entry]) -> Gateway {
        Gateway(ids: entries.map(\.id))
    }
}
