import Foundation
import SwiftData

/// One row of facts about the store itself (specs/007-persistent-session).
///
/// `resultsRevision` only ever goes up, and is never reset, not even by Delete All Data, so a
/// number is never reused and a saved snapshot of an older state can never look current. It is
/// bumped inside the same transaction as any write that changes what results are built from.
@Model
final class StoreMetaRecord {
    @Attribute(.unique) var key: String
    var resultsRevision: Int64
    var formatVersion: Int
    var createdByBuild: String?

    static let singleKey = "meta"
    /// The layout this build writes. A store written by a newer build is opened by nobody older.
    static let currentFormat = 1

    init() {
        key = Self.singleKey
        resultsRevision = 0
        formatVersion = Self.currentFormat
        createdByBuild = nil
    }
}
