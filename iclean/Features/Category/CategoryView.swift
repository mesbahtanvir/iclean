import CleanupKit
import SwiftUI

/// Items or groups in one category, with selection toggles (spec 009 6.5 and 6.6).
///
/// The body reads the results and never the selection: the bottom bar, the toolbar button and the
/// summary line are their own views reading `model.summary`, and every photo reads its own state, so
/// a toggle does not run this body again.
struct CategoryView: View {
    let category: CleanupCategory

    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.displayScale) private var displayScale
    @State private var showConfirm = false
    @State private var viewing: String?
    /// Warms the pictures just ahead of the scroll.
    @State private var prefetcher = ThumbnailPrefetcher()
    /// The width of the scroll view: the columns, and so the pixels each picture needs, come from it.
    @State private var width: CGFloat = 0

    /// How the entries are laid out.
    private enum Layout { case videoList, flatGrid, groups }

    var body: some View {
        let result = model.results.category(category)
        // Hoisted once per body: the flat list of ids is a flatMap over every group.
        let members = result?.allMembers ?? []
        let layout: Layout =
            category == .largeVideos
            ? .videoList : (result?.groups.first?.type == .single ? .flatGrid : .groups)
        ScrollViewReader { proxy in
            ScrollView {
                // Lazy: a library with thousands of groups must not build them all when it opens.
                LazyVStack(alignment: .leading, spacing: Space.xl) {
                    intro(result, layout: layout)
                    if let result {
                        if width > 0 {
                            content(result, members: members, layout: layout)
                        }
                    } else if model.launchPhase != .ready || model.isBuildingResults {
                        // Results are still being restored or built: never say "nothing" before they are.
                        DelayedProgress()
                            .accessibilityIdentifier("category.loading")
                    } else {
                        ContentUnavailableView {
                            Label("All Clear", systemImage: "checkmark.circle")
                        } description: {
                            Text("Nothing left to review here.")
                        }
                    }
                    if typeSize.isAccessibilitySize, result != nil {
                        CategoryBarDetail(category: category)
                    }
                }
                .padding(.vertical, Space.l)
            }
            .onGeometryChange(for: CGFloat.self) {
                $0.size.width
            } action: {
                width = $0
            }
            // A restored screen opens on the photo the person last touched.
            .onAppear { scrollToRestoredPhoto(proxy, in: result, layout: layout) }
            // Not `allMembers.count`: that builds the whole list of ids each time the body runs.
            .onChange(of: result?.groups.count) {
                scrollToRestoredPhoto(proxy, in: result, layout: layout)
            }
            // The groups and cells are built once the width is known, which is after the screen
            // appeared: the first attempt above had nothing to scroll to.
            .onChange(of: width > 0) { _, known in
                guard known else { return }
                Task {
                    try? await Task.sleep(for: .milliseconds(80))
                    scrollToRestoredPhoto(proxy, in: result, layout: layout)
                }
            }
        }
        .environment(prefetcher)
        .task(id: PrefetchKey(count: members.count, pixels: pixelSize(layout))) {
            prefetcher.use(
                library: model.environment.library, ids: members, pixelSize: pixelSize(layout))
        }
        .onDisappear { prefetcher.stopAll() }
        .navigationTitle(category.title)
        #if os(iOS)
            // At accessibility sizes the title, the back button and "Select All Videos" cannot
            // share one line, so the title gets its own.
            .navigationBarTitleDisplayMode(typeSize.isAccessibilitySize ? .large : .inline)
        #endif
        .task { await model.measureSizes(in: category) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { SelectSuggestedButton(category: category) }
        }
        .pinnedBar(isPresented: true) {
            CategoryRemoveBar(category: category) { showConfirm = true }
        }
        .sheet(isPresented: $showConfirm) { ConfirmSheet(category: category) }
        .photoViewer($viewing)
    }

    // MARK: Sizes

    private struct PrefetchKey: Equatable {
        let count: Int
        let pixels: Int
    }

    /// The smallest a photo may be: wider on a Mac and at accessibility sizes, so a cell stays
    /// large enough for its glyphs.
    private var columnMinimum: CGFloat {
        #if os(macOS)
            150
        #else
            typeSize.isAccessibilitySize ? 150 : 104
        #endif
    }

    private var pixelCap: Int {
        #if os(macOS)
            768
        #else
            512
        #endif
    }

    /// The pixels each picture needs, from the real width of a cell (`GridMetrics`).
    private func pixelSize(_ layout: Layout) -> Int {
        switch layout {
        case .videoList:
            // A 72 pt preview.
            return GridMetrics.pixels(
                width: VideoRow.previewSide, minimum: VideoRow.previewSide, spacing: 0,
                scale: displayScale, cap: pixelCap)
        case .flatGrid, .groups:
            guard width > 0 else { return 256 }
            return GridMetrics.pixels(
                width: width, minimum: columnMinimum, spacing: Gutter.grid, scale: displayScale,
                cap: pixelCap)
        }
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: columnMinimum), spacing: Gutter.grid)]
    }

    // MARK: Content

    /// Two lines above the photos, at the 16 pt gutter: what the default is, and how much there is.
    private func intro(_ result: CategoryResult?, layout: Layout) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text(category.explanation)
                .font(.subheadline)
                .padding(.horizontal, Space.l)
            if let result {
                CategorySummaryLine(
                    category: category, count: result.groups.count, isGrouped: layout == .groups)
            }
            if model.pendingNewCount > 0 {
                // The list never changes under the person; new finds wait behind this (004 FR-010).
                Button {
                    model.showPendingResults()
                } label: {
                    Label {
                        Text("Show ^[\(model.pendingNewCount) new item](inflect: true)")
                    } icon: {
                        Image(systemName: "arrow.down.circle")
                    }
                }
                .buttonStyle(.bordered)
                .padding(.horizontal, Space.l)
                .padding(.top, Space.xs)
                .accessibilityIdentifier("category.showNew")
            }
        }
    }

    @ViewBuilder private func content(
        _ result: CategoryResult, members: [String], layout: Layout
    ) -> some View {
        let pixels = pixelSize(layout)
        switch layout {
        case .videoList:
            LazyVStack(spacing: 0) {
                ForEach(members, id: \.self) { id in
                    VideoRow(assetID: id, pixelSize: pixels) { viewing = id }
                }
            }
        case .flatGrid:
            LazyVGrid(columns: columns, spacing: Gutter.grid) {
                ForEach(members, id: \.self) { cell($0, group: nil, pixels: pixels) }
            }
        case .groups:
            ForEach(result.groups) { group in
                VStack(alignment: .leading, spacing: Space.s) {
                    GroupHeader(category: category, group: group)
                    LazyVGrid(columns: columns, spacing: Gutter.grid) {
                        ForEach(group.members, id: \.self) {
                            cell($0, group: group, pixels: pixels)
                        }
                    }
                }
            }
        }
    }

    private func cell(_ id: String, group: ResultGroup?, pixels: Int) -> some View {
        ItemCell(
            assetID: id, isKeeper: group?.keepers.contains(id) ?? false,
            confidence: group?.confidence ?? .normal, pixelSize: pixels, onView: { viewing = id })
    }

    // MARK: Restoring the place

    /// In two steps: a photo in a group lives in a nested lazy grid that does not exist until its
    /// section is on screen, so the section is scrolled to first and then the photo.
    private func scrollToRestoredPhoto(
        _ proxy: ScrollViewProxy, in result: CategoryResult?, layout: Layout
    ) {
        guard let id = model.restoredFocus, let result else { return }
        guard let group = result.groups.first(where: { $0.members.contains(id) }) else { return }
        if layout == .groups {
            proxy.scrollTo(group.id, anchor: .top)
            Task {
                try? await Task.sleep(for: .milliseconds(80))
                proxy.scrollTo(id, anchor: .center)
            }
        } else {
            proxy.scrollTo(id, anchor: .center)
        }
    }
}
