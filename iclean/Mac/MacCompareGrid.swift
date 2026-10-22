#if os(macOS)
    import CleanupKit
    import SwiftUI

    /// The copies of a group side by side (spec 009 section 6.15): up to four in a row, and when there
    /// are more, or the pane is narrow, further rows of the same. A grid lines up the rows that
    /// matter across the copies: the photos, then Taken, Dimensions and Size, then the verdict and
    /// the Remove checkbox.
    ///
    /// The rows of copies are in a lazy stack and each is a Grid of its own, so a group of many
    /// copies builds (and asks for the pictures of) the rows near the screen only, and the facts
    /// still line up across the copies of a row.
    ///
    /// A photo is never taller than the window leaves room for: the Remove checkbox and Keep This
    /// Copy are under it, and they must be on screen with it. A row is as many copies as fit the
    /// width of the scroll view's content, however narrow, so the last copy is never cut off.
    ///
    /// The arrow keys move between the copies (Left and Right along a row, Up and Down by a row),
    /// Space toggles the one the keyboard is on, Return looks at it and Escape goes back. The
    /// checkbox is the control; the photo opens the viewer.
    ///
    /// VoiceOver reads one copy at a time, in the order of the copies and not of the grid's rows:
    /// the photo, then one line with its Taken, Dimensions and Size, then the verdict, the checkbox
    /// and the date notes.
    struct MacCompareGrid: View {
        let group: ResultGroup
        /// The width of the pane, which the copies' widths are taken from until the grid has
        /// measured its own (a legacy scroll bar takes some of the pane's).
        let width: CGFloat
        /// The shape of every photo of the group.
        let ratio: CGFloat
        /// Every copy's verdict slot has this height, so the checkboxes line up.
        let slotHeight: CGFloat
        let displayScale: CGFloat
        let onView: (String) -> Void
        /// Delete: opens the Confirm sheet when something is selected. It removes nothing.
        let onRemove: () -> Void

        @Environment(AppModel.self) private var model
        /// The copy the keyboard is on.
        @State private var current: String?
        @FocusState private var hasFocus: Bool
        /// What the scroll view really has: the width of its content and the height it shows.
        @State private var contentWidth: CGFloat?
        @State private var viewportHeight: CGFloat = 0

        private static let labelWidth: CGFloat = 84
        private static let gap: CGFloat = Space.l
        /// A copy is never narrower than this: its facts ("Nov 15, 2023 at 2:14 PM") need it.
        private static let narrowest: CGFloat = 140
        /// Beyond four copies the rows wrap, with each copy at least this wide and at most the second.
        private static let wrapMinimum: CGFloat = 240
        private static let wrapMaximum: CGFloat = 420
        /// The least a photo is tall, in a window too short to leave it more.
        private static let shortest: CGFloat = 240

        var body: some View {
            let members = group.members
            let layout = self.layout(count: members.count)
            let rows = stride(from: 0, to: members.count, by: layout.columns).map {
                Array(members[$0..<min($0 + layout.columns, members.count)])
            }
            let pixels = GridMetrics.pixels(
                width: Double(layout.photo.width), minimum: Double(layout.photo.width), spacing: 0,
                scale: Double(displayScale), cap: 1024)
            ScrollViewReader { proxy in
                ScrollView {
                    // Lazy: only the rows that are near the screen are built.
                    LazyVStack(alignment: .leading, spacing: Space.xl) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                            copies(row, layout: layout, pixels: pixels).id(index)
                        }
                    }
                    .padding(Space.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Measured on the content, which is narrower than the pane when the scroll view
                    // shows a legacy scroll bar.
                    .onGeometryChange(for: CGFloat.self) {
                        $0.size.width
                    } action: {
                        contentWidth = $0
                    }
                }
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.height
                } action: {
                    viewportHeight = $0
                }
                .focusable()
                .focused($hasFocus)
                .focusEffectDisabled()
                .onMoveCommand { move($0, in: members, columns: layout.columns) }
                .onKeyPress(.space, phases: [.down, .repeat]) { press in
                    guard let current else { return .ignored }
                    // A held key repeats: only the first press toggles.
                    if !press.isRepeat { model.toggle(current) }
                    return .handled
                }
                .onKeyPress(.return, phases: [.down, .repeat]) { press in
                    guard let current else { return .ignored }
                    if !press.isRepeat { onView(current) }
                    return .handled
                }
                // Back to the category, from the keyboard.
                .onExitCommand {
                    if !MacNavigation.shared.groupPath.isEmpty {
                        MacNavigation.shared.groupPath.removeLast()
                    }
                }
                .onDeleteCommand(perform: onRemove)
                // The copy the keyboard moved to may be in a row that is not built yet.
                .onChange(of: current) { _, new in
                    guard let new, let index = members.firstIndex(of: new) else { return }
                    proxy.scrollTo(index / layout.columns)
                }
                .onAppear {
                    // The arrow keys work as soon as the screen is open.
                    if current == nil {
                        current =
                            model.restoredFocus.flatMap { id in
                                members.contains(id) ? id : nil
                            } ?? members.first
                    }
                    hasFocus = true
                }
                // A focus asked for while the screen is still being pushed on is often dropped, so it
                // is asked for again once the push has settled.
                .task {
                    try? await Task.sleep(for: .milliseconds(150))
                    if !hasFocus { hasFocus = true }
                }
            }
        }

        // MARK: Layout

        private struct Metrics {
            let columns: Int
            /// The size of every photo of the group.
            let photo: CGSize
            /// How far the rows are moved in from the left, to keep them in the middle of a pane
            /// that is wider than they are.
            let inset: CGFloat
        }

        /// As many copies in a row as fit the width: up to four, and each at least `narrowest` wide
        /// (`wrapMinimum` when there are more than four). The photo is the card's width and as tall
        /// as that gives, but no taller than the window leaves room for, keeping its shape; the rows
        /// are then as wide as their photos.
        private func layout(count: Int) -> Metrics {
            let content = contentWidth ?? width
            let available = max(content - 2 * Space.l - Self.labelWidth - Self.gap, 1)
            let smallest = count <= 4 ? Self.narrowest : Self.wrapMinimum
            let fit = max(Int((available + Self.gap) / (smallest + Self.gap)), 1)
            let columns = max(min(count, 4, fit), 1)
            var card = (available - Self.gap * CGFloat(columns - 1)) / CGFloat(columns)
            if count > 4 { card = min(card, Self.wrapMaximum) }
            card = max(card, 1)
            let photoWidth = min(card, maxPhotoHeight * ratio)
            let photo = CGSize(width: photoWidth, height: photoWidth / ratio)
            let row = Self.labelWidth + CGFloat(columns) * (Self.gap + photo.width)
            return Metrics(
                columns: columns, photo: photo,
                inset: max(0, (content - 2 * Space.l - row) / 2))
        }

        /// The tallest a photo may be: the window shows the photo and the rows under it, down to the
        /// Remove checkbox, with the room the facts, the verdict slot and the spacing take.
        private var maxPhotoHeight: CGFloat {
            guard viewportHeight > 0 else { return .infinity }
            // Three facts, the verdict slot, the checkbox, six gaps and the padding above and below.
            let underneath = 3 * 22 + slotHeight + 24 + 6 * Space.s + 2 * Space.l
            return max(Self.shortest, viewportHeight - underneath - Space.m)
        }

        /// One row of copies: a grid, so Taken, Dimensions and Size sit at one height across them.
        private func copies(_ ids: [String], layout: Metrics, pixels: Int) -> some View {
            let photo = layout.photo
            return Grid(
                alignment: .topLeading, horizontalSpacing: Self.gap, verticalSpacing: Space.s
            ) {
                row(nil, ids, .photo, photo: photo, pixels: pixels)
                row("Taken", ids, .taken, photo: photo, pixels: pixels)
                row("Dimensions", ids, .dimensions, photo: photo, pixels: pixels)
                row("Size", ids, .size, photo: photo, pixels: pixels)
                row(nil, ids, .status, photo: photo, pixels: pixels)
                row(nil, ids, .toggle, photo: photo, pixels: pixels)
                row(nil, ids, .notes, photo: photo, pixels: pixels)
            }
            .padding(.leading, layout.inset)
        }

        private func row(
            _ label: LocalizedStringKey?, _ ids: [String], _ part: CompareCard.Part,
            photo: CGSize, pixels: Int
        ) -> some View {
            GridRow {
                if let label {
                    Text(label)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: Self.labelWidth, alignment: .leading)
                        // Each copy's facts say what they are, so the row names are not read.
                        .accessibilityHidden(true)
                } else {
                    Color.clear.frame(width: Self.labelWidth, height: 1)
                }
                ForEach(ids, id: \.self) { id in
                    cell(id, part, photo: photo, pixels: pixels)
                }
            }
        }

        private func cell(_ id: String, _ part: CompareCard.Part, photo: CGSize, pixels: Int)
            -> some View
        {
            CompareCard(
                group: group, assetID: id, index: group.members.firstIndex(of: id) ?? 0,
                photoSize: photo, pixelSize: pixels, slotHeight: slotHeight,
                onView: {
                    current = id
                    hasFocus = true
                    onView(id)
                },
                parts: [part], fixedWidth: photo.width,
                ringed: hasFocus && current == id,
                // A click on the checkbox or Keep This Copy does not take the keyboard by itself:
                // it is taken here, so the ring and the keys follow the pointer.
                onTouch: {
                    current = id
                    hasFocus = true
                }
            )
            .modifier(CopyAccessibility(group: group, assetID: id, part: part))
        }

        // MARK: Keyboard

        /// An arrow key: along the row with Left and Right, by a row with Up and Down (the copy under
        /// or over this one, or the end of a shorter last row; nothing past the first or last row).
        private func move(_ direction: MoveCommandDirection, in members: [String], columns: Int) {
            guard !members.isEmpty else { return }
            let plan = GridPlan(sections: [members], groupIDs: nil, columns: columns, keepers: [])
            if let step = plan.step(from: current ?? "", direction) { current = step.id }
        }
    }

    /// How one cell of the grid is read by VoiceOver. The grid is laid out in rows, but a person
    /// compares copies, so the cells are put in the order of the copies (a higher sort priority is
    /// read first), and a copy's Taken, Dimensions and Size are one element that names the copy.
    private struct CopyAccessibility: ViewModifier {
        let group: ResultGroup
        let assetID: String
        let part: CompareCard.Part

        @Environment(AppModel.self) private var model

        func body(content: Content) -> some View {
            let index = group.members.firstIndex(of: assetID) ?? 0
            // Ten places per copy; the first copy is read first.
            let base = Double(group.members.count - index) * 10
            switch part {
            case .taken:
                content
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(facts)
                    .accessibilitySortPriority(base - 1)
            case .dimensions, .size:
                // Said by the copy's one line of facts.
                content.accessibilityHidden(true)
            case .photo:
                content.accessibilitySortPriority(base)
            case .status:
                content.accessibilitySortPriority(base - 2)
            case .toggle:
                content.accessibilitySortPriority(base - 3)
            case .notes, .facts:
                content.accessibilitySortPriority(base - 4)
            }
        }

        /// "Photo 2 of 3, taken Nov 15, 2023 at 2:14 PM, 4,032 by 3,024 pixels, 3.2 megabytes".
        private var facts: String {
            let item = model.results.items[assetID]
            let index = group.members.firstIndex(of: assetID) ?? 0
            let name = item?.metadata.kind.spokenName ?? ItemKind.photo.spokenName
            var parts = [
                String(localized: "\(name) \(index + 1) of \(group.members.count)")
            ]
            if let date = item?.metadata.captureDate {
                parts.append(String(localized: "taken \(Format.capture(date))"))
            } else {
                parts.append(String(localized: "no date"))
            }
            if let item {
                let m = item.metadata
                let width = m.pixelWidth.formatted()
                let height = m.pixelHeight.formatted()
                parts.append(String(localized: "\(width) by \(height) pixels"))
                parts.append(
                    SpokenBytes.string(item.effectiveByteSize, estimate: item.sizeIsEstimate))
                if let length = m.duration { parts.append(Format.durationSpoken(length)) }
            }
            return parts.joined(separator: ", ")
        }
    }
#endif
