#if os(macOS)
    import CleanupKit
    import SwiftUI

    /// A request to open the Confirm sheet: for one category, or (nil) for everything selected.
    private struct ConfirmRequest: Identifiable {
        let id = UUID()
        let category: CleanupCategory?
    }

    /// The Mac's window (spec 012 section 6.15): a sidebar, and a detail pane that shows the Overview or
    /// the selected category, with group compare pushed inside the detail pane.
    ///
    /// The iPhone's Home is a stack of screens; this is the same screens laid out for a window. It
    /// reuses the phone's pieces (the hero, the rows, the scan card, the one-sentence states) and the
    /// same route destinations, so a review that was saved is put back the same way.
    ///
    /// The window shows the detail alone until the first results arrive, so the first thing on a Mac
    /// is one sentence and one big button, and the sidebar appears once, when it has something in it.
    ///
    /// The navigation scaffolding does not depend on the state shown: the Confirm sheet and the
    /// toolbar live here, so they are there in every state, and a Confirm sheet that is open
    /// survives the screen under it going away (a category that was emptied by the removal itself).
    /// The app's one alert (a Delete All that failed) is the Settings window's, where the button is.
    struct SplitRootView: View {
        @Environment(AppModel.self) private var model

        /// The sidebar's choice and the screens pushed inside the detail pane (group compare only,
        /// each a `.group` route). Held outside this view: a window that is closed and opened again
        /// from the Dock must come back to the place `AppModel` still believes the person is at,
        /// not to an Overview that disagrees with the held results and the saved place.
        @Bindable private var navigation = MacNavigation.shared
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
                NavigationStack(path: $navigation.groupPath) {
                    detailRoot
                        .navigationDestination(for: Route.self) { RouteDestinationView(route: $0) }
                }
                .overlay(alignment: .bottom) { tripwireCount }
            }
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) { ScanToolbarButtons() }
                // The count is in the toolbar only while nothing else shows it: the sidebar's footer
                // has the scan card while results exist, and the pane has it before they do. At the
                // narrowest window the toolbar is already full (title, Scan, the photo size, Select
                // Suggested), and macOS would push the less important of them into the overflow.
                if model.isScanning, hasResults, visibility == .detailOnly {
                    ToolbarItem(placement: .status) { ScanToolbarStatus() }
                }
            }
            .environment(
                \.openConfirm, { category in confirm = ConfirmRequest(category: category) }
            )
            .focusedSceneValue(\.reviewActions, reviewActions)
            .sheet(item: $confirm) { ConfirmSheet(category: $0.category) }
            .onChange(of: route) { _, new in model.pathChanged(new) }
            // The saved review is put back once, when the launch has results to check it against.
            .onChange(of: model.restoredRoute) { _, new in restore(new) }
            .onChange(of: hasResults, initial: true) { _, has in showSidebar(has) }
            // A category that is no longer in the results (emptied by a removal, or the saved data
            // was deleted) is left for the Overview, so the pane never shows a selection that the
            // sidebar no longer has.
            .onChange(of: selectionIsStale, initial: true) { _, stale in
                if stale { choose(.overview) }
            }
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
                switch navigation.selection {
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
            if case .category(let category) = navigation.selection { category } else { nil }
        }

        /// The selected category has left the results: its last photos were removed, or the saved
        /// data was deleted. Not while the results are still being opened or built.
        private var selectionIsStale: Bool {
            guard model.launchPhase == .ready, case .category(let category) = navigation.selection
            else { return false }
            return model.results.category(category) == nil
        }

        // MARK: Selection and route

        /// What the sidebar sees and changes. Choosing another item leaves any group that was pushed.
        private var sidebarSelection: Binding<SidebarItem?> {
            Binding(
                get: { navigation.selection },
                set: { new in if let new { choose(new) } })
        }

        private func choose(_ item: SidebarItem) {
            guard item != navigation.selection || !navigation.groupPath.isEmpty else { return }
            navigation.selection = item
            navigation.groupPath = []
        }

        private func select(_ category: CleanupCategory) { choose(.category(category)) }

        /// The review stack the model knows about: the selected category, then the groups pushed on
        /// it. Nothing on the Overview. The same list the phone's stack holds, so saving a position
        /// and putting it back (spec 007) and the route validator need no change.
        private var route: [Route] { navigation.route }

        /// Puts the saved review back at launch. The route is always used up, here or not at all:
        /// one left behind would be applied by a later window, long after the person went
        /// elsewhere. It never moves a person who has already chosen a place ("Continue reviewing"
        /// is that person asking, and `MacContinueRow` takes them there in any state).
        private func restore(_ restored: RestoredRoute?) {
            guard let restored else { return }
            model.restoredRoute = nil
            guard route.isEmpty else { return }
            navigation.go(to: restored.path)
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
            // The group whose compare screen is on top of the category, if there is one: the
            // selection commands act on it and not on the category behind it.
            return ReviewActions(category: category, group: navigation.groupPath.last) {
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
