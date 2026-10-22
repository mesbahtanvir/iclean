import Foundation
import SwiftData

/// Stored piece of a scan job: identifiers, state and counters only (003 FR-013).
@Model
final class ScanChunkRecord {
    @Attribute(.unique) var key: String
    var jobID: UUID
    var sequence: Int
    var assetIDs: [String]
    var stateRaw: String
    /// UInt64 done mask stored by bit pattern.
    var doneMaskBits: Int64
    var attempts: Int
    var crashes: Int
    var isolate: Bool
    var suspectIndex: Int?
    // Optional and additive, so stores written by the first 003 build open unchanged.
    var inFlightIndex: Int?
    var notBefore: Date?
    var owner: UUID?
    var lastError: String?
    // Spec 010: optional and additive. Nil, as in a chunk stored before, skips nothing.
    var skipPrintBits: Int64?
    var skipFaceBits: Int64?

    init(_ chunk: ScanChunk) {
        key = chunk.id
        jobID = chunk.jobID
        sequence = chunk.sequence
        assetIDs = chunk.assetIDs
        stateRaw = chunk.state.rawValue
        doneMaskBits = 0
        attempts = 0
        crashes = 0
        isolate = false
        update(from: chunk)
    }

    func update(from c: ScanChunk) {
        stateRaw = c.state.rawValue
        assetIDs = c.assetIDs
        doneMaskBits = Int64(bitPattern: c.doneMask)
        attempts = c.attempts
        crashes = c.crashes
        isolate = c.isolate
        suspectIndex = c.suspectIndex
        inFlightIndex = c.inFlightIndex
        notBefore = c.notBefore
        owner = c.owner
        lastError = c.lastError
        skipPrintBits = c.skipPrintMask == 0 ? nil : Int64(bitPattern: c.skipPrintMask)
        skipFaceBits = c.skipFaceMask == 0 ? nil : Int64(bitPattern: c.skipFaceMask)
    }

    var chunk: ScanChunk {
        ScanChunk(
            jobID: jobID, sequence: sequence, assetIDs: assetIDs,
            state: ScanChunkState(rawValue: stateRaw) ?? .pending,
            doneMask: UInt64(bitPattern: doneMaskBits), attempts: attempts, crashes: crashes,
            isolate: isolate, suspectIndex: suspectIndex, inFlightIndex: inFlightIndex,
            notBefore: notBefore, owner: owner,
            lastError: lastError, skipPrintMask: skipPrintBits.map(UInt64.init(bitPattern:)) ?? 0,
            skipFaceMask: skipFaceBits.map(UInt64.init(bitPattern:)) ?? 0)
    }
}
