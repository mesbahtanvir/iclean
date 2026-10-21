import Foundation
import Testing

@testable import CleanupKit

@Suite struct DeferredStoreTests {
    struct Boom: Error, LocalizedError { var errorDescription: String? { "boom" } }

    @Test func theStoreIsOpenedOffTheMainThread() async throws {
        let seen = Seen()
        let deferred = DeferredStore(
            opening: {
                seen.mainThread = Thread.isMainThread; return try SwiftDataStore.inMemory()
            },
            fallback: { try SwiftDataStore.inMemory() })
        try await deferred.upsert([Make.item(Make.meta("a"))])
        #expect(seen.mainThread == false)
        #expect(await deferred.openStatus() == .ready)
        #expect(try await deferred.items().count == 1)
    }

    @Test func aSwiftDataStoreCreatedOffTheMainThreadRunsItsMethodsOffTheMainThread() async throws {
        // Created on the main thread, an @ModelActor runs every method there (probed on macOS 26
        // and the iOS 26 simulator). Made inside the deferred store it must not.
        let store = try await Task.detached { try SwiftDataStore.inMemory() }.value
        #expect(await store.isOnMainThreadForTesting() == false)
    }

    @Test func aFailedOpenIsReportedAndFallsBackToMemoryWithoutTouchingFiles() async throws {
        let deferred = DeferredStore(
            opening: { throw Boom() }, fallback: { try SwiftDataStore.inMemory() })
        #expect(await deferred.openStatus() == .volatile("boom"))
        // It still works for this run, in memory.
        try await deferred.upsert([Make.item(Make.meta("a"))])
        #expect(try await deferred.items().count == 1)
    }

    @Test func theStoreIsOpenedOnlyOnceEvenWhenCalledAtTheSameTime() async throws {
        let counter = Seen()
        let deferred = DeferredStore(
            opening: {
                counter.opens += 1; return try SwiftDataStore.inMemory()
            },
            fallback: { try SwiftDataStore.inMemory() })
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask { try? await deferred.upsert([Make.item(Make.meta("p\(i)"))]) }
            }
        }
        #expect(counter.opens == 1)
        #expect(try await deferred.items().count == 20)
    }

    @Test func erasingTheFilesOpensAFreshStoreInTheSamePlace() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(
            path: "iclean-erase-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let deferred = DeferredStore(
            opening: { try SwiftDataStore.at(folder: folder) },
            fallback: { try SwiftDataStore.inMemory() },
            erase: { try SwiftDataStore.eraseStoreFiles(in: folder) })
        try await deferred.upsert([Make.item(Make.meta("a"))])
        try await deferred.eraseStoreFiles()
        #expect(try await deferred.items().isEmpty)
        #expect(await deferred.openStatus() == .ready)
        try await deferred.upsert([Make.item(Make.meta("b"))])
        #expect(try await deferred.items().map(\.assetID) == ["b"])
    }

    @Test func theThreeStoreFilesAreErasedTogether() throws {
        let folder = FileManager.default.temporaryDirectory.appending(
            path: "iclean-files-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for url in SwiftDataStore.storeFileURLs(in: folder) { try Data([1]).write(to: url) }
        try SwiftDataStore.eraseStoreFiles(in: folder)
        for url in SwiftDataStore.storeFileURLs(in: folder) {
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
        // Nothing to erase is not an error.
        try SwiftDataStore.eraseStoreFiles(in: folder)
    }

    final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var _main: Bool?
        private var _opens = 0
        var mainThread: Bool? {
            get { lock.withLock { _main } }
            set { lock.withLock { _main = newValue } }
        }
        var opens: Int {
            get { lock.withLock { _opens } }
            set { lock.withLock { _opens = newValue } }
        }
    }
}
