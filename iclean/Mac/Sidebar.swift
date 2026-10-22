#if os(macOS)
    import CleanupKit
    import SwiftUI

    /// What the sidebar can point at: the Overview, or one category.
    enum SidebarItem: Hashable {
        case overview
        case category(CleanupCategory)
    }

    /// The Mac's list of places (spec 012 section 6.15): "Overview", then a "Cleanup" section of the
    /// categories with their sizes as native badges, and the quiet scan state in the footer. It reads
    /// only cached numbers: no photo is drawn here.
    struct Sidebar: View {
        @Binding var selection: SidebarItem?

        @Environment(AppModel.self) private var model

        var body: some View {
            List(selection: $selection) {
                Label {
                    Text("Overview")
                } icon: {
                    Image(systemName: "square.grid.2x2").foregroundStyle(.secondary)
                }
                .tag(SidebarItem.overview)
                .accessibilityIdentifier("sidebar.overview")
                Section {
                    // The categories keep their fixed order, so rows never reshuffle.
                    ForEach(model.results.categories) { result in
                        SidebarCategoryRow(category: result.category)
                            .tag(SidebarItem.category(result.category))
                            .accessibilityIdentifier("sidebar.category.\(result.category.rawValue)")
                    }
                } header: {
                    Text("Cleanup")
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // The Overview shows "Continue reviewing" and "Show N new items" itself, so they
                // are not drawn twice in one window.
                SidebarFooter(
                    overviewShowing: selection == .overview && !model.results.categories.isEmpty)
            }
        }
    }

    /// One category: a quiet icon, its name, and its size as a badge. The size is what is selected in
    /// it, or what could be removed when nothing is, the same figure the Overview row shows.
    private struct SidebarCategoryRow: View {
        let category: CleanupCategory

        @Environment(AppModel.self) private var model

        var body: some View {
            let tally = model.summary.perCategory[category]
            let figure = tally.map(CategoryRow.figure)
            Label {
                Text(category.title)
            } icon: {
                // The system's label style is kept so the titles line up; the icon is a hint.
                Image(systemName: category.systemImage).foregroundStyle(.secondary)
            }
            .badge(figure.map { badge(for: $0) })
            .accessibilityLabel(spokenLabel(tally: tally, figure: figure))
        }

        /// The selected size, or with nothing selected what could be freed: "up to 933 MB", so a figure
        /// never reads as a selection.
        private func badge(for figure: CategoryRow.Figure) -> Text {
            let size = Format.bytes(figure.bytes, estimate: figure.isEstimate)
            return figure.isSelection ? Text(size) : Text("up to \(size)")
        }

        private func spokenLabel(tally: CategoryTally?, figure: CategoryRow.Figure?) -> String {
            guard let tally, let figure else { return category.title }
            let detail = CategoryRow.detail(tally)
            if figure.isSelection {
                let size = SpokenBytes.string(figure.bytes, estimate: figure.isEstimate)
                return "\(category.title), \(size), \(detail)"
            }
            let size = SpokenBytes.string(figure.bytes)
            return String(localized: "\(category.title), \(detail), up to \(size) could be freed")
        }
    }

    /// Under the list: newer results waiting, the review to continue, and the scan. While scanning it
    /// is the thin bar with the count and one line of note; otherwise "Scanned 3 minutes ago" with a
    /// quiet Scan Again, or Resume Scan after a scan was cut off.
    ///
    /// What can be started comes from `MacScanAction`, the phone's Home states, so the footer never
    /// offers a scan while the saved data is opening or being built.
    struct SidebarFooter: View {
        /// The Overview is in the detail pane, and it shows the review to continue and the newer
        /// results waiting; they are left out here so they are not there twice.
        let overviewShowing: Bool

        @Environment(AppModel.self) private var model

        var body: some View {
            let hasResults = !model.results.categories.isEmpty
            let action = MacScanAction.current(model)
            // While there is nothing to show in the detail pane yet, the scan card is there, so it
            // is not drawn twice.
            let showsScan = model.isScanning && hasResults
            let showsNew = model.pendingNewCount > 0 && !overviewShowing
            let showsContinue = !model.continueRoute.isEmpty && !overviewShowing
            let isEmpty = !showsNew && !showsContinue && !showsScan && action == nil
            if !isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Divider()
                    VStack(alignment: .leading, spacing: Space.s) {
                        if showsNew { ShowNewItemsRow() }
                        if showsContinue { MacContinueRow() }
                        if showsScan {
                            ScanningView(showsControls: false)
                        } else if action == .resume {
                            ResumeScanRow()
                        } else if action != nil {
                            ScanAgainLine(stacked: true)
                        }
                    }
                    .padding(.horizontal, Space.m)
                    .padding(.vertical, Space.s)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)
            }
        }
    }
#endif
