import Foundation
import SwiftData

public enum StoreOpenError: Error, LocalizedError, Equatable {
    /// The store was written by a newer version of iclean.
    case newerFormat(Int)

    public var errorDescription: String? {
        switch self {
        case .newerFormat: "The saved data was written by a newer version of iclean."
        }
    }
}

/// SwiftData-backed store in Application Support, excluded from backup, never synced
/// (research R9).
@ModelActor
public actor SwiftDataStore: Store {
    static let schema = Schema([
        LibraryItemRecord.self, KeepMarkRecord.self, ScanSessionRecord.self, ScanChunkRecord.self,
        StoreMetaRecord.self, StateRecord.self,
    ])

    /// The on-disk store: `Application Support/iclean/iclean.store`.
    public static func onDisk() throws -> SwiftDataStore {
        let folder = try storeFolder()
        let config = ModelConfiguration(
            schema: schema, url: folder.appending(path: "iclean.store"),
            cloudKitDatabase: .none)
        return SwiftDataStore(modelContainer: try open(config))
    }

    /// Opens the container and refuses a store that a newer build wrote: an older build must not
    /// write into a layout it does not know. The caller reports it and runs without saving.
    private static func open(_ config: ModelConfiguration) throws -> ModelContainer {
        let container = try ModelContainer(for: schema, configurations: config)
        let context = ModelContext(container)
        if let meta = try context.fetch(FetchDescriptor<StoreMetaRecord>()).first,
            meta.formatVersion > StoreMetaRecord.currentFormat
        {
            throw StoreOpenError.newerFormat(meta.formatVersion)
        }
        return container
    }

    /// A store at a custom folder (tests).
    public static func at(folder: URL) throws -> SwiftDataStore {
        try prepare(folder)
        let config = ModelConfiguration(
            schema: schema, url: folder.appending(path: "iclean.store"),
            cloudKitDatabase: .none)
        return SwiftDataStore(modelContainer: try open(config))
    }

    public static func inMemory() throws -> SwiftDataStore {
        let config = ModelConfiguration(
            schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return SwiftDataStore(
            modelContainer: try ModelContainer(for: schema, configurations: config))
    }

    public static func storeFolder() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil,
            create: true)
        let folder = base.appending(path: "iclean", directoryHint: .isDirectory)
        try prepare(folder)
        return folder
    }

    /// Creates the folder, excludes it from backup and sets file protection.
    static func prepare(_ folder: URL) throws {
        var attributes: [FileAttributeKey: Any] = [:]
        #if os(iOS) || os(visionOS)
            attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
        #endif
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true, attributes: attributes)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = folder
        try url.setResourceValues(values)
    }

    // MARK: Items

    public func items() throws -> [LibraryItem] {
        try modelContext.fetch(FetchDescriptor<LibraryItemRecord>()).map(\.item)
    }

    public func itemSummaries() throws -> [StoredItemSummary] {
        try page(properties: LibraryItemRecord.summaryKeyPaths) { $0.summary }
    }

    public func itemsWithoutFeaturePrints() throws -> [LibraryItem] {
        try page(properties: LibraryItemRecord.withoutFeaturePrintKeyPaths) {
            $0.itemWithoutFeaturePrint
        }
    }

    /// Reads a slice at a time, so the records of a large library are never all alive at once,
    /// and only the named properties: the fingerprints stay in the database. A single fetch of
    /// 30,000 records needed more than 600 MB (spec 008). No sort: store order is stable
    /// while this actor is the only writer, and sorting made every slice read the whole index.
    private func page<T>(
        properties: [PartialKeyPath<LibraryItemRecord>], _ convert: (LibraryItemRecord) -> T
    ) throws -> [T] {
        var out: [T] = []
        var offset = 0
        while true {
            var descriptor = FetchDescriptor<LibraryItemRecord>()
            descriptor.propertiesToFetch = properties
            descriptor.fetchLimit = 1_000
            descriptor.fetchOffset = offset
            let records = try modelContext.fetch(descriptor)
            out.append(contentsOf: records.map(convert))
            offset += records.count
            if records.count < 1_000 { break }
        }
        return out
    }

    public func featurePrints(for assetIDs: [String]) throws -> [String: Data] {
        var out: [String: Data] = [:]
        for start in stride(from: 0, to: assetIDs.count, by: 500) {
            let ids = Array(assetIDs[start..<min(start + 500, assetIDs.count)])
            let records = try modelContext.fetch(
                FetchDescriptor<LibraryItemRecord>(
                    predicate: #Predicate { ids.contains($0.assetID) }))
            for record in records {
                if let data = record.featurePrint, !data.isEmpty { out[record.assetID] = data }
            }
        }
        return out
    }

    public func refreshMetadata(_ metadata: [AssetMetadata]) throws {
        for start in stride(from: 0, to: metadata.count, by: 500) {
            let slice = Array(metadata[start..<min(start + 500, metadata.count)])
            let ids = slice.map(\.assetID)
            try transaction {
                let records = try modelContext.fetch(
                    FetchDescriptor<LibraryItemRecord>(
                        predicate: #Predicate { ids.contains($0.assetID) }))
                let byID = Dictionary(
                    records.map { ($0.assetID, $0) }, uniquingKeysWith: { a, _ in a })
                for m in slice {
                    guard let record = byID[m.assetID] else { continue }
                    // A favorite, album or date that changed alters what results show.
                    if record.metadataDiffers(from: m) { touchedResults = true }
                    record.updateMetadata(from: m)
                }
            }
        }
    }

    /// Set by a write that changed what results are built from; the transaction then moves the
    /// revision in the same commit, so a snapshot can never match data it was not built from.
    private var touchedResults = false
    #if DEBUG
        private var injectedWriteFailures = 0
        private var injectedCheckpointFailures = 0
    #endif

    /// Runs the writes and saves them together; on any error nothing is kept, so a
    /// failed write can never leave half of its changes to be committed by a later save.
    private func transaction(_ body: () throws -> Void) throws {
        #if DEBUG
            if injectedWriteFailures > 0 {
                injectedWriteFailures -= 1
                throw InjectedStoreFailure()
            }
        #endif
        touchedResults = false
        do {
            try body()
            if touchedResults { try meta().resultsRevision += 1 }
            try modelContext.save()
            touchedResults = false
        } catch {
            modelContext.rollback()
            touchedResults = false
            throw error
        }
    }

    /// The single meta row, created on first use.
    private func meta() throws -> StoreMetaRecord {
        let key = StoreMetaRecord.singleKey
        if let record = try modelContext.fetch(
            FetchDescriptor<StoreMetaRecord>(predicate: #Predicate { $0.key == key })
        ).first {
            return record
        }
        let record = StoreMetaRecord()
        modelContext.insert(record)
        return record
    }

    public func upsert(_ items: [LibraryItem]) throws {
        try transaction { try put(items) }
    }

    /// Upserts without saving (callers group writes into one transaction).
    private func put(_ items: [LibraryItem]) throws {
        guard !items.isEmpty else { return }
        let ids = items.map(\.assetID)
        let existing = try modelContext.fetch(
            FetchDescriptor<LibraryItemRecord>(predicate: #Predicate { ids.contains($0.assetID) }))
        var byID = Dictionary(existing.map { ($0.assetID, $0) }, uniquingKeysWith: { a, _ in a })
        for item in items {
            if let record = byID[item.assetID] {
                if record.resultsProjectionDiffers(from: item) { touchedResults = true }
                record.update(from: item)
            } else {
                let record = LibraryItemRecord(item)
                modelContext.insert(record)
                byID[item.assetID] = record
                touchedResults = true
            }
        }
    }

    public func scanAttempts(for assetIDs: [String]) throws -> [String: Int] {
        guard !assetIDs.isEmpty else { return [:] }
        let ids = assetIDs
        let records = try modelContext.fetch(
            FetchDescriptor<LibraryItemRecord>(predicate: #Predicate { ids.contains($0.assetID) }))
        return Dictionary(
            records.map { ($0.assetID, $0.scanAttempts ?? 0) }, uniquingKeysWith: { a, _ in a })
    }

    public func deleteItems(_ assetIDs: Set<String>) throws {
        guard !assetIDs.isEmpty else { return }
        let ids = Array(assetIDs)
        try transaction {
            let present = try modelContext.fetchCount(
                FetchDescriptor<LibraryItemRecord>(
                    predicate: #Predicate { ids.contains($0.assetID) }))
            guard present > 0 else { return }
            try modelContext.delete(
                model: LibraryItemRecord.self, where: #Predicate { ids.contains($0.assetID) })
            touchedResults = true
        }
    }

    // MARK: Keep marks

    public func keepMarks() throws -> Set<String> {
        Set(try modelContext.fetch(FetchDescriptor<KeepMarkRecord>()).map(\.assetID))
    }

    public func setKeep(_ assetID: String, _ keep: Bool) throws {
        try transaction {
            let existing = try modelContext.fetch(
                FetchDescriptor<KeepMarkRecord>(predicate: #Predicate { $0.assetID == assetID }))
            if keep, existing.isEmpty {
                modelContext.insert(KeepMarkRecord(assetID: assetID))
                touchedResults = true
            } else if !keep, !existing.isEmpty {
                existing.forEach(modelContext.delete)
                touchedResults = true
            }
        }
    }

    public func clearKeepMarks() throws {
        try transaction {
            if try modelContext.fetchCount(FetchDescriptor<KeepMarkRecord>()) > 0 {
                try modelContext.delete(model: KeepMarkRecord.self)
                touchedResults = true
            }
        }
    }

    // MARK: Sessions

    public func saveSession(_ session: ScanSession) throws {
        try transaction { try putSession(session) }
    }

    /// Upserts the session and prunes old ones, without saving. An ended session takes
    /// its chunks with it, in the same transaction, so a job never ends half-way.
    private func putSession(_ session: ScanSession) throws {
        let id = session.id
        let all = try modelContext.fetch(FetchDescriptor<ScanSessionRecord>())
        if session.isActive,
            all.contains(where: { $0.id != id && $0.session.isActive })
        {
            throw StoreError.anotherSessionActive
        }
        if let record = all.first(where: { $0.id == id }) {
            record.update(from: session)
        } else {
            modelContext.insert(ScanSessionRecord(session))
        }
        if !session.isActive { try removeChunks(job: id) }
        // Keep only the latest few sessions, and no chunks of the pruned ones.
        let old = all.filter { $0.id != id }.sorted { $0.startedAt > $1.startedAt }.dropFirst(4)
        for record in old {
            try removeChunks(job: record.id)
            modelContext.delete(record)
        }
    }

    public func currentSession() throws -> ScanSession? {
        var descriptor = FetchDescriptor<ScanSessionRecord>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.session
    }

    public func sessions() throws -> [ScanSession] {
        let descriptor = FetchDescriptor<ScanSessionRecord>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        return try modelContext.fetch(descriptor).map(\.session)
    }

    // MARK: Scan jobs (003)

    public func createJob(_ session: ScanSession, chunks: [ScanChunk]) throws {
        try transaction {
            try putSession(session)
            try removeChunks(job: session.id)
            for chunk in chunks { modelContext.insert(ScanChunkRecord(chunk)) }
        }
    }

    public func chunks(job: UUID) throws -> [ScanChunk] {
        try modelContext.fetch(
            FetchDescriptor<ScanChunkRecord>(
                predicate: #Predicate { $0.jobID == job }, sortBy: [SortDescriptor(\.sequence)])
        ).map(\.chunk)
    }

    public func saveChunks(_ chunks: [ScanChunk], session: ScanSession?) throws {
        try transaction {
            try putChunks(chunks)
            if let session { try putSession(session) }
        }
    }

    public func checkpoint(items: [LibraryItem], chunks: [ScanChunk], session: ScanSession) throws {
        #if DEBUG
            if injectedCheckpointFailures > 0 {
                injectedCheckpointFailures -= 1
                throw InjectedStoreFailure()
            }
        #endif
        try transaction {
            try put(items)
            try putChunks(chunks)
            try putSession(session)
        }
    }

    private func putChunks(_ chunks: [ScanChunk]) throws {
        guard !chunks.isEmpty else { return }
        let keys = chunks.map(\.id)
        let existing = try modelContext.fetch(
            FetchDescriptor<ScanChunkRecord>(predicate: #Predicate { keys.contains($0.key) }))
        let byKey = Dictionary(existing.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        for chunk in chunks {
            if let record = byKey[chunk.id] {
                record.update(from: chunk)
            } else {
                modelContext.insert(ScanChunkRecord(chunk))
            }
        }
    }

    public func deleteChunks(job: UUID) throws {
        try transaction { try removeChunks(job: job) }
    }

    private func removeChunks(job: UUID) throws {
        try modelContext.delete(model: ScanChunkRecord.self, where: #Predicate { $0.jobID == job })
    }

    // MARK: Delete all

    public func deleteAllData() throws {
        try transaction {
            try modelContext.delete(model: LibraryItemRecord.self)
            try modelContext.delete(model: KeepMarkRecord.self)
            try modelContext.delete(model: ScanSessionRecord.self)
            try modelContext.delete(model: ScanChunkRecord.self)
            try modelContext.delete(model: StateRecord.self)
            // The meta row stays and its revision moves on: a number is never reused.
            touchedResults = true
        }
    }

    // MARK: Saved results and review state (007)

    public func revision() throws -> Int64 {
        let key = StoreMetaRecord.singleKey
        return try modelContext.fetch(
            FetchDescriptor<StoreMetaRecord>(predicate: #Predicate { $0.key == key })
        ).first?.resultsRevision ?? 0
    }

    public func resultInputs() throws -> ResultInputs {
        // One actor turn: nothing can write between the reads and the revision.
        let revision = try revision()
        // Without the feature prints, the larger blob: `items()` needs about 20 KB an item, so
        // 30,000 items cost more than 600 MB before a detector ran (spec 008). The prints are read
        // only for the photos that have a neighbour within the similar-shots window; no detector
        // looks at the others, so the results are the same.
        var items = try itemsWithoutFeaturePrints()
        let prints = try featurePrints(
            for: SimilarShotsDetector.photosThatMayNeedFeaturePrints(items))
        for i in items.indices where items[i].analysis != nil {
            if let print = prints[items[i].assetID] { items[i].analysis?.featurePrint = print }
        }
        return ResultInputs(items: items, keepMarks: try keepMarks(), revision: revision)
    }

    public func loadLaunchState() throws -> LaunchState {
        LaunchState(
            revision: try revision(), states: try verifiedStates(), keepMarks: try keepMarks(),
            session: try currentSession(),
            itemCount: try modelContext.fetchCount(FetchDescriptor<LibraryItemRecord>()))
    }

    /// Saved state rows that pass their checksum. A damaged one is deleted: a cache or a saved
    /// choice that cannot be trusted is dropped, and the app starts from what it can rebuild.
    private func verifiedStates() throws -> [StateKey: StateEnvelope] {
        var good: [StateKey: StateEnvelope] = [:]
        var damaged: [StateRecord] = []
        for record in try modelContext.fetch(FetchDescriptor<StateRecord>()) {
            guard let key = StateKey(rawValue: record.key) else { continue }
            if StateCodec.checksum(record.payload) == record.checksum {
                good[key] = StateEnvelope(
                    key: key, version: record.version, payload: record.payload,
                    basedOnRevision: record.basedOnRevision, updatedAt: record.updatedAt)
            } else {
                damaged.append(record)
            }
        }
        if !damaged.isEmpty {
            damaged.forEach(modelContext.delete)
            try? modelContext.save()
        }
        return good
    }

    public func saveState(_ key: StateKey, version: Int, payload: Data) throws {
        try transaction { try putState(key, version: version, payload: payload, basedOn: 0) }
    }

    public func saveSnapshot(_ payload: Data, version: Int, ifRevision: Int64) throws -> Bool {
        var written = false
        try transaction {
            guard try revision() == ifRevision else { return }
            try putState(.results, version: version, payload: payload, basedOn: ifRevision)
            written = true
        }
        return written
    }

    private func putState(_ key: StateKey, version: Int, payload: Data, basedOn: Int64) throws {
        let name = key.rawValue
        let checksum = StateCodec.checksum(payload)
        if let record = try modelContext.fetch(
            FetchDescriptor<StateRecord>(predicate: #Predicate { $0.key == name })
        ).first {
            record.version = version
            record.payload = payload
            record.checksum = checksum
            record.basedOnRevision = basedOn
            record.updatedAt = .now
        } else {
            modelContext.insert(
                StateRecord(
                    key: name, version: version, payload: payload, checksum: checksum,
                    basedOnRevision: basedOn))
        }
    }

    public func deleteState(_ keys: Set<StateKey>) throws {
        let names = keys.map(\.rawValue)
        try transaction {
            try modelContext.delete(
                model: StateRecord.self, where: #Predicate { names.contains($0.key) })
        }
    }

    public func stateInfo() throws -> [StateKey: StateInfo] {
        var out: [StateKey: StateInfo] = [:]
        for record in try modelContext.fetch(FetchDescriptor<StateRecord>()) {
            guard let key = StateKey(rawValue: record.key) else { continue }
            out[key] = StateInfo(
                bytes: record.payload.count, updatedAt: record.updatedAt,
                basedOnRevision: record.basedOnRevision)
        }
        return out
    }

    public func setSizes(_ sizes: [String: MeasuredSize]) throws {
        guard !sizes.isEmpty else { return }
        let all = Array(sizes.keys)
        try transaction {
            // One transaction, so the revision moves at most once; looked up in slices, so a
            // library of 30,000 never puts that many ids in one query (spec 008).
            for start in stride(from: 0, to: all.count, by: 500) {
                let ids = Array(all[start..<min(start + 500, all.count)])
                let records = try modelContext.fetch(
                    FetchDescriptor<LibraryItemRecord>(
                        predicate: #Predicate { ids.contains($0.assetID) }))
                for record in records {
                    guard let size = sizes[record.assetID] else { continue }
                    // Only a size that was missing or an estimate becoming a measured one can
                    // change which copy is kept or how much is shown, so only that moves the
                    // revision.
                    if !size.isEstimated, record.byteSize == nil || record.isSizeEstimated {
                        touchedResults = true
                    }
                    record.byteSize = size.bytes
                    record.isSizeEstimated = size.isEstimated
                }
            }
        }
    }

    public func sizes(for assetIDs: [String]) throws -> [String: MeasuredSize] {
        guard !assetIDs.isEmpty else { return [:] }
        let ids = assetIDs
        let records = try modelContext.fetch(
            FetchDescriptor<LibraryItemRecord>(predicate: #Predicate { ids.contains($0.assetID) }))
        var out: [String: MeasuredSize] = [:]
        for record in records {
            if let bytes = record.byteSize {
                out[record.assetID] = MeasuredSize(
                    bytes: bytes, isEstimated: record.isSizeEstimated)
            }
        }
        return out
    }
}

#if DEBUG
    struct InjectedStoreFailure: Error {}

    extension SwiftDataStore {
        /// Test hook: whether the store is running on the main thread (it must never be).
        public func isOnMainThreadForTesting() -> Bool { Thread.isMainThread }

        /// Test hook: the next `count` write transactions fail, as a full disk would make them.
        public func failNextWritesForTesting(_ count: Int) { injectedWriteFailures = count }

        /// Test hook: marks the store as written by another format version.
        public func setFormatVersionForTesting(_ version: Int) throws {
            try meta().formatVersion = version
            try modelContext.save()
        }

        /// Test hook: the next `count` checkpoints (and only those) fail.
        public func failNextCheckpointsForTesting(_ count: Int) {
            injectedCheckpointFailures = count
        }

        /// Test hook: damages a saved state row's payload so its checksum no longer matches.
        public func corruptStateForTesting(_ key: StateKey) throws {
            let name = key.rawValue
            if let record = try modelContext.fetch(
                FetchDescriptor<StateRecord>(predicate: #Predicate { $0.key == name })
            ).first {
                record.payload = record.payload + Data([0xFF])
                try modelContext.save()
            }
        }
    }
#endif

extension SwiftDataStore {
    /// The three files one SQLite store is made of. They are one unit: the write-ahead log holds
    /// commits the data file does not have yet, so a store must be moved or deleted as all three.
    public static func storeFileURLs(in folder: URL) -> [URL] {
        ["iclean.store", "iclean.store-wal", "iclean.store-shm"].map { folder.appending(path: $0) }
    }

    /// Deletes the store, its write-ahead log and its shared-memory file together.
    public static func eraseStoreFiles(in folder: URL) throws {
        for url in storeFileURLs(in: folder) where FileManager.default.fileExists(atPath: url.path)
        {
            try FileManager.default.removeItem(at: url)
        }
    }
}
