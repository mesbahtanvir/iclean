import Foundation

public struct CategoryResult: Sendable, Hashable, Identifiable {
    public var category: CleanupCategory
    public var groups: [ResultGroup]
    public var id: CleanupCategory { category }

    public init(category: CleanupCategory, groups: [ResultGroup]) {
        self.category = category
        self.groups = groups
    }

    /// Every item shown in the category, keepers included.
    public var allMembers: [String] { groups.flatMap(\.members) }
    /// Items that could be removed (not keepers).
    public var removable: [String] { groups.flatMap(\.removable) }
}

public struct CleanupResults: Sendable, Hashable {
    /// Non-empty categories, in `CleanupCategory` order.
    public var categories: [CategoryResult]
    public var defaultSelection: Set<String>
    public var notScannedCount: Int
    public var items: [String: LibraryItem]

    public init(
        categories: [CategoryResult], defaultSelection: Set<String>, notScannedCount: Int,
        items: [String: LibraryItem]
    ) {
        self.categories = categories
        self.defaultSelection = defaultSelection
        self.notScannedCount = notScannedCount
        self.items = items
    }

    public static let empty = CleanupResults(
        categories: [], defaultSelection: [], notScannedCount: 0, items: [:])

    public func category(_ c: CleanupCategory) -> CategoryResult? {
        categories.first { $0.category == c }
    }

    public func category(of assetID: String) -> CleanupCategory? {
        categories.first { $0.allMembers.contains(assetID) }?.category
    }

    public func group(containing assetID: String) -> ResultGroup? {
        for c in categories {
            if let g = c.groups.first(where: { $0.members.contains(assetID) }) { return g }
        }
        return nil
    }

    /// Count and bytes of the removable items in a category.
    public func totals(for c: CleanupCategory) -> (count: Int, bytes: Int64, isEstimate: Bool) {
        guard let result = category(c) else { return (0, 0, false) }
        let ids = result.removable
        let bytes = ids.reduce(Int64(0)) { $0 + (items[$1]?.effectiveByteSize ?? 0) }
        let estimate = ids.contains { items[$0]?.sizeIsEstimate ?? true }
        return (ids.count, bytes, estimate)
    }

    /// Removes items (deleted elsewhere or just removed) and drops groups that no
    /// longer have anything to remove.
    public func removing(_ assetIDs: Set<String>) -> CleanupResults {
        guard !assetIDs.isEmpty else { return self }
        var copy = self
        copy.categories = categories.compactMap { result in
            var r = result
            r.groups = result.groups.compactMap { g in
                // A removal touches a few groups out of thousands: leave the others as they are
                // (nothing is copied or rebuilt), so removing 15,000 photos stays a quick pass.
                let touched = g.members.contains { assetIDs.contains($0) }
                if !touched, g.type == .single || !g.keepers.isEmpty {
                    if g.type == .single { return g.members.isEmpty ? nil : g }
                    return g.members.count < 2 || g.removable.isEmpty ? nil : g
                }
                var g = g
                if touched {
                    g.members.removeAll { assetIDs.contains($0) }
                    g.keepers = g.keepers.filter { !assetIDs.contains($0) }
                    g.dateNotes = g.dateNotes.filter { g.members.contains($0.key) }
                }
                if g.type == .single { return g.members.isEmpty ? nil : g }
                if g.members.count < 2 || g.removable.isEmpty { return nil }
                if g.keepers.isEmpty {
                    // The keeper is gone: suggest the best of what is left, by the same rules.
                    let rest = g.members.compactMap { items[$0] }
                    switch g.type {
                    case .duplicatePhotos, .duplicateVideos:
                        g.keepers = KeeperRules.duplicateKeepers(rest)
                        g.dateNotes = KeeperRules.dateNotes(rest)
                    case .similarShots:
                        g.keepers = KeeperRules.similarKeepers(rest)
                    case .single:
                        break
                    }
                    if g.keepers.isEmpty, let first = g.members.first { g.keepers = [first] }
                }
                return g
            }
            return r.groups.isEmpty ? nil : r
        }
        copy.defaultSelection.subtract(assetIDs)
        assetIDs.forEach { copy.items.removeValue(forKey: $0) }
        return copy
    }
}

public protocol ResultsBuilder: Sendable {
    func buildResults(items: [LibraryItem], keepMarks: Set<String>) -> CleanupResults
}

/// Builds categories from stored items (data-model.md "Derived").
public struct DefaultResultsBuilder: ResultsBuilder {
    public var detectors: [any CategoryDetector]

    public init(detectors: [any CategoryDetector]) {
        self.detectors = detectors.sorted { $0.category < $1.category }
    }

    public func buildResults(items unordered: [LibraryItem], keepMarks: Set<String>)
        -> CleanupResults
    {
        // The store returns items in no particular order. A fixed order (oldest first,
        // then identifier) keeps groups and lists from reshuffling between launches.
        let items = unordered.sorted { a, b in
            let da = a.metadata.captureDate ?? .distantPast
            let db = b.metadata.captureDate ?? .distantPast
            return da != db ? da < db : a.assetID < b.assetID
        }
        let byID = Dictionary(items.map { ($0.assetID, $0) }, uniquingKeysWith: { a, _ in a })
        // Favorites and keep-marked items are protected: they may appear only as keepers.
        let protected = Set(items.filter { $0.metadata.isFavorite }.map(\.assetID))
            .union(keepMarks)

        var assigned: Set<String> = []
        var categories: [CategoryResult] = []
        for detector in detectors {
            let candidates = items.filter { item in
                !assigned.contains(item.assetID)
                    && (!detector.needsAnalysis || item.analysisSource.hasAnalysis)
            }
            var groups: [ResultGroup] = []
            for var group in detector.detect(items: candidates) {
                let members = group.members.filter { byID[$0] != nil && !assigned.contains($0) }
                guard members.count == group.members.count else { continue }
                if group.type == .single {
                    guard let only = members.first, !protected.contains(only) else { continue }
                } else {
                    group.keepers.formUnion(members.filter { protected.contains($0) })
                    group.keepers.formIntersection(members)
                    if group.keepers.isEmpty, let first = members.first { group.keepers = [first] }
                    guard members.count >= 2, !group.removable.isEmpty else { continue }
                }
                groups.append(group)
            }
            guard !groups.isEmpty else { continue }
            groups.forEach { assigned.formUnion($0.members) }
            categories.append(CategoryResult(category: detector.category, groups: groups))
        }

        var selection: Set<String> = []
        for c in categories where c.category.preselects {
            selection.formUnion(c.removable)
        }
        selection.subtract(protected)

        // Only what is listed is kept, and without fingerprints: the screens need nothing else,
        // and keeping every item of a large library with its fingerprints cost hundreds of MB.
        // Face quality is read only to choose the keeper of a similar-shots group (also after a keeper
        // is removed), so only those members keep it. A scan may leave it out of photos nothing can
        // group (spec 010); dropping it from every other listed item makes a deferred scan's results
        // and a complete scan's results equal values.
        var shown: [String: LibraryItem] = [:]
        for c in categories {
            for id in c.allMembers {
                var item = byID[id]?.withoutFingerprints
                if c.category != .similar { item?.analysis?.faceQuality = nil }
                shown[id] = item
            }
        }
        return CleanupResults(
            categories: categories, defaultSelection: selection,
            notScannedCount: items.filter { $0.analysisSource == .notScanned }.count,
            items: shown)
    }
}
