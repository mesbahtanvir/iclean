import Foundation
import SwiftData

/// A small, checksummed, versioned blob that is NOT the source of truth: the saved results, the
/// person's review choices, and where they were (specs/007-persistent-session). One row per key.
///
/// The payload is opaque here; `StateCodec` seals and opens it. A row whose checksum does not
/// match is treated as absent and deleted, never trusted.
@Model
final class StateRecord {
    @Attribute(.unique) var key: String
    var version: Int
    var payload: Data
    var checksum: Data
    /// The store revision the payload was built for. Only meaningful for the results snapshot.
    var basedOnRevision: Int64
    var updatedAt: Date

    init(key: String, version: Int, payload: Data, checksum: Data, basedOnRevision: Int64) {
        self.key = key
        self.version = version
        self.payload = payload
        self.checksum = checksum
        self.basedOnRevision = basedOnRevision
        self.updatedAt = .now
    }
}
