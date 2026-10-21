import Foundation

/// Where every listed photo sits and what it weighs, built once per set of results (spec 009).
///
/// A photo is in exactly one category (the builder assigns each photo once), so a lookup by id is
/// enough. Without it, totalling a selection meant searching every category's members for every
/// selected photo: with 30,000 photos and half of them selected that is billions of steps.
public struct ResultsIndex: Sendable {
    public struct Entry: Sendable {
        public var category: CleanupCategory
        public var bytes: Int64
        public var isEstimate: Bool
        /// Not a keeper: a photo the person may remove.
        public var isRemovable: Bool
    }

    public struct CategoryTotals: Sendable, Equatable {
        public var members = 0
        public var removable = 0
        public var removableBytes: Int64 = 0
        public var removableIsEstimate = false
    }

    public let entries: [String: Entry]
    public let categories: [CleanupCategory: CategoryTotals]

    public init(_ results: CleanupResults) {
        var entries: [String: Entry] = [:]
        var totals: [CleanupCategory: CategoryTotals] = [:]
        for result in results.categories {
            var t = CategoryTotals()
            for group in result.groups {
                let removable = Set(group.removable)
                for id in group.members {
                    guard let item = results.items[id] else { continue }
                    let isRemovable = removable.contains(id)
                    entries[id] = Entry(
                        category: result.category, bytes: item.effectiveByteSize,
                        isEstimate: item.sizeIsEstimate, isRemovable: isRemovable)
                    t.members += 1
                    if isRemovable {
                        t.removable += 1
                        t.removableBytes += item.effectiveByteSize
                        t.removableIsEstimate = t.removableIsEstimate || item.sizeIsEstimate
                    }
                }
            }
            totals[result.category] = t
        }
        self.entries = entries
        self.categories = totals
    }
}

/// What one category looks like next to the current selection.
public struct CategoryTally: Sendable, Equatable {
    public var members = 0
    public var removable = 0
    public var removableBytes: Int64 = 0
    public var removableIsEstimate = false
    /// Selected photos in the category, keepers included (a keeper can be chosen for removal).
    public var selected = 0
    public var selectedRemovable = 0
    public var selectedBytes: Int64 = 0
    public var selectedIsEstimate = false
}

/// The selection in numbers: what a button like "Review 12 Items" and the figure above it both read,
/// so they always agree. Built in one pass over the selection, never over the whole library.
public struct SelectionSummary: Sendable, Equatable {
    public var count = 0
    public var bytes: Int64 = 0
    public var isEstimate = false
    public var perCategory: [CleanupCategory: CategoryTally] = [:]

    public static let empty = SelectionSummary()

    public init() {}

    /// Photos not in the index (gone since the results were built) are ignored.
    public static func make(selection: Set<String>, index: ResultsIndex) -> SelectionSummary {
        var summary = SelectionSummary()
        for (category, totals) in index.categories {
            summary.perCategory[category] = CategoryTally(
                members: totals.members, removable: totals.removable,
                removableBytes: totals.removableBytes,
                removableIsEstimate: totals.removableIsEstimate)
        }
        for id in selection {
            guard let entry = index.entries[id] else { continue }
            summary.count += 1
            summary.bytes += entry.bytes
            summary.isEstimate = summary.isEstimate || entry.isEstimate
            summary.perCategory[entry.category, default: CategoryTally()].selected += 1
            summary.perCategory[entry.category, default: CategoryTally()].selectedBytes +=
                entry.bytes
            if entry.isRemovable {
                summary.perCategory[entry.category, default: CategoryTally()].selectedRemovable += 1
            }
            if entry.isEstimate {
                summary.perCategory[entry.category, default: CategoryTally()].selectedIsEstimate =
                    true
            }
        }
        return summary
    }
}
