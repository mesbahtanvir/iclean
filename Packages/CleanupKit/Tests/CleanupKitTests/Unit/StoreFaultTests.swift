import Foundation
import Testing

@testable import CleanupKit

/// Damaged or foreign store files must never crash the app, never be deleted behind the
/// person's back, and never be written into by a build that does not know them
/// (specs/007-persistent-session).
@Suite struct StoreFaultTests {
    func freshFolder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "iclean-fault-\(UUID().uuidString)")
    }

    func deferred(_ folder: URL) -> DeferredStore {
        DeferredStore(
            opening: { try SwiftDataStore.at(folder: folder) },
            fallback: { try SwiftDataStore.inMemory() },
            erase: { try SwiftDataStore.eraseStoreFiles(in: folder) })
    }

    /// A file that starts like an SQLite database and then is not one.
    func writeDamagedStore(_ folder: URL, zeroed: Bool) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var data = Data("SQLite format 3\0".utf8)
        data.append(Data(repeating: zeroed ? 0 : 0xA5, count: 8192))
        if zeroed { data.replaceSubrange(0..<16, with: Data(count: 16)) }
        try data.write(to: folder.appending(path: "iclean.store"))
    }

    @Test func aStoreFromANewerBuildIsNotOpenedOrChanged() async throws {
        let folder = freshFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try await Task.detached { try SwiftDataStore.at(folder: folder) }.value
        try await store.upsert([Make.item(Make.meta("a"))])
        try await store.setFormatVersionForTesting(StoreMetaRecord.currentFormat + 1)

        let reopened = deferred(folder)
        let status = await reopened.openStatus()
        guard case .volatile(let why) = status else {
            Issue.record("a newer store must not be opened for writing")
            return
        }
        #expect(why.contains("newer"))
        // It runs in memory for this launch and writes nothing into the newer store: read through
        // the connection that wrote it, the store still holds exactly what it held.
        try await reopened.upsert([Make.item(Make.meta("x"))])
        #expect(try await reopened.items().map(\.assetID) == ["x"])
        #expect(try await store.items().map(\.assetID) == ["a"])
    }

    @Test func aStoreWithAZeroedHeaderIsReportedNotCrashedOnNorDeleted() async throws {
        let folder = freshFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try writeDamagedStore(folder, zeroed: true)
        let file = folder.appending(path: "iclean.store")
        let before = try Data(contentsOf: file)

        let reopened = deferred(folder)
        // Reported, and the launch runs in memory; the damaged file stays for the person to erase.
        guard case .volatile = await reopened.openStatus() else {
            Issue.record("a damaged store must be reported")
            return
        }
        #expect(try Data(contentsOf: file) == before)
        try await reopened.upsert([Make.item(Make.meta("x"))])
        #expect(try await reopened.items().count == 1)
    }

    @Test func aDamagedStoreBodyDoesNotCrashAndIsNotDeleted() async throws {
        let folder = freshFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try writeDamagedStore(folder, zeroed: false)
        let file = folder.appending(path: "iclean.store")
        let before = try Data(contentsOf: file)

        let reopened = deferred(folder)
        guard case .volatile = await reopened.openStatus() else {
            Issue.record("a damaged store must be reported")
            return
        }
        #expect(try Data(contentsOf: file) == before)
        try await reopened.upsert([Make.item(Make.meta("x"))])
        #expect(try await reopened.items().count == 1)
    }

    @Test func aCopyWithoutItsLogNeverHoldsASnapshotOfARevisionItDoesNotHave() async throws {
        let source = freshFolder()
        let copy = freshFolder()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: copy)
        }
        let store = try await Task.detached { try SwiftDataStore.at(folder: source) }.value
        try await store.upsert(["a", "b", "c"].map { Make.item(Make.meta($0)) })
        let revision = try await store.revision()
        #expect(try await store.saveSnapshot(Data([1, 2, 3]), version: 1, ifRevision: revision))
        // The data file alone, without the write-ahead log: what is left if the log is lost. Items,
        // revision and snapshot live in one database, so what remains is whole or older, never mixed.
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: source.appending(path: "iclean.store"), to: copy.appending(path: "iclean.store"))

        let reopened = deferred(copy)
        #expect(await reopened.openStatus() == .ready)
        let launch = try await reopened.loadLaunchState()
        #expect(launch.revision <= revision)
        if let snapshot = launch.states[.results] {
            #expect(
                snapshot.basedOnRevision == launch.revision, "a snapshot always matches its store")
        }
        #expect(launch.itemCount <= 3)
    }
}
