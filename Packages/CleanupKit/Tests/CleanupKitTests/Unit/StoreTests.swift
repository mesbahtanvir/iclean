import Foundation
import Testing

@testable import CleanupKit

@Suite struct StoreTests {
    @Test func upsertAndReadBack() async throws {
        let store = try InMemoryStore.make()
        let item = Make.item(Make.meta("a", albums: ["Trip"]), dHash: .max, sharpness: 12)
        try await store.upsert([item])
        let items = try await store.items()
        #expect(items.count == 1)
        #expect(items[0].analysis?.dHash == .max)
        #expect(items[0].metadata.albumNames == ["Trip"])
    }

    @Test func theDateAddedAndTheLocationRoundTripAndAreUpdated() async throws {
        let store = try InMemoryStore.make()
        var m = Make.meta("a")
        m.addedDate = Date(timeIntervalSince1970: 1_700_000_000)
        m.hasLocation = true
        try await store.upsert([Make.item(m)])
        var back = try #require(try await store.items().first)
        #expect(back.metadata.addedDate == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(back.metadata.hasLocation == true)
        // A refreshed value replaces the stored one, and "no location" is kept as no, not unknown.
        m.addedDate = Date(timeIntervalSince1970: 1_800_000_000)
        m.hasLocation = false
        try await store.upsert([Make.item(m)])
        back = try #require(try await store.items().first)
        #expect(back.metadata.addedDate == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(back.metadata.hasLocation == false)
        // An item never given either stays unknown.
        try await store.upsert([Make.item(Make.meta("b"))])
        let b = try #require(try await store.items().first { $0.assetID == "b" })
        #expect(b.metadata.addedDate == nil && b.metadata.hasLocation == nil)
    }

    @Test func assetIDIsUnique() async throws {
        let store = try InMemoryStore.make()
        try await store.upsert([Make.item(Make.meta("a"), sharpness: 1)])
        try await store.upsert([Make.item(Make.meta("a"), sharpness: 2)])
        let items = try await store.items()
        #expect(items.count == 1)
        #expect(items[0].analysis?.sharpness == 2)
    }

    @Test func notScannedItemsHaveNoFingerprints() async throws {
        let store = try InMemoryStore.make()
        let item = Make.item(Make.meta("a"), source: .notScanned, dHash: 7)
        #expect(item.analysis == nil)
        try await store.upsert([item])
        #expect(try await store.items()[0].analysis == nil)
    }

    @Test func onlyOneActiveSession() async throws {
        let store = try InMemoryStore.make()
        try await store.saveSession(ScanSession(kind: .full, state: .running))
        await #expect(throws: StoreError.anotherSessionActive) {
            try await store.saveSession(ScanSession(kind: .full, state: .paused))
        }
    }

    @Test func keepMarks() async throws {
        let store = try InMemoryStore.make()
        try await store.setKeep("a", true)
        try await store.setKeep("b", true)
        try await store.setKeep("b", false)
        #expect(try await store.keepMarks() == ["a"])
        try await store.clearKeepMarks()
        #expect(try await store.keepMarks().isEmpty)
    }

    @Test func deleteAllDataEmptiesEverything() async throws {
        let store = try InMemoryStore.make()
        try await store.upsert([Make.item(Make.meta("a"))])
        try await store.setKeep("a", true)
        try await store.saveSession(ScanSession(kind: .full, state: .completed))
        try await store.deleteAllData()
        #expect(try await store.items().isEmpty)
        #expect(try await store.keepMarks().isEmpty)
        #expect(try await store.currentSession() == nil)
    }

    @Test func storeFolderIsExcludedFromBackup() throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "iclean-test-\(UUID().uuidString)")
        _ = try SwiftDataStore.at(folder: folder)
        let values = try folder.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
        try? FileManager.default.removeItem(at: folder)
    }
}
