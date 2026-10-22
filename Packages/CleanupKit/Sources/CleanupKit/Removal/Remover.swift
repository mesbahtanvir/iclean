import Foundation

public struct CategoryTotal: Sendable, Hashable {
    public var count: Int
    public var bytes: Int64
}

/// What the confirm sheet shows before removal (FR-012).
public struct RemovalPreview: Sendable, Hashable {
    public var count: Int
    public var bytes: Int64
    public var isEstimate: Bool
    public var byCategory: [CleanupCategory: CategoryTotal]
    /// Groups where every member is selected (FR-016 needs a separate warning).
    public var wholeGroupsSelected: [String]
}

/// Result of one removal (data-model.md "CleanupSummary").
public struct CleanupSummary: Sendable, Hashable {
    public var requestedCount: Int
    public var removedCount: Int
    public var bytesFreed: Int64
    public var isEstimate: Bool
    public var failedAssetIDs: [String]
    public var removedAssetIDs: [String]
    public var byCategory: [CleanupCategory: CategoryTotal]
    /// The user cancelled the iOS confirmation; nothing was removed.
    public var cancelled: Bool
}

public enum RemovalError: Error, Equatable {
    /// Every photo of a group is selected and the user has not confirmed that.
    case wholeGroupSelected([String])
    case nothingSelected
}

public protocol Remover: Sendable {
    func summary(for selection: Set<String>, in results: CleanupResults) -> RemovalPreview
    func remove(
        _ selection: Set<String>, in results: CleanupResults, confirmRemoveAll: Bool
    ) async throws -> CleanupSummary
}

public struct DefaultRemover: Remover {
    private let library: PhotoLibrary

    public init(library: PhotoLibrary) {
        self.library = library
    }

    public func summary(for selection: Set<String>, in results: CleanupResults) -> RemovalPreview {
        let ids = selection.filter { results.items[$0] != nil }
        let (byCategory, bytes, estimate) = totals(ids, in: results)
        let whole = results.categories.flatMap(\.groups).filter { g in
            g.type != .single && g.members.allSatisfy(selection.contains)
        }.map(\.id)
        return RemovalPreview(
            count: ids.count, bytes: bytes, isEstimate: estimate, byCategory: byCategory,
            wholeGroupsSelected: whole)
    }

    public func remove(
        _ selection: Set<String>, in results: CleanupResults, confirmRemoveAll: Bool
    ) async throws -> CleanupSummary {
        let preview = summary(for: selection, in: results)
        guard preview.count > 0 else { throw RemovalError.nothingSelected }
        if !preview.wholeGroupsSelected.isEmpty, !confirmRemoveAll {
            throw RemovalError.wholeGroupSelected(preview.wholeGroupsSelected)
        }
        let ids = selection.filter { results.items[$0] != nil }.sorted()
        let result = await library.remove(ids)
        let removed = Set(result.removed)
        let (byCategory, bytes, estimate) = totals(removed, in: results)
        return CleanupSummary(
            requestedCount: ids.count, removedCount: removed.count, bytesFreed: bytes,
            isEstimate: estimate, failedAssetIDs: result.failed.sorted(),
            removedAssetIDs: result.removed.sorted(), byCategory: byCategory,
            cancelled: result.cancelled)
    }

    private func totals(_ ids: Set<String>, in results: CleanupResults)
        -> ([CleanupCategory: CategoryTotal], Int64, Bool)
    {
        // One lookup table for the whole call: searching the categories for every id was
        // selection x members, which is billions of steps at 30,000 photos.
        let index = ResultsIndex(results)
        var byCategory: [CleanupCategory: CategoryTotal] = [:]
        var bytes: Int64 = 0
        var estimate = false
        for id in ids {
            guard let entry = index.entries[id] else { continue }
            bytes += entry.bytes
            estimate = estimate || entry.isEstimate
            byCategory[entry.category, default: CategoryTotal(count: 0, bytes: 0)].count += 1
            byCategory[entry.category, default: CategoryTotal(count: 0, bytes: 0)].bytes +=
                entry.bytes
        }
        return (byCategory, bytes, estimate)
    }
}
