import Foundation
import SwiftData

/// The user's decision that an item must never be flagged again (FR-011).
@Model
final class KeepMarkRecord {
    @Attribute(.unique) var assetID: String
    var createdAt: Date

    init(assetID: String, createdAt: Date = .now) {
        self.assetID = assetID
        self.createdAt = createdAt
    }
}
