#if os(macOS)
    import CleanupKit
    import SwiftUI

    /// The copies of a group side by side (spec 009 section 6.15): up to four in a row, and when there
    /// are more, further rows of the same. A grid lines up the rows that matter across the copies:
    /// the photos, then Taken, Dimensions and Size, then the verdict and the Remove checkbox.
    ///
    /// Left and Right move between the copies, Space toggles the one the keyboard is on, and Return
    /// looks at it. The checkbox is the control; the photo opens the viewer.
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
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        copies(row, layout: layout, pixels: pixels)
                    }
                }
                .padding(Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .focusable()
            .focused($hasFocus)
            .focusEffectDisabled()
            .onMoveCommand { move($0, in: members) }
            .onKeyPress(.space) {
                guard let current else { return .ignored }
                model.toggle(current)
                return .handled
            }
            .onKeyPress(.return) {
                guard let current else { return .ignored }
                onView(current)
                return .handled
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
                row(nil, ids, [.photo], photo: photo, pixels: pixels)
                row("Taken", ids, [.taken], photo: photo, pixels: pixels)
                row("Dimensions", ids, [.dimensions], photo: photo, pixels: pixels)
                row("Size", ids, [.size], photo: photo, pixels: pixels)
                row(nil, ids, [.status], photo: photo, pixels: pixels)
                row(nil, ids, [.toggle], photo: photo, pixels: pixels)
                row(nil, ids, [.notes], photo: photo, pixels: pixels)
            }
        }

        private func row(
            _ label: LocalizedStringKey?, _ ids: [String], _ parts: Set<CompareCard.Part>,
            photo: CGSize, pixels: Int
        ) -> some View {
            GridRow {
                if let label {
                    Text(label)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: Self.labelWidth, alignment: .leading)
                } else {
                    Color.clear.frame(width: Self.labelWidth, height: 1)
                }
                ForEach(ids, id: \.self) { id in
                    CompareCard(
                        group: group, assetID: id, index: group.members.firstIndex(of: id) ?? 0,
                        photoSize: photo, pixelSize: pixels, slotHeight: slotHeight,
                        onView: {
                            current = id
                            onView(id)
                        },
                        parts: parts, fixedWidth: photo.width,
                        ringed: hasFocus && current == id)
                }
            }
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
#endif
