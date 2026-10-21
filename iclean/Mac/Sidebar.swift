#if os(macOS)
    import CleanupKit
    import SwiftUI

    /// What the sidebar can point at: the Overview, or one category.
    enum SidebarItem: Hashable {
        case overview
        case category(CleanupCategory)
    }

    /// The Mac's list of places (spec 009 section 6.15): "Overview", then a "Cleanup" section of the
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
            .safeAreaInset(edge: .bottom, spacing: 0) { SidebarFooter() }
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
            .badge(figure.map { Text(Format.bytes($0.bytes, estimate: $0.isEstimate)) })
            .accessibilityLabel(spokenLabel(tally: tally, figure: figure))
        }

        private func spokenLabel(tally: CategoryTally?, figure: CategoryRow.Figure?) -> String {
            guard let tally, let figure else { return category.title }
            let size = SpokenBytes.string(figure.bytes, estimate: figure.isEstimate)
            return "\(category.title), \(size), \(CategoryRow.detail(tally))"
        }
    }

    /// Under the list: newer results waiting, the review to continue, and the scan. While scanning it
    /// is the thin bar with the count and one line of note; otherwise "Scanned 3 minutes ago" with a
    /// quiet Scan Again, or Resume Scan after a scan was cut off.
    struct SidebarFooter: View {
        @Environment(AppModel.self) private var model

        var body: some View {
            let hasResults = !model.results.categories.isEmpty
            let idle = !model.isScanning && !model.isFinishing && !model.hasInterruptedScan
            // While there is nothing to show in the detail pane yet, the scan card is there, so it
            // is not drawn twice.
            let showsScan = model.isScanning && hasResults
            let isEmpty =
                model.pendingNewCount == 0 && model.continueRoute.isEmpty && !showsScan
                && !model.hasInterruptedScan && !idle
            if !isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Divider()
                    VStack(alignment: .leading, spacing: Space.s) {
                        if model.pendingNewCount > 0 { ShowNewItemsRow() }
                        if !model.continueRoute.isEmpty { ContinueReviewingRow() }
                        if showsScan {
                            ScanningView(showsControls: false)
                        } else if model.hasInterruptedScan {
                            ResumeScanRow()
                        } else if idle {
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
