import Foundation

/// What the person decided while results were on screen, by photo id. Results are rebuilt while
/// a scan goes on (spec 008, 004 FR-011), and these decisions are laid over every new build so
/// nothing the person did is undone by an update.
public struct ReviewChoices: Sendable, Equatable {
    /// True: the person marked the photo for removal. False: the person unmarked a photo that
    /// was marked by default.
    public var marks: [String: Bool]
    /// Photos the person made the keeper of their group.
    public var keepers: Set<String>
    /// Photos removed in this session. They are never listed again, even if a late scan result
    /// brings them back.
    public var removed: Set<String>

    public init(
        marks: [String: Bool] = [:], keepers: Set<String> = [], removed: Set<String> = []
    ) {
        self.marks = marks
        self.keepers = keepers
        self.removed = removed
    }
}

public enum ResultsContinuity {
    /// The new results with the person's decisions applied, and the selection that goes with them.
    ///
    /// Only what the person decided is carried over. A keeper that was merely shown is not
    /// pinned: pinning it would make the final results differ from a one-shot scan of the same
    /// library (004 FR-014), and a later, better copy would never be suggested.
    public static func merge(_ new: CleanupResults, choices: ReviewChoices) -> (
        results: CleanupResults, selection: Set<String>
    ) {
        var results = new.removing(choices.removed)
        for c in results.categories.indices {
            for g in results.categories[c].groups.indices {
                var group = results.categories[c].groups[g]
                guard group.type != .single else { continue }
                let chosen = Set(group.members).intersection(choices.keepers)
                guard !chosen.isEmpty else { continue }
                // Favorites always stay keepers (001 FR-009).
                let protected = group.members.filter {
                    results.items[$0]?.metadata.isFavorite == true
                }
                group.keepers = chosen.union(protected)
                results.categories[c].groups[g] = group
                // The default selection follows the keepers: everything else in the group is
                // marked for removal in a category that starts marked.
                results.defaultSelection.subtract(group.members)
                if results.categories[c].category.preselects {
                    results.defaultSelection.formUnion(group.removable)
                }
            }
        }
        var selection = results.defaultSelection
        for (id, marked) in choices.marks where results.items[id] != nil {
            if marked { selection.insert(id) } else { selection.remove(id) }
        }
        // A keeper is never marked for removal.
        for category in results.categories {
            for group in category.groups where group.type != .single {
                selection.subtract(group.keepers)
            }
        }
        return (results, selection)
    }
}
