#if os(macOS)
    import CleanupKit
    import SwiftUI

    /// The copies of a group side by side (spec 009 section 6.15): up to four in a row, and when there
    /// are more, further rows of the same. A grid lines up the rows that matter across the copies:
    /// the photos, then Taken, Dimensions and Size, then the verdict and the Remove checkbox.
    ///
    /// The rows of copies are in a lazy stack and each is a Grid of its own, so a group of many
    /// copies builds (and asks for the pictures of) the rows near the screen only, and the facts
    /// still line up across the copies of a row.
    ///
    /// Left and Right move between the copies, Space toggles the one the keyboard is on, and Return
    /// looks at it. The checkbox is the control; the photo opens the viewer.
    ///
    /// VoiceOver reads one copy at a time, in the order of the copies and not of the grid's rows:
    /// the photo, then one line with its Taken, Dimensions and Size, then the verdict, the checkbox
    /// and the date notes.
    struct MacCompareGrid: View {
        let group: ResultGroup
        /// The width of the pane, from which the copies' widths are taken.
        let width: CGFloat
        /// The shape of every photo of the group.
        let ratio: CGFloat
        /// Every copy's verdict slot has this height, so the checkboxes line up.
        let slotHeight: CGFloat
        let displayScale: CGFloat
        let onView: (String) -> Void

        @Environment(AppModel.self) private var model
        /// The copy the keyboard is on.
        @State private var current: String?
        @FocusState private var hasFocus: Bool

        private static let labelWidth: CGFloat = 84
        private static let gap: CGFloat = Space.l
        /// Beyond four copies the rows wrap, with each copy at least this wide and at most the second.
        private static let wrapMinimum: CGFloat = 240
        private static let wrapMaximum: CGFloat = 420

        var body: some View {
            let members = group.members
            let layout = self.layout(count: members.count)
            let rows = stride(from: 0, to: members.count, by: layout.columns).map {
                Array(members[$0..<min($0 + layout.columns, members.count)])
            }
            let pixels = GridMetrics.pixels(
                width: Double(layout.cardWidth), minimum: Double(layout.cardWidth), spacing: 0,
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
                }
                .focusable()
                .focused($hasFocus)
                .focusEffectDisabled()
                .onMoveCommand { move($0, in: members) }
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
                // The copy the keyboard moved to may be in a row that is not built yet.
                .onChange(of: current) { _, new in
                    guard let new, let index = members.firstIndex(of: new) else { return }
                    proxy.scrollTo(index / layout.columns)
                }
                .onAppear {
                    // Left and Right work as soon as the screen is open.
                    if current == nil {
                        current =
                            model.restoredFocus.flatMap { id in
                                members.contains(id) ? id : nil
                            } ?? members.first
                    }
                    hasFocus = true
                }
            }
        }

        // MARK: Layout

        private struct Metrics {
            let columns: Int
            let cardWidth: CGFloat
        }

        /// Up to four copies share the row; more wrap in rows of as many as are wide enough.
        private func layout(count: Int) -> Metrics {
            let available = max(
                width - 2 * Space.l - Self.labelWidth - Self.gap, Self.wrapMinimum)
            if count <= 4 {
                let columns = max(count, 1)
                let card = (available - Self.gap * CGFloat(columns - 1)) / CGFloat(columns)
                return Metrics(columns: columns, cardWidth: max(card, 120))
            }
            let fit = Int((available + Self.gap) / (Self.wrapMinimum + Self.gap))
            let columns = min(max(fit, 2), 4)
            let card = (available - Self.gap * CGFloat(columns - 1)) / CGFloat(columns)
            return Metrics(
                columns: columns, cardWidth: min(max(card, Self.wrapMinimum), Self.wrapMaximum))
        }

        /// One row of copies: a grid, so Taken, Dimensions and Size sit at one height across them.
        private func copies(_ ids: [String], layout: Metrics, pixels: Int) -> some View {
            let photo = CGSize(width: layout.cardWidth, height: layout.cardWidth / ratio)
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
                    onView(id)
                },
                parts: [part], fixedWidth: photo.width,
                ringed: hasFocus && current == id
            )
            .modifier(CopyAccessibility(group: group, assetID: id, part: part))
        }

        // MARK: Keyboard

        private func move(_ direction: MoveCommandDirection, in members: [String]) {
            guard !members.isEmpty else { return }
            let i = current.flatMap { members.firstIndex(of: $0) } ?? 0
            switch direction {
            case .left: current = members[max(i - 1, 0)]
            case .right: current = members[min(i + 1, members.count - 1)]
            default: break
            }
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
