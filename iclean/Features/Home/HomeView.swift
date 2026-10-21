import CleanupKit
import SwiftUI

/// Home: the answer to "how much can I free?", and the one next step.
///
/// The screen it shows is chosen by `HomeState`. The navigation scaffolding does not depend on it:
/// the destinations, the Settings gear, the alert, the Confirm sheet and the tripwire all live on
/// the stack and its root container, so they are there in every state and nothing is torn down
/// when the state changes (a Confirm sheet that is open survives its own bar disappearing).
struct HomeView: View {
    @Environment(AppModel.self) private var model
    /// The screens pushed on Home. Typed, so they can be saved and put back after a restart.
    @State private var path: [Route] = []
    /// The Review bar opens the Confirm sheet from here, not from the bar.
    @State private var showConfirm = false

    var body: some View {
        NavigationStack(path: $path) {
            ZStack { content }
                .navigationTitle("iclean")
                #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                #endif
                #if os(iOS)
                    // The Mac has a Settings window (Command-comma), so no gear there.
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            NavigationLink {
                                SettingsView()
                            } label: {
                                Label("Settings", systemImage: "gearshape")
                            }
                            .accessibilityIdentifier("home.settings")
                        }
                    }
                #endif
                .navigationDestination(for: Route.self) { RouteDestinationView(route: $0) }
                .overlay(alignment: .bottom) { tripwireCount }
        }
        .sheet(isPresented: $showConfirm) { ConfirmSheet() }
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
        .onChange(of: path) { _, new in model.pathChanged(new) }
        // The saved review stack is put back once, when the launch has results to check it against.
        .onChange(of: model.restoredRoute) { _, new in restore(new) }
        .task { restore(model.restoredRoute) }
    }

    @ViewBuilder private var content: some View {
        switch HomeState(model) {
        case .launching(let opening):
            withNotices { HomeLaunching(opening: opening) }
        case .failed:
            withNotices { HomeFailed() }
        case .results:
            ResultsView(onReview: { showConfirm = true })
        case .interruptedEmpty:
            withNotices { HomeInterruptedEmpty() }
        case .firstRun:
            withNotices { HomeFirstRun() }
        case .emptyLibrary:
            withNotices { HomeNothingToShow(kind: .emptyLibrary) }
        case .allCleaned:
            withNotices(iCloud: true) { HomeNothingToShow(kind: .allCleaned) }
        case .clean:
            withNotices(iCloud: true) { HomeNothingToShow(kind: .clean) }
        }
    }

    /// A one-sentence state with the notices (limited access, store problems, iCloud-only photos)
    /// as footnotes at the bottom edge, where they never compete with the sentence.
    private func withNotices<Content: View>(
        iCloud: Bool = false, @ViewBuilder _ content: () -> Content
    ) -> some View {
        content()
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(alignment: .leading, spacing: Space.s) {
                    if iCloud { ICloudFootnote(count: model.results.notScannedCount) }
                    HomeNotices()
                }
                .padding(.horizontal, Space.l)
                .padding(.vertical, Space.m)
                .readableColumn()
            }
    }

    private func restore(_ restored: RestoredRoute?) {
        guard let restored, path.isEmpty else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { path = restored.path }
        model.restoredRoute = nil
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
}
