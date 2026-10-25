import Foundation

public struct CategoryResult: Sendable, Hashable, Identifiable {
    public var category: CleanupCategory
    public var groups: [ResultGroup]
    /// The level `groups` are at, for a category with levels (spec 011).
    public var level: ResultLevel?
    /// What every level would list, among the candidates the detector saw. Empty without levels.
    public var levels: [LevelSummary]
    public var id: CleanupCategory { category }

    public init(
        category: CleanupCategory, groups: [ResultGroup], level: ResultLevel? = nil,
        levels: [LevelSummary] = []
    ) {
        self.category = category
        self.groups = groups
        self.level = level
        self.levels = levels
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

    /// The removal category an item is listed in (spec 015: a trim category never answers here).
    public func category(of assetID: String) -> CleanupCategory? {
        categories.first { $0.category.action == .remove && $0.allMembers.contains(assetID) }?
            .category
    }

    /// The trim category an item is listed in, if any (spec 015 Live Photos).
    public func trimCategory(of assetID: String) -> CleanupCategory? {
        categories.first { $0.category.action == .trim && $0.allMembers.contains(assetID) }?
            .category
    }

    public func group(containing assetID: String) -> ResultGroup? {
        for c in categories {
            if let g = c.groups.first(where: { $0.members.contains(assetID) }) { return g }
        }
        return nil
    }

    /// Count and bytes of the removable items in a category. For a trim category the bytes are the
    /// movies that would go, not the whole assets (spec 015).
    public func totals(for c: CleanupCategory) -> (count: Int, bytes: Int64, isEstimate: Bool) {
        guard let result = category(c) else { return (0, 0, false) }
        let ids = result.removable
        let bytes = ids.reduce(Int64(0)) { sum, id in
            let item = items[id]
            let bytes = c.action == .trim ? item?.motionByteSize : item?.effectiveByteSize
            return sum + (bytes ?? 0)
        }
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
            r.groups = result.groups.compactMap { g -> ResultGroup? in
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
                    case .duplicatePhotos:
                        g.keepers = KeeperRules.duplicateKeepers(rest)
                        g.dateNotes = KeeperRules.dateNotes(rest)
                    case .similarShots:
                        g.keepers = KeeperRules.similarKeepers(rest)
                    case .burst:
                        g.keepers = KeeperRules.burstKeepers(rest)
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
        // Removal categories first, each seeing what the earlier ones left; then the trim categories
        // (spec 015), which see every item, since trimming a photo and removing it are different
        // decisions and an asset may be listed for both.
        let removals = detectors.filter { $0.category.action == .remove }
        let ordered = removals + detectors.filter { $0.category.action == .trim }
        for detector in ordered {
            let candidates = items.filter { item in
                (detector.category.action == .trim || !assigned.contains(item.assetID))
                    && (!detector.needsAnalysis || item.analysisSource.hasAnalysis)
            }
            var groups: [ResultGroup] = []
            let detection = detector.detectLevelled(items: candidates, all: items)
            for var group in detection.groups {
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
            // A category with levels stays when the chosen level lists nothing but another level would,
            // so the person can step back; at the default level nothing listed means no category, as before.
            let keepsEmpty =
                detection.level != nil && detection.level != detector.category.defaultLevel
                && detection.levels.contains { $0.photos > 0 }
            guard !groups.isEmpty || keepsEmpty else { continue }
            if detector.category.action == .remove {
                groups.forEach { assigned.formUnion($0.members) }
            }
            categories.append(
                CategoryResult(
                    category: detector.category, groups: groups, level: detection.level,
                    levels: detection.levels))
        }

        var selection: Set<String> = []
        for c in categories where c.category.preselects(at: c.level) {
            selection.formUnion(c.removable)
        }
        selection.subtract(protected)

        // Only what is listed is kept, and without fingerprints: the screens need nothing else,
        // and keeping every item of a large library with its fingerprints cost hundreds of MB.
        // Face quality is read only to choose the keeper of a similar-shots or burst group (also after
        // a keeper is removed), so only those members keep it. A scan may leave it out of photos nothing can
        // group (spec 010); dropping it from every other listed item makes a deferred scan's results
        // and a complete scan's results equal values.
        var shown: [String: LibraryItem] = [:]
        for c in categories {
            for id in c.allMembers {
                var item = byID[id]?.withoutFingerprints
                if c.category != .similar, c.category != .bursts {
                    item?.analysis?.faceQuality = nil
                }
                shown[id] = item
            }
        }
        return CleanupResults(
            categories: categories, defaultSelection: selection,
            notScannedCount: items.filter { $0.analysisSource == .notScanned }.count,
            items: shown)
    }
}
