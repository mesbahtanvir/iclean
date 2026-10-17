import Foundation
import SwiftData

@Model
final class ScanSessionRecord {
    @Attribute(.unique) var id: UUID
    var kindRaw: String
    var stateRaw: String
    var startedAt: Date
    var finishedAt: Date?
    var totalItems: Int
    var processedItems: Int
    var notScannedCount: Int
    var lastProcessedAssetID: String?

    init(_ session: ScanSession) {
        id = session.id
        kindRaw = session.kind.rawValue
        stateRaw = session.state.rawValue
        startedAt = session.startedAt
        totalItems = 0
        processedItems = 0
        notScannedCount = 0
        update(from: session)
    }

    func update(from s: ScanSession) {
        kindRaw = s.kind.rawValue
        stateRaw = s.state.rawValue
        startedAt = s.startedAt
        finishedAt = s.finishedAt
        totalItems = s.totalItems
        processedItems = s.processedItems
        notScannedCount = s.notScannedCount
        lastProcessedAssetID = s.lastProcessedAssetID
    }

    var session: ScanSession {
        ScanSession(
            id: id, kind: ScanKind(rawValue: kindRaw) ?? .full,
            state: ScanState(rawValue: stateRaw) ?? .stopped, startedAt: startedAt,
            finishedAt: finishedAt, totalItems: totalItems, processedItems: processedItems,
            notScannedCount: notScannedCount, lastProcessedAssetID: lastProcessedAssetID)
    }
}
