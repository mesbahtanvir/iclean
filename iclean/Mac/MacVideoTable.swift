#if os(macOS)
    import CleanupKit
    import SwiftUI

    /// Large Videos on a Mac: a native table, the highest-regret list in the app (spec 009 section
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
            .contextMenu(forSelectionType: String.self) { ids in
                menu(ids)
            } primaryAction: { ids in
                open(ids)
            }
            .onKeyPress(.space) {
                guard !picked.isEmpty else { return .ignored }
                let all = picked.allSatisfy { model.isSelected($0) }
                model.setSelected(Array(picked), !all)
                return .handled
            }
            .onKeyPress(.return) {
                guard !picked.isEmpty else { return .ignored }
                open(picked)
                return .handled
            }
            .onDeleteCommand(perform: onRemove)
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

        /// "Video, 5 minutes, 900 MB, Mar 3, 2024, selected for removal".
        private func spoken(_ row: Row) -> String {
            var parts = [ItemKind.video.spokenName]
            if row.hasLength { parts.append(Format.durationSpoken(row.length)) }
            parts.append(Format.bytes(row.bytes, estimate: row.isEstimate))
            if row.hasDate { parts.append(row.taken.formatted(date: .abbreviated, time: .omitted)) }
            parts.append(ReviewState.text(selected: model.isSelected(row.id)))
            return parts.joined(separator: ", ")
        }
    }
#endif
