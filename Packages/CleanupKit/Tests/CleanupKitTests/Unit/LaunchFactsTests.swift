import Foundation
import Testing

@testable import CleanupKit

/// Two facts Home must not guess (spec 009 section 0): whether a full scan ever ran to the end, and
/// how many photos the store holds.
@Suite struct LaunchFactsTests {
    func day(_ n: Int) -> Date { Date(timeIntervalSince1970: 1_700_000_000 + Double(n) * 86_400) }

    @Test func noScanMeansNoFullScanCompleted() async throws {
        let store = try InMemoryStore.make()
        #expect(try await store.loadLaunchState().lastFullScanCompletedAt == nil)
    }

    @Test func aStoppedScanAndAQuickCheckAreNotACompletedFullScan() async throws {
        let store = try InMemoryStore.make()
        try await store.saveSession(
            ScanSession(
                kind: .full, state: .stopped, startedAt: day(1), finishedAt: day(1),
                totalItems: 100,
                processedItems: 5))
        try await store.saveSession(
            ScanSession(
                kind: .quickCheck, state: .completed, startedAt: day(2), finishedAt: day(2)))
        let launch = try await store.loadLaunchState()
        // The newest session of any kind is a quick check, which says nothing about a full scan.
        #expect(launch.session?.kind == .quickCheck)
        #expect(launch.lastFullScanCompletedAt == nil)
    }

    @Test func theNewestFullScanThatEndedNormallyIsTheOneRemembered() async throws {
        let store = try InMemoryStore.make()
        try await store.saveSession(
            ScanSession(
                kind: .full, state: .completed, startedAt: day(1), finishedAt: day(1),
                totalItems: 10, processedItems: 10))
        try await store.saveSession(
            ScanSession(
                kind: .full, state: .completed, startedAt: day(3), finishedAt: day(3),
                totalItems: 10, processedItems: 10))
        try await store.saveSession(
            ScanSession(
                kind: .full, state: .stopped, startedAt: day(4), finishedAt: day(4), totalItems: 10,
                processedItems: 2))
        try await store.saveSession(
            ScanSession(
                kind: .quickCheck, state: .completed, startedAt: day(5), finishedAt: day(5)))
        #expect(try await store.loadLaunchState().lastFullScanCompletedAt == day(3))
    }

    @Test func theItemCountIsTheStoresCount() async throws {
        let store = try InMemoryStore.make()
        #expect(try await store.itemCount() == 0)
        try await store.upsert((0..<7).map { Make.item(Make.meta("p\($0)")) })
        #expect(try await store.itemCount() == 7)
        #expect(try await store.loadLaunchState().itemCount == 7)
        try await store.deleteItems(["p0", "p1"])
        #expect(try await store.itemCount() == 5)
    }
}
