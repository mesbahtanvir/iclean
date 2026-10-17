import Foundation
import SwiftData

/// SwiftData-backed store in Application Support, excluded from backup, never synced
/// (research R9).
@ModelActor
public actor SwiftDataStore: Store {
    static let schema = Schema([
        LibraryItemRecord.self, KeepMarkRecord.self, ScanSessionRecord.self,
    ])

    /// The on-disk store: `Application Support/iclean/iclean.store`.
    public static func onDisk() throws -> SwiftDataStore {
        let folder = try storeFolder()
        let config = ModelConfiguration(
            schema: schema, url: folder.appending(path: "iclean.store"),
            cloudKitDatabase: .none)
        return SwiftDataStore(modelContainer: try ModelContainer(for: schema, configurations: config))
    }

    /// A store at a custom folder (tests).
    public static func at(folder: URL) throws -> SwiftDataStore {
        try prepare(folder)
        let config = ModelConfiguration(
            schema: schema, url: folder.appending(path: "iclean.store"),
            cloudKitDatabase: .none)
        return SwiftDataStore(modelContainer: try ModelContainer(for: schema, configurations: config))
    }

    public static func inMemory() throws -> SwiftDataStore {
        let config = ModelConfiguration(
            schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return SwiftDataStore(modelContainer: try ModelContainer(for: schema, configurations: config))
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

    public func upsert(_ items: [LibraryItem]) throws {
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
        try modelContext.save()
    }

    public func deleteItems(_ assetIDs: Set<String>) throws {
        guard !assetIDs.isEmpty else { return }
        let ids = Array(assetIDs)
        try modelContext.delete(
            model: LibraryItemRecord.self, where: #Predicate { ids.contains($0.assetID) })
        try modelContext.save()
    }

    // MARK: Keep marks

    public func keepMarks() throws -> Set<String> {
        Set(try modelContext.fetch(FetchDescriptor<KeepMarkRecord>()).map(\.assetID))
    }

    public func setKeep(_ assetID: String, _ keep: Bool) throws {
        let existing = try modelContext.fetch(
            FetchDescriptor<KeepMarkRecord>(predicate: #Predicate { $0.assetID == assetID }))
        if keep, existing.isEmpty {
            modelContext.insert(KeepMarkRecord(assetID: assetID))
        } else if !keep {
            existing.forEach(modelContext.delete)
        }
        try modelContext.save()
    }

    public func clearKeepMarks() throws {
        try modelContext.delete(model: KeepMarkRecord.self)
        try modelContext.save()
    }

    // MARK: Sessions

    public func saveSession(_ session: ScanSession) throws {
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
        // Keep only the latest few sessions.
        let old = all.filter { $0.id != id }.sorted { $0.startedAt > $1.startedAt }.dropFirst(4)
        old.forEach(modelContext.delete)
        try modelContext.save()
    }

    public func currentSession() throws -> ScanSession? {
        var descriptor = FetchDescriptor<ScanSessionRecord>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first?.session
    }

    // MARK: Delete all

    public func deleteAllData() throws {
        try modelContext.delete(model: LibraryItemRecord.self)
        try modelContext.delete(model: KeepMarkRecord.self)
        try modelContext.delete(model: ScanSessionRecord.self)
        try modelContext.save()
    }
}
