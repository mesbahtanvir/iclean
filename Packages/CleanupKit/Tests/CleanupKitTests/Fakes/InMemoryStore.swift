@testable import CleanupKit

enum InMemoryStore {
    /// The real SwiftData store, kept in memory.
    static func make() throws -> SwiftDataStore { try SwiftDataStore.inMemory() }
}
