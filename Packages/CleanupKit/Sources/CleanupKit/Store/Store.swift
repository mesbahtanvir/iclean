import Foundation

/// Local storage for scan results, keep marks and scan progress.
/// Everything stays on the phone (Constitution Principle I).
public protocol Store: Sendable {
    func items() async throws -> [LibraryItem]
    func upsert(_ items: [LibraryItem]) async throws
    func deleteItems(_ assetIDs: Set<String>) async throws
    func keepMarks() async throws -> Set<String>
    func setKeep(_ assetID: String, _ keep: Bool) async throws
    func clearKeepMarks() async throws
    func saveSession(_ session: ScanSession) async throws
    /// The most recent session, if any.
    func currentSession() async throws -> ScanSession?
    /// Recent sessions, newest first (003 FR-012).
    func sessions() async throws -> [ScanSession]
    /// How many scans have ended with each of these items not analyzed (003 FR-008).
    func scanAttempts(for assetIDs: [String]) async throws -> [String: Int]

    // MARK: Scan jobs (003)

    /// Saves the session and replaces its chunks, in one transaction.
    func createJob(_ session: ScanSession, chunks: [ScanChunk]) async throws
    /// The job's chunks, ordered by sequence.
    func chunks(job: UUID) async throws -> [ScanChunk]
    /// Writes chunks (and the session when given) in one transaction.
    func saveChunks(_ chunks: [ScanChunk], session: ScanSession?) async throws
    /// Results of a chunk, its state, and the session counters, in one transaction, so a
    /// failure leaves the store with all of them or none (003 FR-002).
    func checkpoint(items: [LibraryItem], chunk: ScanChunk, session: ScanSession) async throws
    func deleteChunks(job: UUID) async throws
    /// Deletes everything iclean has stored (FR-018).
    func deleteAllData() async throws
}

public enum StoreError: Error, Equatable {
    /// Only one session can be running or paused at a time.
    case anotherSessionActive
}
