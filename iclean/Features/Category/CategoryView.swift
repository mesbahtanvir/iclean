import CleanupKit
import SwiftUI

/// Items or groups in one category, with selection toggles (spec 009 6.5 and 6.6).
///
/// The body reads the results and never the selection: the bottom bar, the toolbar button and the
/// summary line are their own views reading `model.summary`, and every photo reads its own state, so
/// a toggle does not run this body again. It does not read the width or (on a Mac) the photo size
/// either: the scrolling grid is a view of its own (`CategoryScroller`) that does, so dragging the
/// slider or the window's edge lays out the grid and nothing more.
struct CategoryView: View {
    let category: CleanupCategory

    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.displayScale) private var displayScale
    #if os(macOS)
        @Environment(\.openConfirm) private var openConfirm
        /// What the cells share: where the keyboard is and where the arrow keys lead.
        @State private var navigator = GridNavigator()
    #endif
    @State private var showConfirm = false
    @State private var viewing: String?
    /// Warms the pictures just ahead of the scroll.
    @State private var prefetcher = ThumbnailPrefetcher()
    /// The flat list of the ids, worked out when the results change and not each time this runs.
    @State private var memo = MemberMemo()

    var body: some View {
        let result = model.results.category(category)
        // A flatMap over every group: 30,000 of them in a flat category.
        let members = memo.members(of: result, version: model.resultsVersion)
        let layout: CategoryLayout =
            category == .largeVideos
            ? .videoList : (result?.groups.first?.type == .single ? .flatGrid : .groups)
        mainContent(result, members: members, layout: layout)
            .environment(prefetcher)
            .onDisappear { prefetcher.stopAll() }
            .navigationTitle(category.title)
            #if os(iOS)
                // At accessibility sizes the title, the back button and "Select All Videos" cannot
                // share one line, so the title gets its own.
                .navigationBarTitleDisplayMode(typeSize.isAccessibilitySize ? .large : .inline)
            #endif
            #if os(macOS)
                // "3 sets · 6.4 MB" under the name, in the window's title bar.
                .modifier(
                    CategorySubtitle(
                        category: category, count: result?.groups.count ?? 0,
                        isGrouped: layout == .groups))
            #endif
            .task { await model.measureSizes(in: category) }
            .toolbar {
                #if os(macOS)
                    if layout != .videoList {
                        ToolbarItem(placement: .primaryAction) { PhotoSizeSlider() }
                    }
                #endif
                ToolbarItem(placement: .primaryAction) {
                    SelectSuggestedButton(category: category)
                }
            }
            #if os(iOS)
                .pinnedBar(isPresented: true) {
                    CategoryRemoveBar(category: category) { requestConfirm() }
                }
            #else
                // A 40 pt status bar, not a slab.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    MacRemoveStatusBar(category: category) { requestConfirm() }
                }
            #endif
            .sheet(isPresented: $showConfirm) { ConfirmSheet(category: category) }
            .photoViewer($viewing)
    }

    /// What fills the screen: the scrolling list of photos, groups or videos, or, for Large Videos on
    /// a Mac, a native table.
    @ViewBuilder private func mainContent(
        _ result: CategoryResult?, members: [String], layout: CategoryLayout
    ) -> some View {
        #if os(macOS)
            if layout == .videoList, result != nil {
                let pixels = GridSizing.videoPixels(scale: displayScale)
                VStack(alignment: .leading, spacing: Space.m) {
                    CategoryIntro(category: category, result: result, layout: layout)
                    MacVideoTable(
                        ids: members, pixelSize: pixels, onView: { viewing = $0 },
                        onRemove: removeIfSelected
                    )
                }
                .padding(.top, Space.l)
                .modifier(Prefetching(prefetcher: prefetcher, members: members, pixels: pixels))
            } else {
                scroller(result, members: members, layout: layout)
            }
        #else
            scroller(result, members: members, layout: layout)
        #endif
    }

    @ViewBuilder private func scroller(
        _ result: CategoryResult?, members: [String], layout: CategoryLayout
    ) -> some View {
        #if os(macOS)
            CategoryScroller(
                category: category, result: result, members: members, layout: layout,
                prefetcher: prefetcher, onView: { viewing = $0 }, navigator: navigator,
                onRemove: removeIfSelected)
        #else
            CategoryScroller(
                category: category, result: result, members: members, layout: layout,
                prefetcher: prefetcher, onView: { viewing = $0 })
        #endif
    }

    /// Opens the Confirm sheet. In the Mac window the shell owns it, so it outlives this screen.
    private func requestConfirm() {
        #if os(macOS)
            if let openConfirm {
                openConfirm(category)
                return
            }
        #endif
        showConfirm = true
    }

    #if os(macOS)
        /// Delete: opens the Confirm sheet, but only when something is selected, so the key can never
        /// show an empty question. It never removes anything itself.
        private func removeIfSelected() {
            guard (model.summary.perCategory[category]?.selected ?? 0) > 0 else { return }
            requestConfirm()
        }
    #endif
}

/// How the entries are laid out.
private enum CategoryLayout { case videoList, flatGrid, groups }

/// The sizes the screen and its grid share.
private enum GridSizing {
    static var pixelCap: Int {
        #if os(macOS)
            768
        #else
            512
        #endif
    }

    /// Space left and right of the grid: none on a phone, where the photos run edge to edge, and the
    /// text's gutter on a Mac, where the photos are rounded tiles and need air at the window's edge.
    static var gridInset: CGFloat {
        #if os(macOS)
            Space.l
        #else
            0
        #endif
    }

    /// The pixels the preview of a video in a list needs.
    static func videoPixels(scale: CGFloat) -> Int {
        #if os(macOS)
            // A 56 pt preview in the table.
            GridMetrics.pixels(
                width: MacVideoTable.preview, minimum: MacVideoTable.preview, spacing: 0,
                scale: scale, cap: pixelCap)
        #else
            // A 72 pt preview.
            GridMetrics.pixels(
                width: VideoRow.previewSide, minimum: VideoRow.previewSide, spacing: 0,
                scale: scale, cap: pixelCap)
        #endif
    }
}

/// The flat list of a category's ids, kept until the results change. Held by the screen, not
/// observed: `CategoryView` reads the results, which is what re-runs it.
@MainActor
private final class MemberMemo {
    private var version = -1
    private var groupCount = -1
    private var members: [String] = []

    func members(of result: CategoryResult?, version: Int) -> [String] {
        let groupCount = result?.groups.count ?? -1
        if version != self.version || groupCount != self.groupCount {
            members = result?.allMembers ?? []
            self.version = version
            self.groupCount = groupCount
        }
        return members
    }
}

/// Tells the prefetcher what is in the list and how big its pictures are. One task, restarted when
/// the list's length or the picture size changes.
private struct Prefetching: ViewModifier {
    let prefetcher: ThumbnailPrefetcher
    let members: [String]
    let pixels: Int

    @Environment(AppModel.self) private var model

    private struct Key: Equatable {
        let count: Int
        let pixels: Int
    }

    func body(content: Content) -> some View {
        content.task(id: Key(count: members.count, pixels: pixels)) {
            prefetcher.use(library: model.environment.library, ids: members, pixelSize: pixels)
        }
    }
}

/// Two lines above the photos, at the 16 pt gutter: what the default is, and how much there is.
private struct CategoryIntro: View {
    let category: CleanupCategory
    let result: CategoryResult?
    let layout: CategoryLayout

    @Environment(AppModel.self) private var model

    var body: some View {
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
}

/// The scrolling list of photos, groups or videos. It owns what changes while the person drags the
/// photo-size slider or the window's edge (the width, the photo size), so only it is laid out again.
/// The ids come in as one value that is the same array until the results change.
private struct CategoryScroller: View {
    let category: CleanupCategory
    let result: CategoryResult?
    let members: [String]
    let layout: CategoryLayout
    let prefetcher: ThumbnailPrefetcher
    let onView: (String) -> Void
    #if os(macOS)
        let navigator: GridNavigator
        let onRemove: () -> Void
    #endif

    @Environment(AppModel.self) private var model
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.displayScale) private var displayScale
    #if os(macOS)
        /// The photo size the person chose with the toolbar slider.
        @AppStorage(PhotoSize.key) private var photoSize = PhotoSize.standard
        /// The size under the slider's thumb while it is being dragged.
        private let drag = PhotoSizeDrag.shared
    #endif
    /// The width the columns are made from: the scroll view's content, which on a Mac is narrower
    /// than the scroll view when it shows a legacy scroll bar.
    @State private var width: CGFloat = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Lazy: a library with thousands of groups must not build them all when it opens.
                LazyVStack(alignment: .leading, spacing: Space.xl) {
                    CategoryIntro(category: category, result: result, layout: layout)
                    if let result {
                        if width > 0 {
                            content(result)
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
                #if os(macOS)
                    // Measured here, in the scroll content, and not on the scroll view: a legacy
                    // scroll bar (a mouse is connected, or Show scroll bars is Always) takes some of
                    // the scroll view's width, and the columns must be counted from what is left.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) {
                        $0.size.width
                    } action: {
                        measured($0)
                    }
                #endif
            }
            #if os(iOS)
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.width
                } action: {
                    measured($0)
                }
            #endif
            #if os(macOS)
                .gridKeys(navigator, toggle: { model.toggle($0) }, open: onView, remove: onRemove)
                .focusedSceneValue(
                    \.gridActions, GridActions(navigator: navigator, compare: compareFocused))
            #endif
            // A restored screen opens on the photo the person last touched.
            .onAppear {
                scrollToRestoredPhoto(proxy)
                #if os(macOS)
                    connectNavigator(proxy)
                #endif
            }
            // Not `allMembers.count`: that builds the whole list of ids each time the body runs.
            .onChange(of: result?.groups.count) {
                scrollToRestoredPhoto(proxy)
            }
            // The groups and cells are built once the width is known, which is after the screen
            // appeared: the first attempt above had nothing to scroll to.
            .onChange(of: width > 0) { _, known in
                guard known else { return }
                Task {
                    try? await Task.sleep(for: .milliseconds(80))
                    scrollToRestoredPhoto(proxy)
                }
            }
            #if os(macOS)
                .onChange(of: columnMinimum) { syncNavigator() }
                .onChange(of: layout) { navigator.isGrouped = layout == .groups }
            #endif
            .modifier(Prefetching(prefetcher: prefetcher, members: members, pixels: pixelSize))
        }
    }

    private func measured(_ newWidth: CGFloat) {
        width = newWidth
        syncNavigator()
    }

    #if os(macOS)
        /// Tells the keys how to find the results and how to scroll to a photo.
        private func connectNavigator(_ proxy: ScrollViewProxy) {
            navigator.results = { [model, category] in model.results.category(category) }
            navigator.version = { [model] in model.resultsVersion }
            navigator.restoredPhoto = { [model] in model.restoredFocus }
            navigator.select = { [model] ids in model.setSelected(ids, true) }
            navigator.isGrouped = layout == .groups
            navigator.scrollTo = { id, groupID in
                if let groupID {
                    // The group's own section first: its photos are in a lazy grid that does not
                    // exist until the section is on screen.
                    proxy.scrollTo(groupID, anchor: nil)
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(80))
                        proxy.scrollTo(id, anchor: nil)
                    }
                } else {
                    proxy.scrollTo(id, anchor: nil)
                }
            }
            syncNavigator()
        }

        /// Edit > Compare This Group: the compare screen of the group the keyboard is in.
        private func compareFocused() {
            guard MacNavigation.shared.groupPath.isEmpty, let groupID = navigator.focusedGroupID,
                let group = result?.groups.first(where: { $0.id == groupID })
            else { return }
            MacNavigation.shared.groupPath.append(.group(category, containing: group))
        }
    #endif

    /// The number of columns the grid has now, which the up and down keys step by.
    private func syncNavigator() {
        #if os(macOS)
            navigator.columns = GridMetrics.columns(
                width: Double(gridWidth), minimum: Double(columnMinimum),
                spacing: Double(Gutter.grid))
        #endif
    }

    // MARK: Sizes

    /// The smallest a photo may be: wider on a Mac and at accessibility sizes, so a cell stays
    /// large enough for its glyphs. On a Mac the person sets it with the slider, and the grid
    /// follows the thumb as it moves.
    private var columnMinimum: CGFloat {
        #if os(macOS)
            CGFloat(PhotoSize.clamped(drag.size ?? photoSize))
        #else
            typeSize.isAccessibilitySize ? 150 : 104
        #endif
    }

    /// The smallest a photo may be, for the pictures asked for. While the thumb is down this is
    /// still the size that was set before, so the sweep does not start a new round of requests at
    /// each step; the pictures are asked for again at the size that was settled on.
    private var requestMinimum: CGFloat {
        #if os(macOS)
            CGFloat(PhotoSize.clamped(photoSize))
        #else
            columnMinimum
        #endif
    }

    /// The width the columns are made from.
    private var gridWidth: CGFloat { max(width - 2 * GridSizing.gridInset, 0) }

    /// The pixels each picture needs, from the real width of a cell (`GridMetrics`).
    private var pixelSize: Int {
        switch layout {
        case .videoList:
            return GridSizing.videoPixels(scale: displayScale)
        case .flatGrid, .groups:
            guard width > 0 else { return 256 }
            return GridMetrics.pixels(
                width: gridWidth, minimum: requestMinimum, spacing: Gutter.grid,
                scale: displayScale, cap: GridSizing.pixelCap)
        }
    }

    // MARK: Content

    @ViewBuilder private func content(_ result: CategoryResult) -> some View {
        let pixels = pixelSize
        switch layout {
        case .videoList:
            LazyVStack(spacing: 0) {
                ForEach(members, id: \.self) { id in
                    VideoRow(assetID: id, pixelSize: pixels) { onView(id) }
                }
            }
        case .flatGrid:
            equatable(photos(members, group: nil, pixels: pixels))
        case .groups:
            // Each group is its own element of the lazy stack, as before.
            ForEach(result.groups) { group in
                equatable(
                    GroupSection(
                        category: category, group: group,
                        photos: photos(group.members, group: group, pixels: pixels)))
            }
        }
    }

    private func photos(_ ids: [String], group: ResultGroup?, pixels: Int) -> PhotoGrid {
        #if os(macOS)
            PhotoGrid(
                members: ids, group: group, columnMinimum: columnMinimum, pixels: pixels,
                navigator: navigator, onView: onView)
        #else
            PhotoGrid(
                members: ids, group: group, columnMinimum: columnMinimum, pixels: pixels,
                onView: onView)
        #endif
    }

    /// On a Mac, the photos are laid out again only when what they are made from changes. The width
    /// changes with every frame of a window's resize and the slider with every step, and most of
    /// those leave the ids, the columns and the pictures' size as they were: the lazy grid fits
    /// itself to the width, and nothing here needs to run. (On a phone the width only changes when
    /// the phone is turned.)
    @ViewBuilder private func equatable<Content: View & Equatable>(_ view: Content) -> some View {
        #if os(macOS)
            view.equatable()
        #else
            view
        #endif
    }

    // MARK: Restoring the place

    /// In two steps: a photo in a group lives in a nested lazy grid that does not exist until its
    /// section is on screen, so the section is scrolled to first and then the photo.
    private func scrollToRestoredPhoto(_ proxy: ScrollViewProxy) {
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

/// A lazy grid of photos: a flat category, or the photos of one group.
private struct PhotoGrid: View, Equatable {
    let members: [String]
    /// The group these photos are in, nil in a flat grid.
    let group: ResultGroup?
    let columnMinimum: CGFloat
    let pixels: Int
    #if os(macOS)
        let navigator: GridNavigator
    #endif
    let onView: (String) -> Void

    /// What the grid is made from. The closures stand for state that does not change.
    nonisolated static func == (lhs: PhotoGrid, rhs: PhotoGrid) -> Bool {
        lhs.members == rhs.members && lhs.group == rhs.group
            && lhs.columnMinimum == rhs.columnMinimum && lhs.pixels == rhs.pixels
    }

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: columnMinimum), spacing: Gutter.grid)],
            spacing: Gutter.grid
        ) {
            ForEach(members, id: \.self) { cell($0) }
        }
        .padding(.horizontal, GridSizing.gridInset)
    }

    @ViewBuilder private func cell(_ id: String) -> some View {
        #if os(macOS)
            MacItemCell(
                assetID: id, isKeeper: group?.keepers.contains(id) ?? false,
                confidence: group?.confidence ?? .normal, pixelSize: pixels, group: group,
                navigator: navigator, onView: { onView(id) })
        #else
            ItemCell(
                assetID: id, isKeeper: group?.keepers.contains(id) ?? false,
                confidence: group?.confidence ?? .normal, pixelSize: pixels,
                onView: { onView(id) })
        #endif
    }
}

/// One group of copies or similar shots: its header, which links to Compare, and its photos.
private struct GroupSection: View, Equatable {
    let category: CleanupCategory
    let group: ResultGroup
    let photos: PhotoGrid

    nonisolated static func == (lhs: GroupSection, rhs: GroupSection) -> Bool {
        lhs.category == rhs.category && lhs.group == rhs.group && lhs.photos == rhs.photos
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            GroupHeader(category: category, group: group)
            photos
        }
    }
}
