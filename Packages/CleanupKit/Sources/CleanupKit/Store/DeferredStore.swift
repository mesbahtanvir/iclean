import Foundation

/// A store that opens itself off the main thread, on first use.
///
/// An `@ModelActor` created on the main thread runs every one of its methods on the main thread, so
/// the store must be created somewhere else. This also keeps a slow first open (a migration) off
/// the launch path, and turns a failure to open into an explicit state instead of silently
/// handing the app an empty in-memory store.
public actor DeferredStore: Store {
    private let opener: @Sendable () throws -> any Store
    private let fallback: @Sendable () throws -> any Store
    private let eraser: @Sendable () throws -> Void
    private var opening: Task<(any Store, StoreOpenStatus), Never>?

    /// - Parameters:
    ///   - opening: opens the real store. Runs on a background thread.
    ///   - fallback: an empty store that lives in memory, used if opening fails.
    ///   - erase: deletes the store's files, for `eraseStoreFiles`.
    public init(
        opening: @escaping @Sendable () throws -> any Store,
        fallback: @escaping @Sendable () throws -> any Store,
        erase: @escaping @Sendable () throws -> Void = {}
    ) {
        self.opener = opening
        self.fallback = fallback
        self.eraser = erase
    }

    private func resolved() async -> (any Store, StoreOpenStatus) {
        if let opening { return await opening.value }
        let opener = self.opener
        let fallback = self.fallback
        let task = Task.detached(priority: .userInitiated) { () -> (any Store, StoreOpenStatus) in
            do {
                return (try opener(), .ready)
            } catch {
                Log.scan.error(
                    "Could not open the store: \(error.localizedDescription, privacy: .public)")
                // The failure is kept in the status; the damaged files are left exactly as they are.
                let memory = try! fallback()
                return (memory, .volatile(error.localizedDescription))
            }
        }
        opening = task
        return await task.value
    }

    private func store() async -> any Store { await resolved().0 }

    public func openStatus() async -> StoreOpenStatus { await resolved().1 }

    public func eraseStoreFiles() async throws {
        // Let any open that is in flight finish first, so nothing holds the files.
        _ = await opening?.value
        opening = nil
        try eraser()
        _ = await resolved()
    }

    // MARK: Store

    public func items() async throws -> [LibraryItem] { try await store().items() }
    public func itemSummaries() async throws -> [StoredItemSummary] {
        try await store().itemSummaries()
    }
    public func itemsWithoutFeaturePrints() async throws -> [LibraryItem] {
        try await store().itemsWithoutFeaturePrints()
    }
    public func featurePrints(for assetIDs: [String]) async throws -> [String: Data] {
        try await store().featurePrints(for: assetIDs)
    }
    public func refreshMetadata(_ metadata: [AssetMetadata]) async throws {
        try await store().refreshMetadata(metadata)
    }
    public func upsert(_ items: [LibraryItem]) async throws { try await store().upsert(items) }
    public func deleteItems(_ assetIDs: Set<String>) async throws {
        try await store().deleteItems(assetIDs)
    }
    public func keepMarks() async throws -> Set<String> { try await store().keepMarks() }
    public func setKeep(_ assetID: String, _ keep: Bool) async throws {
        try await store().setKeep(assetID, keep)
    }
    public func clearKeepMarks() async throws { try await store().clearKeepMarks() }
    public func saveSession(_ session: ScanSession) async throws {
        try await store().saveSession(session)
    }
    public func currentSession() async throws -> ScanSession? { try await store().currentSession() }
    public func sessions() async throws -> [ScanSession] { try await store().sessions() }
    public func scanAttempts(for assetIDs: [String]) async throws -> [String: Int] {
        try await store().scanAttempts(for: assetIDs)
    }
    public func createJob(_ session: ScanSession, chunks: [ScanChunk]) async throws {
        try await store().createJob(session, chunks: chunks)
    }
    public func chunks(job: UUID) async throws -> [ScanChunk] { try await store().chunks(job: job) }
    public func saveChunks(_ chunks: [ScanChunk], session: ScanSession?) async throws {
        try await store().saveChunks(chunks, session: session)
    }
    public func checkpoint(items: [LibraryItem], chunks: [ScanChunk], session: ScanSession)
        async throws
    {
        try await store().checkpoint(items: items, chunks: chunks, session: session)
    }
    public func deleteChunks(job: UUID) async throws { try await store().deleteChunks(job: job) }
    public func resultInputs() async throws -> ResultInputs { try await store().resultInputs() }
    public func revision() async throws -> Int64 { try await store().revision() }
    public func loadLaunchState() async throws -> LaunchState {
        try await store().loadLaunchState()
    }
    public func saveState(_ key: StateKey, version: Int, payload: Data) async throws {
        try await store().saveState(key, version: version, payload: payload)
    }
    public func saveSnapshot(_ payload: Data, version: Int, ifRevision: Int64) async throws -> Bool
    {
        try await store().saveSnapshot(payload, version: version, ifRevision: ifRevision)
    }
    public func deleteState(_ keys: Set<StateKey>) async throws {
        try await store().deleteState(keys)
    }
    public func stateInfo() async throws -> [StateKey: StateInfo] { try await store().stateInfo() }
    public func setSizes(_ sizes: [String: MeasuredSize]) async throws {
        try await store().setSizes(sizes)
    }
    public func sizes(for assetIDs: [String]) async throws -> [String: MeasuredSize] {
        try await store().sizes(for: assetIDs)
    }
    public func deleteAllData() async throws { try await store().deleteAllData() }
}
