#if os(macOS)
    import CleanupKit
    import SwiftUI

    /// A request to open the Confirm sheet: for one category, or (nil) for everything selected.
    private struct ConfirmRequest: Identifiable {
        let id = UUID()
        let category: CleanupCategory?
    }

    /// The Mac's window (spec 009 section 6.15): a sidebar, and a detail pane that shows the Overview or
    /// the selected category, with group compare pushed inside the detail pane.
    ///
    /// The iPhone's Home is a stack of screens; this is the same screens laid out for a window. It
    /// reuses the phone's pieces (the hero, the rows, the scan card, the one-sentence states) and the
    /// same route destinations, so a review that was saved is put back the same way.
    ///
    /// The window shows the detail alone until the first results arrive, so the first thing on a Mac
    /// is one sentence and one big button, and the sidebar appears once, when it has something in it.
    ///
    /// The navigation scaffolding does not depend on the state shown: the Confirm sheet, the alert and
    /// the toolbar live here, so they are there in every state, and a Confirm sheet that is open
    /// survives the screen under it going away (a category that was emptied by the removal itself).
    struct SplitRootView: View {
        @Environment(AppModel.self) private var model

        /// The sidebar's choice. The detail pane follows it.
        @State private var selection: SidebarItem = .overview
        /// The screens pushed inside the detail pane: group compare only, each a `.group` route.
        @State private var groupPath: [Route] = []
        @State private var visibility: NavigationSplitViewVisibility = .detailOnly
        @State private var revealedSidebar = false
        @State private var confirm: ConfirmRequest?
        #if DEBUG
            @State private var debugViewer: String?
        #endif

        var body: some View {
            NavigationSplitView(columnVisibility: $visibility) {
                Sidebar(selection: sidebarSelection)
                    .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
            } detail: {
                NavigationStack(path: $groupPath) {
                    detailRoot
                        .navigationDestination(for: Route.self) { RouteDestinationView(route: $0) }
                }
                .overlay(alignment: .bottom) { tripwireCount }
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) { ScanToolbarButtons() }
                if model.isScanning {
                    ToolbarItem(placement: .status) { ScanToolbarStatus() }
                }
            }
            .environment(
                \.openConfirm, { category in confirm = ConfirmRequest(category: category) }
            )
            .focusedSceneValue(\.reviewActions, reviewActions)
            .sheet(item: $confirm) { ConfirmSheet(category: $0.category) }
            .alert(
                "Something went wrong",
                isPresented: Binding(
                    get: { model.errorMessage != nil },
                    set: { if !$0 { model.errorMessage = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.errorMessage ?? "")
            }
            .onChange(of: route) { _, new in model.pathChanged(new) }
            // The saved review is put back once, when the launch has results to check it against.
            .onChange(of: model.restoredRoute) { _, new in restore(new) }
            .onChange(of: hasResults, initial: true) { _, has in showSidebar(has) }
            .task { restore(model.restoredRoute) }
            #if DEBUG
                .photoViewer($debugViewer)
                .task { await driveForSnapshot() }
            #endif
        }

        // MARK: Detail

        /// One answer per state, the same as the phone's Home: the sentence states are centred in the
        /// pane, and with results it is the Overview or the selected category.
        @ViewBuilder private var detailRoot: some View {
            switch HomeState(model) {
            case .launching(let opening):
                HomeLaunching(opening: opening).homeNotices().navigationTitle("iclean")
            case .failed:
                HomeFailed().homeNotices().navigationTitle("iclean")
            case .results:
                resultsDetail
            case .interruptedEmpty:
                HomeInterruptedEmpty().homeNotices().navigationTitle("iclean")
            case .firstRun:
                HomeFirstRun().homeNotices().navigationTitle("iclean")
            case .emptyLibrary:
                HomeNothingToShow(kind: .emptyLibrary).homeNotices().navigationTitle("iclean")
            case .allCleaned:
                HomeNothingToShow(kind: .allCleaned).homeNotices(iCloud: true)
                    .navigationTitle("iclean")
            case .clean:
                HomeNothingToShow(kind: .clean).homeNotices(iCloud: true).navigationTitle("iclean")
            }
        }

        @ViewBuilder private var resultsDetail: some View {
            if !hasResults {
                if model.isScanning {
                    // Nothing found yet: the scan card is the pane, and the controls are in the
                    // toolbar. Never a spinner beside it, never a claim that the library is clean.
                    ScanningView(showsControls: false)
                        .frame(maxWidth: 420)
                        .padding(Space.xxl)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .homeNotices()
                        .navigationTitle("iclean")
                } else {
                    // The scan is over and its results are being built.
                    DelayedProgress(caption: "Updating results…")
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("results.updating")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .homeNotices()
                        .navigationTitle("iclean")
                }
            } else {
                switch selection {
                case .overview:
                    Overview(
                        onReview: { confirm = ConfirmRequest(category: nil) },
                        onSelect: select
                    )
                    .navigationTitle("Overview")
                case .category(let category):
                    // A new identity per category, so a switch never carries the old screen's state
                    // (the open viewer, the scroll position) into the next.
                    CategoryView(category: category)
                        .id(category)
                }
            }
        }

        private var hasResults: Bool { !model.results.categories.isEmpty }

        private var selectedCategory: CleanupCategory? {
            if case .category(let category) = selection { category } else { nil }
        }

        // MARK: Selection and route

        /// What the sidebar sees and changes. Choosing another item leaves any group that was pushed.
        private var sidebarSelection: Binding<SidebarItem?> {
            Binding(
                get: { selection },
                set: { new in if let new { choose(new) } })
        }

        private func choose(_ item: SidebarItem) {
            guard item != selection || !groupPath.isEmpty else { return }
            selection = item
            groupPath = []
        }

        private func select(_ category: CleanupCategory) { choose(.category(category)) }

        /// The review stack the model knows about: the selected category, then the groups pushed on
        /// it. Nothing on the Overview. The same list the phone's stack holds, so saving a position
        /// and putting it back (spec 007) and the route validator need no change.
        private var route: [Route] {
            if case .category(let category) = selection {
                return [.category(category)] + groupPath
            }
            return []
        }

        /// The route as a binding: its first element is the sidebar's choice, the rest the stack.
        private var routeBinding: Binding<[Route]> {
            Binding(
                get: { route },
                set: { new in
                    if case .category(let category)? = new.first {
                        selection = .category(category)
                        groupPath = Array(new.dropFirst())
                    } else {
                        selection = .overview
                        groupPath = []
                    }
                })
        }

        private func restore(_ restored: RestoredRoute?) {
            guard let restored, route.isEmpty else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { routeBinding.wrappedValue = restored.path }
            model.restoredRoute = nil
        }

        /// The sidebar appears once, when the first results do. Until then the window is one
        /// sentence in the middle; after that the person's own choice to hide it is respected.
        private func showSidebar(_ hasResults: Bool) {
            if hasResults, !revealedSidebar {
                revealedSidebar = true
                visibility = .all
            } else if !hasResults {
                revealedSidebar = false
                visibility = .detailOnly
            }
        }

        // MARK: Menu

        /// What the Edit menu acts on: the category in front, or the Overview, and how to open the
        /// Confirm sheet for it. Nothing while there is nothing to review.
        private var reviewActions: ReviewActions? {
            guard hasResults else { return nil }
            let category = selectedCategory
            return ReviewActions(category: category) {
                confirm = ConfirmRequest(category: category)
            }
        }

        @ViewBuilder private var tripwireCount: some View {
            #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-NetworkTripwire") {
                    Text("\(NetworkTripwire.attempts.count)")
                        .font(.caption2)
                        .opacity(0.01)
                        .accessibilityIdentifier("tripwire.count")
                }
            #endif
        }

        // MARK: Snapshots

        #if DEBUG
            /// `-SelectSidebar` and `-OpenSheet` (WindowSnapshot): puts the window in a state worth a
            /// picture, once there are results to show.
            private func driveForSnapshot() async {
                let sidebar = WindowSnapshot.requestedSidebar
                let sheet = WindowSnapshot.requestedSheet
                guard sidebar != nil || sheet != nil else { return }
                for _ in 0..<300 {
                    if hasResults, model.launchPhase == .ready { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                guard hasResults else { return }
                if let sidebar {
                    if sidebar == "overview" {
                        choose(.overview)
                    } else if let category = CleanupCategory(rawValue: sidebar) {
                        choose(.category(category))
                    }
                }
                // Let the detail pane settle before a sheet goes over it.
                try? await Task.sleep(for: .milliseconds(600))
                switch sheet {
                case "confirm":
                    confirm = ConfirmRequest(category: selectedCategory)
                case "viewer":
                    let result =
                        selectedCategory.flatMap { model.results.category($0) }
                        ?? model.results.categories.first
                    debugViewer = result?.allMembers.first
                default:
                    break
                }
            }
        #endif
    }
#endif
