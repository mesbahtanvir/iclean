import Foundation

/// Why a photo was left out of a removal.
public enum RemovalDrop: String, Sendable, CaseIterable {
    /// It is no longer in the library.
    case gone
    /// It is a favorite now.
    case nowFavorite
    /// It changed (edited, or its details changed) since it was suggested.
    case changed
    /// Every photo that was to be kept from its group is gone, so removing the rest could lose a
    /// whole set.
    case keeperGone
    /// It is not in any suggested group any more (its group fell apart), so nothing suggests
    /// removing it.
    case notSuggested
}

/// What a removal will do, fixed at the moment the confirm sheet opened. The sheet shows it and
/// Remove executes exactly it: results that change meanwhile do not change an open plan.
public struct RemovalPlan: Sendable {
    public var ids: Set<String>
    /// The results the plan was made from (a value, so later changes do not reach it).
    public var results: CleanupResults
    public var dropped: [RemovalDrop: Set<String>]

    public init(
        ids: Set<String>, results: CleanupResults, dropped: [RemovalDrop: Set<String>] = [:]
    ) {
        self.ids = ids
        self.results = results
        self.dropped = dropped
    }

    public var droppedCount: Int { dropped.values.reduce(0) { $0 + $1.count } }
}

/// Checks a selection against the Photos library as it is now, just before it is shown for
/// confirmation. A saved view can be old; this keeps an old view from removing a photo the person
/// has since changed or deleted.
public enum RemovalGate {
    public static func plan(
        selection: Set<String>, results: CleanupResults, library: PhotoLibrary
    ) async -> RemovalPlan {
        // Only photos that some group of the results still suggests: a copy whose group fell
        // apart because its keeper was deleted is a lone photo now, and nothing says to remove it.
        let members = Set(results.categories.flatMap(\.allMembers))
        let known = selection.filter { results.items[$0] != nil }
        let ids = known.filter(members.contains)
        // The keepers of every group that has something selected are checked too.
        var keeperIDs: Set<String> = []
        for category in results.categories {
            for group in category.groups where group.type != .single {
                if group.members.contains(where: ids.contains) {
                    keeperIDs.formUnion(group.keepers)
                }
            }
        }
        let now = await library.stamps(forIDs: Array(ids.union(keeperIDs)))

        var dropped: [RemovalDrop: Set<String>] = [:]
        let orphans = known.subtracting(ids)
        if !orphans.isEmpty { dropped[.notSuggested] = orphans }
        var kept = ids
        func drop(_ id: String, _ reason: RemovalDrop) {
            kept.remove(id)
            dropped[reason, default: []].insert(id)
        }
        for id in ids {
            guard let current = now[id] else {
                drop(id, .gone)
                continue
            }
            let stored = results.items[id]?.metadata
            if current.isFavorite, stored?.isFavorite != true {
                drop(id, .nowFavorite)
            } else if let stored,
                stored.modificationDate != current.modificationDate
                    || stored.hasAdjustments != current.hasAdjustments
                    || stored.pixelWidth != current.pixelWidth
                    || stored.pixelHeight != current.pixelHeight
            {
                drop(id, .changed)
            }
        }
        // A group whose kept photos are all gone is left alone: nothing of the set must be lost.
        for category in results.categories {
            for group in category.groups where group.type != .single {
                guard !group.keepers.isEmpty, group.keepers.allSatisfy({ now[$0] == nil }) else {
                    continue
                }
                for id in group.members where kept.contains(id) { drop(id, .keeperGone) }
            }
        }
        return RemovalPlan(ids: kept, results: results, dropped: dropped)
    }
}
