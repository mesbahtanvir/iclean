#if os(macOS)
    import AppKit
    import CleanupKit
    import SwiftUI

    /// Large Videos on a Mac: a native table, the highest-regret list in the app (spec 011 section
    /// 6.15). A checkbox to select a video for removal, a 56 pt preview, then its size (largest
    /// first, which a click on a header changes), length and date.
    ///
    /// Only Large Videos is a table. Duplicate Videos stay grouped, with Compare and Keep This Copy.
    ///
    /// Picking a row (to open it, or to act on it from the context menu) is separate from selecting
    /// it for removal: the checkbox does that, and Space does it for the picked rows. Nothing here
    /// removes anything; Delete only opens the Confirm sheet.
    struct MacVideoTable: View {
        let ids: [String]
        /// The pixels the 56 pt preview needs.
        let pixelSize: Int
        var onView: (String) -> Void
        /// Delete: opens the Confirm sheet when something is selected.
        var onRemove: () -> Void

        @Environment(AppModel.self) private var model
        @State private var sortOrder = [KeyPathComparator(\Row.bytes, order: .reverse)]
        @State private var picked: Set<String> = []

        /// What the table needs of a video, worked out once per draw. A date or a length that the
        /// video does not have sorts first and shows a dash.
        struct Row: Identifiable {
            let id: String
            let bytes: Int64
            let isEstimate: Bool
            let length: Double
            let hasLength: Bool
            let taken: Date
            let hasDate: Bool
        }

        /// The size of a preview, and so of a row.
        static let preview: CGFloat = 56

        var body: some View {
            let rows = ids.compactMap(row).sorted(using: sortOrder)
            Table(rows, selection: $picked, sortOrder: $sortOrder) {
                TableColumn("Remove") { row in
                    checkbox(row)
                }
                .width(56)
                TableColumn("Preview") { row in
                    previewImage(row)
                }
                .width(Self.preview + 12)
                TableColumn("Size", value: \.bytes) { row in
                    // The primary cell of the row: the one the tests and VoiceOver find it by.
                    Text(Format.bytes(row.bytes, estimate: row.isEstimate))
                        .font(.body.weight(.semibold))
                        .monospacedDigit()
                        // What the video is. Whether it goes is the checkbox's, in the cell before.
                        .accessibilityLabel(spoken(row))
                        .accessibilityIdentifier("category.item.\(row.id)")
                }
                .width(min: 90, ideal: 110)
                TableColumn("Length", value: \.length) { row in
                    Text(row.hasLength ? Format.duration(row.length) : "—")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .width(min: 70, ideal: 80)
                TableColumn("Taken", value: \.taken) { row in
                    Text(
                        row.hasDate
                            ? row.taken.formatted(date: .abbreviated, time: .omitted) : "—"
                    )
                    .foregroundStyle(.secondary)
                }
            }
            .environment(\.defaultMinListRowHeight, Self.preview + 8)
            .accessibilityLabel("Large videos")
            .contextMenu(forSelectionType: String.self) { ids in
                menu(ids)
            } primaryAction: { ids in
                // A double click, and Return on the picked rows.
                open(ids)
            }
            // Space has two routes, because a table is a native view that may keep the key: the
            // SwiftUI one here, and the table's own (`TableSpaceKey`). Whichever gets the key uses
            // it up, so the rows are toggled once.
            .onKeyPress(.space, phases: [.down, .repeat]) { press in
                guard !picked.isEmpty else { return .ignored }
                // A held key repeats: only the first press toggles the picked rows.
                if !press.isRepeat { _ = togglePicked() }
                return .handled
            }
            .onKeyPress(.return, phases: [.down, .repeat]) { press in
                guard !picked.isEmpty else { return .ignored }
                if !press.isRepeat { open(picked) }
                return .handled
            }
            .onDeleteCommand(perform: onRemove)
            .background { TableSpaceKey { togglePicked() } }
        }

        /// Space: marks the picked rows for removal, or, when they all are, keeps them. Nothing
        /// happens without a picked row.
        private func togglePicked() -> Bool {
            guard !picked.isEmpty else { return false }
            let all = picked.allSatisfy { model.isSelected($0) }
            model.setSelected(Array(picked), !all)
            return true
        }

        // MARK: Cells

        private func checkbox(_ row: Row) -> some View {
            Toggle(
                isOn: Binding(
                    get: { model.isSelected(row.id) },
                    set: { _ in model.toggle(row.id) })
            ) {
                Text("Select for Removal")
            }
            .labelsHidden()
            .toggleStyle(.checkbox)
            .help("Select for Removal")
            // It names the video, so a row read from its checkbox says which one it is; the state is
            // the checkbox's own value.
            .accessibilityLabel("Remove, \(spoken(row))")
        }

        private func previewImage(_ row: Row) -> some View {
            Thumbnail(assetID: row.id, maxPixels: pixelSize)
                .frame(width: Self.preview, height: Self.preview)
                .clipShape(RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
                .padding(.vertical, Space.xs)
                .accessibilityHidden(true)
        }

        // MARK: Actions

        @ViewBuilder private func menu(_ ids: Set<String>) -> some View {
            if !ids.isEmpty {
                Button("View Larger") { open(ids) }
                Button("Always Keep") {
                    Task { for id in ids { await model.alwaysKeep(id) } }
                }
                Divider()
                if ids.allSatisfy({ model.isSelected($0) }) {
                    Button(ids.count == 1 ? "Keep This Video" : "Keep These Videos") {
                        model.setSelected(Array(ids), false)
                    }
                } else {
                    Button("Select for Removal") { model.setSelected(Array(ids), true) }
                }
            }
        }

        private func open(_ ids: Set<String>) {
            // The first of them in the order the table shows.
            if let id = self.ids.first(where: ids.contains) { onView(id) }
        }

        // MARK: Data

        private func row(_ id: String) -> Row? {
            guard let item = model.results.items[id] else { return nil }
            return Row(
                id: id, bytes: item.effectiveByteSize, isEstimate: item.sizeIsEstimate,
                length: item.metadata.duration ?? 0, hasLength: item.metadata.duration != nil,
                taken: item.metadata.captureDate ?? .distantPast,
                hasDate: item.metadata.captureDate != nil)
        }

        /// "Video, 5 minutes, 900 MB, Mar 3, 2024": what it is, not whether it goes.
        private func spoken(_ row: Row) -> String {
            var parts = [ItemKind.video.spokenName]
            if row.hasLength { parts.append(Format.durationSpoken(row.length)) }
            parts.append(Format.bytes(row.bytes, estimate: row.isEstimate))
            if row.hasDate { parts.append(row.taken.formatted(date: .abbreviated, time: .omitted)) }
            return parts.joined(separator: ", ")
        }
    }

    /// Space on the table's own keyboard, for when the table keeps the key from SwiftUI.
    ///
    /// A local key monitor sees a key before the window dispatches it. It takes Space only when the
    /// first responder is a table over this view (this is put behind the table), so a text field, a
    /// checkbox cell that has the keyboard, or any other window is never affected. Held keys are
    /// used up and do nothing, as everywhere: only the first press toggles.
    private struct TableSpaceKey: NSViewRepresentable {
        /// Acts on the picked rows; false when there were none, and the key is then left alone.
        let action: @MainActor () -> Bool

        func makeNSView(context: Context) -> Probe { Probe() }

        func updateNSView(_ view: Probe, context: Context) { view.action = action }

        static func dismantleNSView(_ view: Probe, coordinator: ()) { view.stop() }

        final class Probe: NSView {
            var action: (@MainActor () -> Bool)?
            private var monitor: Any?

            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                stop()
                guard window != nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
                    [weak self] event in
                    // Monitors run on the main thread, in the middle of the event loop.
                    let taken = MainActor.assumeIsolated { self?.takes(event) ?? false }
                    return taken ? nil : event
                }
            }

            func stop() {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }

            @MainActor private func takes(_ event: NSEvent) -> Bool {
                let plain = event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty
                guard event.keyCode == 49, plain, let window, event.window === window,
                    let table = window.firstResponder as? NSTableView,
                    convert(bounds, to: nil).intersects(table.convert(table.visibleRect, to: nil))
                else { return false }
                if event.isARepeat { return true }
                return action?() ?? false
            }
        }
    }
#endif
