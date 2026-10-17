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
    /// Deletes everything iclean has stored (FR-018).
    func deleteAllData() async throws
}

public enum StoreError: Error, Equatable {
    /// Only one session can be running or paused at a time.
    case anotherSessionActive
}
