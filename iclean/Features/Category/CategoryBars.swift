import CleanupKit
import SwiftUI

// The parts of the Category screen that read the selection. Each is its own view reading
// `model.summary`, so a toggle re-draws these and the photos that changed, and `CategoryView.body`
// (with every group in it) does not run again (spec 009 6.5, 9).

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

/// "4.8 MB · goes to Recently Deleted": what the button below it will do, and where it goes.
private func destination(_ tally: Tally) -> String {
    let size = Format.bytes(tally.selectedBytes, estimate: tally.selectedIsEstimate)
    return String(localized: "\(size) · goes to Recently Deleted")
}

/// The one filled control: "Remove 3 Photos" over the size and where it goes. With nothing selected
/// it is the same button, disabled and plain, never a faded slab.
struct CategoryRemoveBar: View {
    let category: CleanupCategory
    let action: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let tally = Tally(model.summary, category)
        if tally.selected > 0 {
            Button(action: action) {
                VStack(spacing: 2) {
                    title(count: tally.selected)
                        .font(.headline)
                    // At accessibility sizes the second line moves into the scroll content, so
                    // the pinned area stays one button tall.
                    if !typeSize.isAccessibilitySize {
                        Text(destination(tally))
                            .font(.subheadline.weight(.medium))
                    }
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                // One element for the two lines, so the button is one thing to tap and to read.
                .accessibilityElement(children: .combine)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityHint(Text("Opens a summary. Nothing is removed until you confirm."))
            .accessibilityIdentifier("category.removeSelected")
        } else {
            Button(action: action) {
                Text("Choose Items to Remove")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
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

/// At accessibility sizes the bar's second line lives here, at the end of the scroll content.
struct CategoryBarDetail: View {
    let category: CleanupCategory

    @Environment(AppModel.self) private var model

    var body: some View {
        let tally = Tally(model.summary, category)
        if tally.selected > 0 {
            Text(destination(tally))
                .font(Typography.note)
                .foregroundStyle(Palette.quietText)
                .padding(.horizontal, Space.l)
        }
    }
}

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
            } else if category == .largeVideos {
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
        line(size: tally.map { Format.bytes($0.removableBytes, estimate: $0.removableIsEstimate) })
            .font(Typography.note)
            .foregroundStyle(Palette.quietText)
            .padding(.horizontal, Space.l)
    }

    @ViewBuilder private func line(size: String?) -> some View {
        if let size {
            if isGrouped {
                Text("^[\(count) set](inflect: true) · \(size)")
            } else {
                Text(
                    "^[\(count) \(ItemNoun(categories: [category]).singular)](inflect: true) · \(size)"
                )
            }
        } else if isGrouped {
            Text("^[\(count) set](inflect: true)")
        } else {
            Text("^[\(count) \(ItemNoun(categories: [category]).singular)](inflect: true)")
        }
    }
}

/// The header of one group of copies or similar shots: a 44 pt row that is the whole link to the
/// compare screen. "3 copies" over "2 selected", then "Compare" in the accent and a chevron.
struct GroupHeader: View {
    let category: CleanupCategory
    let group: ResultGroup

    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize

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
                        .foregroundStyle(.tint)
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
        .accessibilityIdentifier("category.group.\(group.id)")
    }

    @ViewBuilder private var title: some View {
        let count = group.members.count
        if group.type == .similarShots {
            Text("^[\(count) similar shot](inflect: true)")
        } else {
            Text("^[\(count) copy](inflect: true)")
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
