#if os(macOS)
    import AppKit
    import CleanupKit
    import SwiftUI

    /// Where the keyboard can go in a grid of photos, and what a range is (spec 009 section 6.15;
    /// spec 005 FR-015 and FR-016). Plain data and arithmetic, so it can be reasoned about (and tested)
    /// without a window.
    struct GridPlan {
        /// The photos in reading order, one list per group (a flat grid is one list).
        var sections: [[String]]
        /// The id of each group's section, in the same order; nil in a flat grid.
        var groupIDs: [String]?
        /// How many photos fit in a row, from the width of the grid.
        var columns: Int
        /// The photos suggested to keep. A range never selects them.
        var keepers: Set<String>

        /// Where an arrow key leads from a photo.
        struct Step: Equatable {
            let id: String
            /// The id of the group section to bring on screen first, when the step leaves the group
            /// the key was pressed in: in a long list the next group may not be built yet.
            let groupID: String?
        }

        /// The photo an arrow key leads to from `id`: along a row with left and right (on to the next
        /// group at the end of one), and by a row with up and down, in the same column where there is
        /// one. Nil at the edge of the grid. From a photo that is not in the grid, the first photo.
        func step(from id: String, _ direction: MoveCommandDirection) -> Step? {
            guard let (s, i) = locate(id) else {
                return sections.first?.first.map { Step(id: $0, groupID: groupIDs?.first) }
            }
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
            let flat = sections.flatMap { $0 }
            guard let end = flat.firstIndex(of: id) else { return [] }
            let start = anchor.flatMap { flat.firstIndex(of: $0) } ?? end
            return flat[min(start, end)...max(start, end)].filter { !keepers.contains($0) }
        }

        private func locate(_ id: String) -> (Int, Int)? {
            for (s, section) in sections.enumerated() {
                if let i = section.firstIndex(of: id) { return (s, i) }
            }
            return nil
        }
    }

    /// What the cells of one grid share: where the keyboard can go and where a range starts. A class,
    /// so every cell holds the same one: handing each cell the lists would make a grid of thousands
    /// compare thousands of ids per cell. The plan is built when a key or a Shift-click needs it, from
    /// the results as they are then, so it is never stale.
    @MainActor
    final class GridNavigator {
        /// The category's results, now.
        var results: () -> CategoryResult? = { nil }
        /// How many photos fit in a row, from the width of the grid.
        var columns = 1
        /// Where a Shift-click starts: the photo last clicked or moved to.
        var anchor: String?
        /// Brings a photo into view; the second argument is the group section to bring first. Set by
        /// the screen that owns the scroll view.
        var scrollTo: ((String, String?) -> Void)?

        var plan: GridPlan {
            guard let result = results() else {
                return GridPlan(sections: [], groupIDs: nil, columns: columns, keepers: [])
            }
            let flat = result.groups.first?.type == .single
            let groups = result.groups
            return GridPlan(
                sections: flat ? [result.allMembers] : groups.map(\.members),
                groupIDs: flat ? nil : groups.map(\.id), columns: columns,
                keepers: Set(groups.filter { $0.type != .single }.flatMap(\.keepers)))
        }
    }

    /// One photo in a grid on a Mac (spec 009 sections 6.5 and 6.15): the phone's verdict language,
    /// with a pointer and a keyboard instead of a finger.
    ///
    /// - At rest it is the photo alone. The check mark and the expand control appear when the pointer
    ///   is over it, when it has the keyboard focus, and while it is selected (a selected photo
    ///   always shows its trash mark).
    /// - A click focuses the photo and nothing else. A click on the check mark toggles it, a
    ///   Command-click toggles it, a Shift-click selects the range from the last photo touched.
    /// - Space toggles, Return and a double-click open the viewer, the arrow keys move the focus, and
    ///   Delete opens the Confirm sheet. Nothing here confirms a removal.
    /// - A context menu replaces the long press, and every on-photo control has a tooltip.
    struct MacItemCell: View {
        let assetID: String
        var isKeeper: Bool
        var confidence: Confidence = .normal
        /// The pixels the picture needs, from the real width of the cell (`GridMetrics`).
        var pixelSize: Int
        /// The group this photo is in, nil in a flat grid.
        var group: ResultGroup?
        let navigator: GridNavigator
        var focus: FocusState<String?>.Binding
        var onView: () -> Void
        /// Delete: opens the Confirm sheet when something is selected.
        var onRemove: () -> Void

        @Environment(AppModel.self) private var model
        @Environment(ThumbnailPrefetcher.self) private var prefetcher
        @State private var hovering = false

        var body: some View {
            let item = model.results.items[assetID]
            let selected = model.isSelected(assetID)
            let focused = focus.wrappedValue == assetID
            let favorite = item?.metadata.isFavorite == true
            let inAlbums = item?.metadata.albumNames.isEmpty == false
            let previewOnly = item?.analysisSource == .cloudPreview || confidence == .lower
            let showsKept = isKeeper && !selected
            let isVideo = item?.metadata.kind.isVideo == true
            let showsControls = hovering || focused || selected
            Thumbnail(assetID: assetID, maxPixels: pixelSize)
                // Only the picture is darkened: the scrim sits under the marks and the chip.
                .overlay {
                    if selected { Color.black.opacity(0.28) }
                }
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    markButton(selected: selected, isVideo: isVideo)
                        .opacity(showsControls ? 1 : 0)
                }
                .overlay(alignment: .topLeading) {
                    ExpandButton(action: onView)
                        .opacity(showsControls ? 1 : 0)
                }
                .overlay(alignment: .bottomLeading) {
                    // At most three parts in the one capsule; the album glyph is the one given up.
                    PhotoChip(
                        keeper: showsKept, favorite: favorite,
                        inAlbums: inAlbums && !(showsKept && favorite && previewOnly),
                        previewOnly: previewOnly
                    )
                    .padding(Space.xs)
                }
                .overlay {
                    // The keyboard focus: a 3 pt ring in the accent, drawn by hand because the
                    // system's own ring is a rectangle that ignores the rounded corners.
                    RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .opacity(focused ? 1 : 0)
                        .allowsHitTesting(false)
                }
                .calmAnimation(value: selected)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
                // Focus, then the keys that act on the focused photo.
                .focusable()
                .focused(focus, equals: assetID)
                .focusEffectDisabled()
                // The double click is declared before the single one, so it is the one that wins.
                .onTapGesture(count: 2) { onView() }
                .simultaneousGesture(TapGesture().onEnded { clicked() })
                .onKeyPress(.space) {
                    model.toggle(assetID)
                    return .handled
                }
                .onKeyPress(.return) {
                    onView()
                    return .handled
                }
                .onMoveCommand { move($0) }
                .onDeleteCommand(perform: onRemove)
                .contextMenu { menu(selected: selected, isVideo: isVideo) }
                .onAppear { prefetcher.appeared(assetID) }
                .onDisappear { prefetcher.disappeared(assetID) }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    ItemCell.description(
                        item: item, isKeeper: isKeeper, confidence: confidence,
                        favorite: favorite, inAlbums: inAlbums)
                )
                .accessibilityValue(ReviewState.text(selected: selected))
                .accessibilityHint(ReviewState.changeHint)
                .accessibilityAddTraits(.isButton)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("category.item.\(assetID)")
                // The VoiceOver press toggles; the click does not, so it has its own action.
                .accessibilityAction(.default) { model.toggle(assetID) }
                .accessibilityAction(named: Text("View full screen"), onView)
                .accessibilityAction(named: Text("Always Keep")) {
                    Task { await model.alwaysKeep(assetID) }
                }
        }

        // MARK: Pointer

        /// The check mark: a click on it toggles removal. 28 pt or more to hit, plain so macOS draws
        /// no bezel around it.
        private func markButton(selected: Bool, isVideo: Bool) -> some View {
            let help: LocalizedStringKey =
                selected
                ? (isVideo ? "Keep This Video" : "Keep This Photo") : "Select for Removal"
            return Button {
                anchor()
                model.toggle(assetID)
            } label: {
                SelectionMark(selected: selected)
                    .padding(Space.xs)
                    .frame(minWidth: 28, minHeight: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(help)
            .padding(Space.xs)
            .accessibilityHidden(true)
        }

        /// A click: it focuses the photo and nothing else. With Command it toggles, with Shift it
        /// selects the range from the last photo touched (never a suggested keeper).
        private func clicked() {
            focus.wrappedValue = assetID
            let flags = NSEvent.modifierFlags
            if flags.contains(.shift) {
                model.setSelected(navigator.plan.range(from: navigator.anchor, to: assetID), true)
            } else if flags.contains(.command) {
                anchor()
                model.toggle(assetID)
            } else {
                anchor()
            }
        }

        private func anchor() { navigator.anchor = assetID }

        // MARK: Keyboard

        /// An arrow key: the neighbour gets the focus, and is scrolled to first, because in a long
        /// list it may not exist yet and a view that does not exist cannot take the focus.
        private func move(_ direction: MoveCommandDirection) {
            guard let step = navigator.plan.step(from: assetID, direction) else { return }
            let next = step.id
            navigator.anchor = next
            navigator.scrollTo?(next, step.groupID)
            focus.wrappedValue = next
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                if focus.wrappedValue != next { focus.wrappedValue = next }
            }
        }

        // MARK: Context menu

        @ViewBuilder private func menu(selected: Bool, isVideo: Bool) -> some View {
            Button("View Larger", action: onView)
            Button("Always Keep") { Task { await model.alwaysKeep(assetID) } }
            Divider()
            if selected {
                if isVideo {
                    Button("Keep This Video") { model.toggle(assetID) }
                } else {
                    Button("Keep This Photo") { model.toggle(assetID) }
                }
            } else {
                Button("Select for Removal") { model.toggle(assetID) }
            }
            if let group, group.members.count > 1 {
                Button("Select the Rest of This Group") {
                    // The photos suggested to keep stay: this is "the rest", not "all".
                    model.setSelected(group.members.filter { !group.keepers.contains($0) }, true)
                }
            }
        }
    }
#endif
