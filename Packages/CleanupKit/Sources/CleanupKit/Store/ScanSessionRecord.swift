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
    // 003: optional so stores written by earlier versions open unchanged.
    var baseProcessed: Int?
    var failedItems: Int?
    var crashCount: Int?
    var interruptedCount: Int?

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
        baseProcessed = s.baseProcessed
        failedItems = s.failedItems
        crashCount = s.crashCount
        interruptedCount = s.interruptedCount
    }

    var session: ScanSession {
        ScanSession(
            id: id, kind: ScanKind(rawValue: kindRaw) ?? .full,
            state: ScanState(rawValue: stateRaw) ?? .stopped, startedAt: startedAt,
            finishedAt: finishedAt, totalItems: totalItems, processedItems: processedItems,
            notScannedCount: notScannedCount, lastProcessedAssetID: lastProcessedAssetID,
            baseProcessed: baseProcessed ?? 0, failedItems: failedItems ?? 0,
            crashCount: crashCount ?? 0, interruptedCount: interruptedCount ?? 0)
    }
}
