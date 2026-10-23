import Foundation

/// What the person decided while reviewing, as deviations from the defaults, keyed by photo
/// (never by group: a group's id is a hash of its members and changes when one leaves).
///
/// It is saved as it changes and replayed over every publish of results (launch, foreground, scan,
/// rebuild), so a rebuild never undoes their choices. See specs/007-persistent-session.
public struct ReviewIntent: Codable, Equatable, Sendable {
    public static let formatVersion = 1
    /// How long a "remove this" decision is honoured. It is short on purpose: a photo someone
    /// ticked last month is not something to take out in the next big removal.
    public static let removeLifetime: TimeInterval = 7 * 24 * 3600
    /// A "keep this" decision is honoured much longer.
    public static let keepLifetime: TimeInterval = 180 * 24 * 3600

    /// Photos the person chose to remove although they are not selected by default.
    public var forcedOn: [String: Date]
    /// Photos the person chose to keep although they are selected by default.
    public var forcedOff: [String: Date]
    /// Photos the person chose to keep in their group ("Keep This One").
    public var keeperChoices: [String: Date]
    /// Photos in `forcedOn` that were ticked while they were an ordinary removable copy, not the
    /// kept one. If a rebuild later makes such a photo the kept copy, the tick no longer applies:
    /// the person never chose to remove the copy that is now suggested to be kept.
    public var removableTicks: Set<String>

    public init(
        forcedOn: [String: Date] = [:], forcedOff: [String: Date] = [:],
        keeperChoices: [String: Date] = [:], removableTicks: Set<String> = []
    ) {
        self.forcedOn = forcedOn
        self.forcedOff = forcedOff
        self.keeperChoices = keeperChoices
        self.removableTicks = removableTicks
    }

    public var isEmpty: Bool { forcedOn.isEmpty && forcedOff.isEmpty && keeperChoices.isEmpty }
    public var decisionCount: Int { forcedOn.count + forcedOff.count + keeperChoices.count }

    // MARK: Recording (the person's actions)

    /// A photo was ticked or unticked. `keepers` are the photos the results suggest keeping right
    /// now; a tick on any other photo is remembered as a tick on an ordinary removable copy.
    public mutating func setSelected(
        _ ids: [String], _ selected: Bool, keepers: Set<String>? = nil, at date: Date = .now
    ) {
        for id in ids {
            if selected {
                forcedOn[id] = date
                forcedOff[id] = nil
                if let keepers, !keepers.contains(id) {
                    removableTicks.insert(id)
                } else {
                    removableTicks.remove(id)
                }
            } else {
                forcedOff[id] = date
                forcedOn[id] = nil
                removableTicks.remove(id)
            }
        }
    }

    /// "Keep This One". The photo is kept, so it cannot also be marked for removal.
    public mutating func chooseKeeper(_ id: String, at date: Date = .now) {
        keeperChoices[id] = date
        forcedOn[id] = nil
        removableTicks.remove(id)
    }

    /// Photos that are gone, removed, or now kept for good need no decision any more.
    public mutating func forget(_ ids: Set<String>) {
        for id in ids {
            forcedOn[id] = nil
            forcedOff[id] = nil
            keeperChoices[id] = nil
            removableTicks.remove(id)
        }
    }

    /// Drops decisions that have expired.
    public mutating func expire(now: Date = .now) {
        forcedOn = forcedOn.filter { now.timeIntervalSince($0.value) <= Self.removeLifetime }
        forcedOff = forcedOff.filter { now.timeIntervalSince($0.value) <= Self.keepLifetime }
        keeperChoices = keeperChoices.filter {
            now.timeIntervalSince($0.value) <= Self.keepLifetime
        }
        removableTicks = removableTicks.filter { forcedOn[$0] != nil }
    }

    /// Without the decisions that only repeat the defaults, so what is saved stays small and a
    /// later change of a default is not held back by a choice that never differed from it.
    public func normalized(against defaults: Set<String>) -> ReviewIntent {
        var copy = self
        copy.forcedOn = forcedOn.filter { !defaults.contains($0.key) }
        copy.forcedOff = forcedOff.filter { defaults.contains($0.key) }
        copy.removableTicks = removableTicks.filter { copy.forcedOn[$0] != nil }
        return copy
    }

    // MARK: Replay

    public struct Applied: Sendable {
        public var results: CleanupResults
        public var selection: Set<String>
    }

    /// The default selection of `results`: removable photos of the categories that preselect,
    /// minus the protected ones (favorites and "always keep").
    public static func defaults(for results: CleanupResults, keepMarks: Set<String>) -> Set<String>
    {
        var selection: Set<String> = []
        for c in results.categories where c.category.preselects(at: c.level) {
            selection.formUnion(c.removable)
        }
        let protected = Set(results.items.values.filter { $0.metadata.isFavorite }.map(\.assetID))
            .union(keepMarks)
        return selection.subtracting(protected)
    }

    /// Replays the decisions over fresh results: keeper choices first (oldest first, so the
    /// latest wins), then the defaults are recomputed from the groups, then the selection is the
    /// defaults plus every still valid "remove" decision, minus every "keep" decision.
    public func apply(to results: CleanupResults, keepMarks: Set<String>, now: Date = .now)
        -> Applied
    {
        var results = results
        let protected = Set(results.items.values.filter { $0.metadata.isFavorite }.map(\.assetID))
            .union(keepMarks)
        if !keeperChoices.isEmpty {
            // One pass over the groups finds where each chosen photo is; replaying a choice then
            // touches only its own group instead of looking through all of them.
            var places: [String: [(category: Int, group: Int)]] = [:]
            for ci in results.categories.indices {
                for (gi, group) in results.categories[ci].groups.enumerated()
                where group.type != .single {
                    for member in group.members where keeperChoices[member] != nil {
                        places[member, default: []].append((ci, gi))
                    }
                }
            }
            for (id, _) in keeperChoices.sorted(by: { $0.value < $1.value }) {
                for place in places[id] ?? [] {
                    // Favorites and "always keep" photos stay keepers; the chosen one joins them.
                    let stay = results.categories[place.category].groups[place.group].keepers
                        .filter { protected.contains($0) }
                    results.categories[place.category].groups[place.group].keepers = stay.union([id]
                    )
                }
            }
        }
        let defaults = Self.defaults(for: results, keepMarks: keepMarks)
        results.defaultSelection = defaults
        let members = Set(results.categories.flatMap(\.allMembers))
        var selection = defaults
        let keepers = Set(
            results.categories.flatMap {
                $0.groups.filter { $0.type != .single }.flatMap(\.keepers)
            })
        for (id, decidedAt) in forcedOn {
            guard members.contains(id), !protected.contains(id),
                now.timeIntervalSince(decidedAt) <= Self.removeLifetime
            else { continue }
            // Ticked as an ordinary copy, and now the copy suggested to be kept: not a choice the
            // person made about this photo.
            if keepers.contains(id), removableTicks.contains(id) { continue }
            // A photo edited after the person ticked it is not the photo they ticked.
            if let modified = results.items[id]?.metadata.modificationDate, modified > decidedAt {
                continue
            }
            selection.insert(id)
        }
        for (id, decidedAt) in forcedOff where now.timeIntervalSince(decidedAt) <= Self.keepLifetime
        {
            selection.remove(id)
        }
        return Applied(results: results, selection: selection)
    }
}
