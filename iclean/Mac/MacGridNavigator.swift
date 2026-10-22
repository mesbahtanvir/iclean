#if os(macOS)
    import CleanupKit
    import Observation
    import SwiftUI

    /// Where the keyboard can go in a grid of photos, and what a range is (spec 012 section 6.15;
    /// spec 005 FR-015 and FR-016). Plain data and arithmetic, so it can be reasoned about (and tested)
    /// without a window. Built once for a set of results: a step or a range is then a lookup, not a
    /// walk through thousands of ids.
    struct GridPlan {
        /// The photos in reading order, one list per group (a flat grid is one list).
        let sections: [[String]]
        /// The id of each group's section, in the same order; nil in a flat grid.
        let groupIDs: [String]?
        /// How many photos fit in a row, from the width of the grid.
        var columns: Int
        /// The photos suggested to keep. A range never selects them.
        let keepers: Set<String>

        /// Where a photo is: its section, its place in it, and its place in the reading order.
        private struct Place {
            let section: Int
            let index: Int
            let overall: Int
        }

        private let places: [String: Place]
        private let flat: [String]

        init(sections: [[String]], groupIDs: [String]?, columns: Int, keepers: Set<String>) {
            self.sections = sections
            self.groupIDs = groupIDs
            self.columns = columns
            self.keepers = keepers
            var places: [String: Place] = [:]
            var flat: [String] = []
            flat.reserveCapacity(sections.reduce(0) { $0 + $1.count })
            for (s, section) in sections.enumerated() {
                for (i, id) in section.enumerated() {
                    places[id] = Place(section: s, index: i, overall: flat.count)
                    flat.append(id)
                }
            }
            self.places = places
            self.flat = flat
        }

        /// Where an arrow key leads from a photo.
        struct Step: Equatable {
            let id: String
            /// The id of the group section to bring on screen first, when the step leaves the group
            /// the key was pressed in: in a long list the next group may not be built yet.
            let groupID: String?
        }

        func contains(_ id: String) -> Bool { places[id] != nil }

        /// The id of the group section a photo is in; nil in a flat grid.
        func groupID(of id: String) -> String? {
            guard let place = places[id] else { return nil }
            return groupIDs.flatMap { $0.indices.contains(place.section) ? $0[place.section] : nil }
        }

        /// The first photo, as a step.
        var first: Step? { sections.first?.first.map { Step(id: $0, groupID: groupIDs?.first) } }

        /// The photo an arrow key leads to from `id`: along a row with left and right (on to the next
        /// group at the end of one), and by a row with up and down, in the same column where there is
        /// one. Nil at the edge of the grid. From a photo that is not in the grid, the first photo.
        func step(from id: String, _ direction: MoveCommandDirection) -> Step? {
            guard let place = places[id] else { return first }
            let (s, i) = (place.section, place.index)
            let section = sections[s]
            let columns = max(self.columns, 1)
            func within(_ target: String) -> Step { Step(id: target, groupID: nil) }
            func across(_ target: String, _ index: Int) -> Step {
                let groupID = groupIDs.flatMap { $0.indices.contains(index) ? $0[index] : nil }
                return Step(id: target, groupID: groupID)
            }
            switch direction {
            case .left:
                if i > 0 { return within(section[i - 1]) }
                guard s > 0, let last = sections[s - 1].last else { return nil }
                return across(last, s - 1)
            case .right:
                if i + 1 < section.count { return within(section[i + 1]) }
                guard s + 1 < sections.count, let first = sections[s + 1].first else { return nil }
                return across(first, s + 1)
            case .down:
                if i + columns < section.count { return within(section[i + columns]) }
                // A shorter last row has no photo under this one: go to its end.
                if i / columns < (section.count - 1) / columns, let last = section.last {
                    return within(last)
                }
                guard s + 1 < sections.count, !sections[s + 1].isEmpty else { return nil }
                let next = sections[s + 1]
                return across(next[min(i % columns, next.count - 1)], s + 1)
            case .up:
                if i - columns >= 0 { return within(section[i - columns]) }
                guard s > 0, !sections[s - 1].isEmpty else { return nil }
                let previous = sections[s - 1]
                let lastRow = ((previous.count - 1) / columns) * columns
                return across(previous[min(lastRow + i % columns, previous.count - 1)], s - 1)
            @unknown default:
                return nil
            }
        }

        /// The photos from `anchor` to `id`, in reading order, without any suggested keeper. Just `id`
        /// itself when there is no anchor.
        func range(from anchor: String?, to id: String) -> [String] {
            guard let end = places[id]?.overall else { return [] }
            let start = anchor.flatMap { places[$0]?.overall } ?? end
            return flat[min(start, end)...max(start, end)].filter { !keepers.contains($0) }
        }
    }

    /// What the cells of one grid share: where the keyboard is, where it can go, and where a range
    /// starts. A class, so every cell holds the same one: handing each cell the lists would make a
    /// grid of thousands compare thousands of ids per cell.
    ///
    /// The grid is one keyboard target (the scroll view), and the photo the keyboard is on is a plain
    /// property here, not a focus of the photo's own. So it exists whether or not the photo's cell
    /// does, and a long grid that scrolled it away still has it. Only the little ring and controls
    /// of a cell read it (`isFocused`), so a key press redraws those and not the cells.
    ///
    /// The plan of where the keys lead is built when a key or a Shift-click first needs it for a set
    /// of results, and kept until the results change, so a held arrow key is a lookup per press.
    @MainActor @Observable
    final class GridNavigator {
        /// The photo the keyboard is on, if any.
        private(set) var focusedID: String?
        /// The group section the keyboard's photo is in; nil in a flat grid. For Compare.
        private(set) var focusedGroupID: String?
        /// Whether the grid has the keyboard: the ring shows only then.
        var isActive = false

        /// The category's results, now.
        @ObservationIgnored var results: () -> CategoryResult? = { nil }
        /// A number that changes whenever the results do, to know when the plan is out of date.
        @ObservationIgnored var version: () -> Int = { 0 }
        /// The photo a restored screen opens on, where the keyboard starts if it is in the grid.
        @ObservationIgnored var restoredPhoto: () -> String? = { nil }
        /// How many photos fit in a row, from the width of the grid.
        @ObservationIgnored var columns = 1
        /// Whether the grid is a list of groups, each with a Compare screen.
        @ObservationIgnored var isGrouped = false
        /// Where a Shift-click or Shift-arrow starts: the photo last clicked or moved to.
        @ObservationIgnored var anchor: String?
        /// Brings a photo into view; the second argument is the group section to bring first. Set by
        /// the screen that owns the scroll view.
        @ObservationIgnored var scrollTo: ((String, String?) -> Void)?
        /// Gives the grid the keyboard. Set by the screen that owns the scroll view.
        @ObservationIgnored var takeKeyboard: (() -> Void)?
        /// Marks photos for removal (a range). Set by the screen, which has the model.
        @ObservationIgnored var select: (([String]) -> Void)?
        /// The photos whose cells exist now, to tell a focused photo that scrolled away.
        @ObservationIgnored private var onScreen: Set<String> = []
        /// A photo known to be in view although its cell may not have reported it yet: the one just
        /// clicked, moved to, or scrolled back to. Cleared when its cell is let go of.
        @ObservationIgnored private var shown: String?
        @ObservationIgnored private var cached: (version: Int, plan: GridPlan)?

        var plan: GridPlan {
            let current = version()
            if var cached, cached.version == current {
                cached.plan.columns = columns
                return cached.plan
            }
            var built: GridPlan
            if let result = results() {
                let flat = result.groups.first?.type == .single
                let groups = result.groups
                built = GridPlan(
                    sections: flat ? [result.allMembers] : groups.map(\.members),
                    groupIDs: flat ? nil : groups.map(\.id), columns: columns,
                    keepers: Set(groups.filter { $0.type != .single }.flatMap(\.keepers)))
            } else {
                built = GridPlan(sections: [], groupIDs: nil, columns: columns, keepers: [])
            }
            cached = (current, built)
            return built
        }

        // MARK: Where the keyboard is

        /// Whether the ring is on this photo.
        func isFocused(_ id: String) -> Bool { isActive && focusedID == id }

        /// A click: the keyboard is on this photo, and the grid has the keyboard. (Where a range
        /// starts is the click's to say: a Shift-click must keep the anchor it extends from.)
        func focus(_ id: String) {
            focusedID = id
            focusedGroupID = isGrouped ? plan.groupID(of: id) : nil
            shown = id
            takeKeyboard?()
        }

        /// A cell was built or let go of.
        func appeared(_ id: String) { onScreen.insert(id) }
        func disappeared(_ id: String) {
            onScreen.remove(id)
            if shown == id { shown = nil }
        }

        /// The photo a key that changes something should act on: the one the keyboard is on, but
        /// only if it can be seen. One that scrolled away is brought back instead, and the key does
        /// nothing more, so a key never changes a photo nobody can see. (If the photo still does not
        /// count as seen once it was brought back, the next press acts: the key is never dead.)
        func photoToAct() -> String? {
            guard let id = focusedID else { return nil }
            if onScreen.contains(id) || shown == id { return id }
            shown = id
            scrollTo?(id, plan.groupID(of: id))
            return nil
        }

        // MARK: Keys

        /// An arrow key: the keyboard goes to the neighbour, which is scrolled to first, because in a
        /// long list it may not exist yet. With `extending` (Shift) every photo from the anchor to
        /// the neighbour is marked for removal too, never a suggested keeper, as a Shift-click does.
        func move(_ direction: MoveCommandDirection, extending: Bool = false) {
            let plan = self.plan
            let target: GridPlan.Step?
            if let focusedID, plan.contains(focusedID) {
                target = plan.step(from: focusedID, direction)
            } else if let restored = restoredPhoto(), plan.contains(restored) {
                // Nothing has the keyboard yet: it starts where the screen was restored.
                target = GridPlan.Step(id: restored, groupID: plan.groupID(of: restored))
            } else {
                target = plan.first
            }
            guard let target else { return }
            if extending {
                let start = anchor ?? focusedID ?? target.id
                anchor = start
                select?(plan.range(from: start, to: target.id))
            } else {
                anchor = target.id
            }
            focusedID = target.id
            focusedGroupID = isGrouped ? plan.groupID(of: target.id) : nil
            shown = target.id
            scrollTo?(target.id, target.groupID)
        }
    }
#endif
