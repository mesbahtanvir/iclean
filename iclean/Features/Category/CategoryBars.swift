import CleanupKit
import SwiftUI

// The parts of the Category screen that read the selection. Each is its own view reading
// `model.summary`, so a toggle re-draws these and the photos that changed, and `CategoryView.body`
// (with every group in it) does not run again (spec 012 6.5, 9).

/// What the bars need from the summary, with zeros while the category is not in it yet.
private struct Tally {
    var selected = 0
    var selectedBytes: Int64 = 0
    var selectedIsEstimate = false
    var removable = 0
    var selectedRemovable = 0

    init(_ summary: SelectionSummary, _ category: CleanupCategory) {
        guard let tally = summary.perCategory[category] else { return }
        selected = tally.selected
        selectedBytes = tally.selectedBytes
        selectedIsEstimate = tally.selectedIsEstimate
        removable = tally.removable
        selectedRemovable = tally.selectedRemovable
    }
}

/// The one filled control: "Remove 3 Photos", one line (spec 014: the size is in the summary line
/// above the photos, and where they go is said on the Confirm sheet). With nothing selected it is
/// the same button, disabled and plain, never a faded slab.
struct CategoryRemoveBar: View {
    let category: CleanupCategory
    let action: () -> Void

    @Environment(AppModel.self) private var model

    var body: some View {
        let tally = Tally(model.summary, category)
        if tally.selected > 0 {
            Button(action: action) {
                title(count: tally.selected)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("category.removeSelected.title")
            }
            .prominentButtonStyle()
            .controlSize(.large)
            // Capped like the Review bar: a pinned bar must not grow into the photos above it.
            .actionShape(pinned: true)
            .accessibilityHint(Text("Opens a summary. Nothing is removed until you confirm."))
            .accessibilityIdentifier("category.removeSelected")
        } else {
            Button(action: action) {
                Text("Choose Items to Remove")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("category.removeSelected.title")
            }
            .secondaryButtonStyle()
            .controlSize(.large)
            .actionShape(pinned: true)
            .disabled(true)
            .accessibilityIdentifier("category.removeSelected")
        }
    }

    /// "Remove 3 Photos", "Remove 1 Video": the number is grouped and the noun agrees.
    @ViewBuilder private func title(count: Int) -> some View {
        switch ItemNoun(categories: [category]) {
        case .photos: Text("Remove ^[\(count) Photo](inflect: true)")
        case .videos: Text("Remove ^[\(count) Video](inflect: true)")
        case .items: Text("Remove ^[\(count) Item](inflect: true)")
        }
    }
}

#if os(macOS)
    /// The Mac's remove bar: a 40 pt status bar, not a slab (spec 012 section 6.15). The count and the
    /// size, quietly, on the left; on the right the one filled control, regular size, whose ellipsis
    /// says it opens a summary first. It has no keyboard shortcut: Return never removes anything.
    struct MacRemoveStatusBar: View {
        let category: CleanupCategory
        let action: () -> Void

        @Environment(AppModel.self) private var model

        var body: some View {
            let tally = Tally(model.summary, category)
            HStack(spacing: Space.m) {
                status(tally)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if tally.selected > 0 {
                    Button(action: action) { title(count: tally.selected) }
                        .prominentButtonStyle()
                        .controlSize(.regular)
                        .help("Opens a summary. Nothing is removed until you confirm.")
                        .accessibilityHint(
                            Text("Opens a summary. Nothing is removed until you confirm.")
                        )
                        .accessibilityIdentifier("category.removeSelected")
                } else {
                    Button(action: action) { Text("Remove…") }
                        .secondaryButtonStyle()
                        .controlSize(.regular)
                        .disabled(true)
                        .accessibilityIdentifier("category.removeSelected")
                }
            }
            .padding(.horizontal, Space.l)
            .frame(height: 40)
            .frame(maxWidth: .infinity)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
            .calmAnimation(value: tally.selected > 0)
        }

        /// "3 photos selected · about 4.8 MB", or "Nothing selected".
        @ViewBuilder private func status(_ tally: Tally) -> some View {
            if tally.selected > 0 {
                let size = Format.bytes(tally.selectedBytes, estimate: tally.selectedIsEstimate)
                let noun = ItemNoun(categories: [category]).singular
                Text("^[\(tally.selected) \(noun)](inflect: true) selected · \(size)")
            } else {
                Text("Nothing selected")
            }
        }

        /// "Remove 3 Photos…": the number is grouped and the noun agrees.
        @ViewBuilder private func title(count: Int) -> some View {
            switch ItemNoun(categories: [category]) {
            case .photos: Text("Remove ^[\(count) Photo](inflect: true)…")
            case .videos: Text("Remove ^[\(count) Video](inflect: true)…")
            case .items: Text("Remove ^[\(count) Item](inflect: true)…")
            }
        }
    }
#endif

/// The toolbar button: "Keep All" once every suggested item is selected (tapping it deselects them),
/// otherwise "Select Suggested", or "Select All Videos" on Large Videos. It never touches a keeper:
/// only the items that are not kept are in play.
struct SelectSuggestedButton: View {
    let category: CleanupCategory

    @Environment(AppModel.self) private var model
    @State private var taps = 0

    var body: some View {
        let tally = Tally(model.summary, category)
        let all = tally.removable > 0 && tally.selectedRemovable == tally.removable
        Button {
            taps += 1
            let ids = model.results.category(category)?.removable ?? []
            model.setSelected(ids, !all)
        } label: {
            if all {
                Text("Keep All")
            } else if category.listsVideos {
                Text("Select All Videos")
            } else {
                Text("Select Suggested")
            }
        }
        .disabled(tally.removable == 0)
        .sensoryFeedback(.selection, trigger: taps)
        .accessibilityIdentifier("category.selectAll")
    }
}

/// The line under the caption: how many sets (or photos, or videos) and how much space.
struct CategorySummaryLine: View {
    let category: CleanupCategory
    let count: Int
    /// Whether the entries are groups of copies or similar shots, or single photos and videos.
    let isGrouped: Bool

    @Environment(AppModel.self) private var model

    var body: some View {
        let tally = model.summary.perCategory[category]
        Self.text(
            category: category, count: count, isGrouped: isGrouped,
            size: tally.map {
                Format.bytes($0.removableBytes, estimate: $0.removableIsEstimate)
            }
        )
        .font(Typography.note)
        .foregroundStyle(Palette.quietText)
        .padding(.horizontal, Space.l)
    }

    /// "3 sets · 6.4 MB", "12 photos · 40 MB", or just the count while there is no size yet.
    static func text(category: CleanupCategory, count: Int, isGrouped: Bool, size: String?)
        -> Text
    {
        if let size {
            if isGrouped {
                return Text("^[\(count) set](inflect: true) · \(size)")
            }
            return Text(
                "^[\(count) \(ItemNoun(categories: [category]).singular)](inflect: true) · \(size)"
            )
        }
        if isGrouped { return Text("^[\(count) set](inflect: true)") }
        return Text("^[\(count) \(ItemNoun(categories: [category]).singular)](inflect: true)")
    }
}

#if os(macOS)
    /// The window's subtitle under the category's name: "3 sets · 6.4 MB". A modifier of its own, so
    /// the summary it reads re-draws it and not the screen it is on.
    struct CategorySubtitle: ViewModifier {
        let category: CleanupCategory
        let count: Int
        let isGrouped: Bool

        @Environment(AppModel.self) private var model

        func body(content: Content) -> some View {
            let tally = model.summary.perCategory[category]
            content.navigationSubtitle(
                CategorySummaryLine.text(
                    category: category, count: count, isGrouped: isGrouped,
                    size: tally.map {
                        Format.bytes($0.removableBytes, estimate: $0.removableIsEstimate)
                    }))
        }
    }
#endif

/// The header of one group of copies or similar shots: a 44 pt row that is the whole link to the
/// compare screen. "3 copies" over "2 selected", then "Compare" in the accent and a chevron.
struct GroupHeader: View {
    let category: CleanupCategory
    let group: ResultGroup

    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    #if os(macOS)
        /// On a Mac "Compare" is quiet at rest and in the accent when the pointer is over the row or
        /// the keyboard is on it.
        @State private var hovering = false
        @Environment(\.isFocused) private var focused
    #endif

    /// "Compare" in the accent: always on a phone. On a Mac the word and its chevron are always
    /// there, so the row reads as a link to someone who has not hovered it yet or who is on the
    /// keyboard, and the accent says "this one" for the row under the pointer or the focus.
    private var emphasized: Bool {
        #if os(macOS)
            hovering || focused
        #else
            true
        #endif
    }

    var body: some View {
        // A group has a handful of members, so counting the selected ones here is cheap.
        let selected = group.members.filter { model.isSelected($0) }.count
        let layout =
            typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.xs))
            : AnyLayout(HStackLayout(alignment: .center, spacing: Space.m))
        NavigationLink(value: Route.group(category, containing: group)) {
            layout {
                VStack(alignment: .leading, spacing: 2) {
                    title.font(.headline)
                    selectedText(selected)
                        .font(.subheadline)
                        .foregroundStyle(Palette.quietText)
                }
                if !typeSize.isAccessibilitySize { Spacer(minLength: Space.s) }
                HStack(spacing: Space.xs) {
                    Text("Compare")
                        .font(.subheadline)
                        .foregroundStyle(
                            emphasized
                                ? AnyShapeStyle(Palette.accentText)
                                : AnyShapeStyle(Palette.quietText))
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
            // One element: "3 copies, 2 selected, Compare".
            .accessibilityElement(children: .combine)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Space.l)
        #if os(macOS)
            .onHover { hovering = $0 }
            .help("Compare these side by side")
        #endif
        .accessibilityIdentifier("category.group.\(group.id)")
    }

    @ViewBuilder private var title: some View {
        let count = group.members.count
        switch group.type {
        case .similarShots: Text("^[\(count) similar shot](inflect: true)")
        case .burst: Text("^[\(count) burst frame](inflect: true)")
        default: Text("^[\(count) copy](inflect: true)")
        }
    }

    @ViewBuilder private func selectedText(_ selected: Int) -> some View {
        if selected == 0 {
            Text("None selected")
        } else {
            Text("\(selected) selected")
        }
    }
}
