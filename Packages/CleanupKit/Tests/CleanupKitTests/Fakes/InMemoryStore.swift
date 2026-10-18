import Foundation

@testable import CleanupKit

enum InMemoryStore {
    /// Containers are created one at a time: creating many at once crashed CoreData in one
    /// of five full parallel runs.
    private static let lock = NSLock()

    /// The real SwiftData store, kept in memory.
    static func make() throws -> SwiftDataStore {
        try lock.withLock { try SwiftDataStore.inMemory() }
    }
}
