import Foundation
import SwiftData

/// SwiftData-backed store in Application Support, excluded from backup, never synced
/// (research R9).
@ModelActor
public actor SwiftDataStore: Store {
    static let schema = Schema([
        LibraryItemRecord.self, KeepMarkRecord.self, ScanSessionRecord.self, ScanChunkRecord.self,
    ])

    /// The on-disk store: `Application Support/iclean/iclean.store`.
    public static func onDisk() throws -> SwiftDataStore {
        let folder = try storeFolder()
        let config = ModelConfiguration(
            schema: schema, url: folder.appending(path: "iclean.store"),
            cloudKitDatabase: .none)
        return SwiftDataStore(
            modelContainer: try ModelContainer(for: schema, configurations: config))
    }

    /// A store at a custom folder (tests).
    public static func at(folder: URL) throws -> SwiftDataStore {
        try prepare(folder)
        let config = ModelConfiguration(
            schema: schema, url: folder.appending(path: "iclean.store"),
            cloudKitDatabase: .none)
        return SwiftDataStore(
            modelContainer: try ModelContainer(for: schema, configurations: config))
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
        #if os(iOS)
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

    /// Runs the writes and saves them together; on any error nothing is kept, so a
    /// failed write can never leave half of its changes to be committed by a later save.
    private func transaction(_ body: () throws -> Void) throws {
        do {
            try body()
            try modelContext.save()
        } catch {
            modelContext.rollback()
            throw error
        }
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
                record.update(from: item)
            } else {
                let record = LibraryItemRecord(item)
                modelContext.insert(record)
                byID[item.assetID] = record
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
            try modelContext.delete(
                model: LibraryItemRecord.self, where: #Predicate { ids.contains($0.assetID) })
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
            } else if !keep {
                existing.forEach(modelContext.delete)
            }
        }
    }

    public func clearKeepMarks() throws {
        try transaction { try modelContext.delete(model: KeepMarkRecord.self) }
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

    public func checkpoint(items: [LibraryItem], chunk: ScanChunk, session: ScanSession) throws {
        try transaction {
            try put(items)
            try putChunks([chunk])
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
        }
    }
}
